import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SecondSightCore

struct RedactionSnapshot: Sendable {
    let axRects: [CGRect]
    let secureInputEnabled: Bool
    let axSummary: String?
}

final class RedactionSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RedactionSnapshot(axRects: [], secureInputEnabled: false, axSummary: nil)

    func update(_ snapshot: RedactionSnapshot) {
        lock.lock()
        value = snapshot
        lock.unlock()
    }

    func current() -> RedactionSnapshot {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

final class AccessibilityScanner: @unchecked Sendable {
    let store: RedactionSnapshotStore
    private let queue = DispatchQueue(label: "study.secondsight.ax-scanner", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(store: RedactionSnapshotStore = RedactionSnapshotStore()) {
        self.store = store
    }

    func start() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: .milliseconds(200), leeway: .milliseconds(30))
        timer.setEventHandler { [weak self] in self?.scan() }
        self.timer = timer
        timer.resume()
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func scan() {
        let secureInput = IsSecureEventInputEnabled()
        guard AXIsProcessTrusted() else {
            store.update(RedactionSnapshot(axRects: [], secureInputEnabled: secureInput, axSummary: nil))
            return
        }

        let system = AXUIElementCreateSystemWide()
        guard let app = elementAttribute(system, kAXFocusedApplicationAttribute as CFString) else {
            store.update(RedactionSnapshot(axRects: [], secureInputEnabled: secureInput, axSummary: nil))
            return
        }
        let windows = elementArrayAttribute(app, kAXWindowsAttribute as CFString)
        var rects: [CGRect] = []
        var summaryNodes: [[String: Any]] = []
        var visited = 0
        for window in windows.prefix(8) {
            walk(window, depth: 0, visited: &visited, rects: &rects, summary: &summaryNodes)
            if visited >= 2_000 { break }
        }
        let summary = Self.compactJSON(summaryNodes, maximumBytes: 8 * 1_024)
        store.update(RedactionSnapshot(axRects: rects, secureInputEnabled: secureInput, axSummary: summary))
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        visited: inout Int,
        rects: inout [CGRect],
        summary: inout [[String: Any]]
    ) {
        guard visited < 2_000, depth <= 10 else { return }
        visited += 1
        let role = stringAttribute(element, kAXRoleAttribute as CFString) ?? ""
        let subrole = stringAttribute(element, kAXSubroleAttribute as CFString) ?? ""
        let titleParts = [
            stringAttribute(element, kAXTitleAttribute as CFString),
            stringAttribute(element, kAXDescriptionAttribute as CFString),
            stringAttribute(element, "AXPlaceholderValue" as CFString),
        ].compactMap { $0 }
        let label = titleParts.joined(separator: " ")
        if (subrole == (kAXSecureTextFieldSubrole as String) ||
            (role == (kAXTextFieldRole as String) && SensitiveTextPolicy.isSensitiveField(label: label))),
           let frame = frameAttribute(element)
        {
            rects.append(frame)
        }

        if depth <= 4, summary.count < 350 {
            var node: [String: Any] = ["role": role]
            if !subrole.isEmpty { node["subrole"] = subrole }
            if !label.isEmpty { node["title"] = String(label.prefix(300)) }
            if let frame = frameAttribute(element) {
                node["frame"] = ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
            }
            node["depth"] = depth
            summary.append(node)
        }
        for child in elementArrayAttribute(element, kAXChildrenAttribute as CFString) {
            walk(child, depth: depth + 1, visited: &visited, rects: &rects, summary: &summary)
            if visited >= 2_000 { return }
        }
    }

    private static func compactJSON(_ object: Any, maximumBytes: Int) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(withJSONObject: object, options: [])
        else { return nil }
        if data.count <= maximumBytes { return String(data: data, encoding: .utf8) }
        var nodes = object as? [[String: Any]] ?? []
        while !nodes.isEmpty {
            nodes.removeLast(max(1, nodes.count / 8))
            guard let candidate = try? JSONSerialization.data(withJSONObject: nodes), candidate.count <= maximumBytes else { continue }
            return String(data: candidate, encoding: .utf8)
        }
        return "[]"
    }

    private func elementAttribute(_ element: AXUIElement, _ attribute: CFString) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID()
        else { return nil }
        return (value as! AXUIElement)
    }

    private func elementArrayAttribute(_ element: AXUIElement, _ attribute: CFString) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func stringAttribute(_ element: AXUIElement, _ attribute: CFString) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success else { return nil }
        return value as? String
    }

    private func frameAttribute(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &sizeValue) == .success,
              let positionValue,
              let sizeValue,
              CFGetTypeID(positionValue) == AXValueGetTypeID(),
              CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }
        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
