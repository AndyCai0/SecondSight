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
    private static let interval = DispatchTimeInterval.milliseconds(200)
    private static let messagingTimeout: Float = 0.08
    private static let maximumScanDurationNanoseconds: UInt64 = 140_000_000
    private static let maximumVisitedElements = 750
    private static let maximumDepth = 10

    let store: RedactionSnapshotStore
    private let queue = DispatchQueue(label: "study.secondsight.ax-scanner", qos: .userInitiated)
    private var timer: DispatchSourceTimer?

    init(store: RedactionSnapshotStore = RedactionSnapshotStore()) {
        self.store = store
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now(), repeating: Self.interval, leeway: .milliseconds(30))
            timer.setEventHandler { [weak self] in
                // AX returns Objective-C/Core Foundation objects. Drain them after
                // every bounded pass instead of retaining thousands until a GCD
                // worker happens to recycle its pool.
                autoreleasepool { self?.scan() }
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        queue.sync {
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0)
            store.update(RedactionSnapshot(axRects: [], secureInputEnabled: false, axSummary: nil))
        }
    }

    private func scan() {
        let secureInput = IsSecureEventInputEnabled()
        guard AXIsProcessTrusted() else {
            store.update(RedactionSnapshot(axRects: [], secureInputEnabled: secureInput, axSummary: nil))
            return
        }

        let system = AXUIElementCreateSystemWide()
        // A changing or unresponsive target app must not leave this 5 Hz source
        // blocked with stale AX proxies. This timeout is process-global and is
        // reset in stop().
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        guard let app = elementAttribute(system, kAXFocusedApplicationAttribute as CFString) else {
            store.update(RedactionSnapshot(axRects: [], secureInputEnabled: secureInput, axSummary: nil))
            return
        }
        let deadline = DispatchTime.now().uptimeNanoseconds + Self.maximumScanDurationNanoseconds
        var roots: [AXUIElement] = []
        if let focusedElement = elementAttribute(app, kAXFocusedUIElementAttribute as CFString) {
            roots.append(focusedElement)
        }
        if let focusedWindow = elementAttribute(app, kAXFocusedWindowAttribute as CFString),
           !roots.contains(where: { CFEqual($0, focusedWindow) }) {
            roots.append(focusedWindow)
        }
        for window in elementArrayAttribute(app, kAXWindowsAttribute as CFString).prefix(4)
        where !roots.contains(where: { CFEqual($0, window) }) {
            roots.append(window)
        }
        var rects: [CGRect] = []
        var summaryNodes: [[String: Any]] = []
        var visited = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]
        for root in roots {
            walk(
                root,
                depth: 0,
                deadline: deadline,
                visited: &visited,
                seen: &seen,
                rects: &rects,
                summary: &summaryNodes
            )
            if scanLimitReached(visited: visited, deadline: deadline) { break }
        }
        let summary = Self.compactJSON(summaryNodes, maximumBytes: 8 * 1_024)
        store.update(RedactionSnapshot(axRects: rects, secureInputEnabled: secureInput, axSummary: summary))
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        deadline: UInt64,
        visited: inout Int,
        seen: inout [CFHashCode: [AXUIElement]],
        rects: inout [CGRect],
        summary: inout [[String: Any]]
    ) {
        guard depth <= Self.maximumDepth,
              !scanLimitReached(visited: visited, deadline: deadline)
        else { return }
        let elementHash = CFHash(element)
        if seen[elementHash]?.contains(where: { CFEqual($0, element) }) == true { return }
        seen[elementHash, default: []].append(element)
        visited += 1
        guard let attributes = elementAttributes(element) else { return }
        let role = attributes.role
        let subrole = attributes.subrole
        let titleParts = [attributes.title, attributes.description, attributes.placeholder].compactMap { $0 }
        let label = titleParts.joined(separator: " ")
        let frame = attributes.frame
        if (subrole == (kAXSecureTextFieldSubrole as String) ||
            (role == (kAXTextFieldRole as String) && SensitiveTextPolicy.isSensitiveField(label: label))),
           let frame
        {
            rects.append(frame)
        }

        if depth <= 4, summary.count < 350 {
            var node: [String: Any] = ["role": role]
            if !subrole.isEmpty { node["subrole"] = subrole }
            if !label.isEmpty { node["title"] = String(label.prefix(300)) }
            if let frame {
                node["frame"] = ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
            }
            node["depth"] = depth
            summary.append(node)
        }
        for child in attributes.children {
            walk(
                child,
                depth: depth + 1,
                deadline: deadline,
                visited: &visited,
                seen: &seen,
                rects: &rects,
                summary: &summary
            )
            if scanLimitReached(visited: visited, deadline: deadline) { return }
        }
    }

    private func scanLimitReached(visited: Int, deadline: UInt64) -> Bool {
        visited >= Self.maximumVisitedElements || DispatchTime.now().uptimeNanoseconds >= deadline
    }

    private struct ElementAttributes {
        let role: String
        let subrole: String
        let title: String?
        let description: String?
        let placeholder: String?
        let frame: CGRect?
        let children: [AXUIElement]
    }

    private func elementAttributes(_ element: AXUIElement) -> ElementAttributes? {
        let names: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
        ]
        var rawValues: CFArray?
        let error = AXUIElementCopyMultipleAttributeValues(
            element,
            names as CFArray,
            AXCopyMultipleAttributeOptions(rawValue: 0),
            &rawValues
        )
        guard error == .success,
              let values = rawValues as? [Any],
              values.count == names.count
        else { return nil }

        let visibleChildren = values[7] as? [AXUIElement]
        return ElementAttributes(
            role: values[0] as? String ?? "",
            subrole: values[1] as? String ?? "",
            title: values[2] as? String,
            description: values[3] as? String,
            placeholder: values[4] as? String,
            frame: frame(positionValue: values[5], sizeValue: values[6]),
            // Some accessibility providers do not implement AXVisibleChildren.
            // Fall back only when it is unsupported, not when it is a valid
            // empty array, so off-screen virtualized nodes stay out of the walk.
            children: visibleChildren
                ?? elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        )
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

    private func frame(positionValue: Any, sizeValue: Any) -> CGRect? {
        let positionObject = positionValue as CFTypeRef
        let sizeObject = sizeValue as CFTypeRef
        guard CFGetTypeID(positionObject) == AXValueGetTypeID(),
              CFGetTypeID(sizeObject) == AXValueGetTypeID()
        else { return nil }
        let positionAX = positionObject as! AXValue
        let sizeAX = sizeObject as! AXValue
        guard AXValueGetType(positionAX) == .cgPoint,
              AXValueGetType(sizeAX) == .cgSize
        else { return nil }
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position), AXValueGetValue(sizeAX, .cgSize, &size) else { return nil }
        return CGRect(origin: position, size: size)
    }
}
