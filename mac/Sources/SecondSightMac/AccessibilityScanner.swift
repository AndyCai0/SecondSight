import ApplicationServices
import AppKit
import Carbon.HIToolbox
import CoreGraphics
import Foundation
import SecondSightCore

struct RedactionSnapshot: Sendable {
    let axRects: [CGRect]
    let secureInputEnabled: Bool
    let protectionUnavailable: Bool
    let axSummary: String?
}

final class RedactionSnapshotStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value = RedactionSnapshot(
        axRects: [],
        secureInputEnabled: false,
        protectionUnavailable: true,
        axSummary: nil
    )

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
    // A protected display can legitimately contain two visible Safari
    // windows from one process. The previous 140 ms budget repeatedly stopped
    // around 280 nodes and paused every frame even though the scan was making
    // healthy progress. Keep the pass bounded, but allow the precise leaf
    // scan to finish instead of falling back to an unusable black/stale view.
    private static let maximumScanDurationNanoseconds: UInt64 = 280_000_000
    private static let maximumVisitedElements = 1_000
    private static let maximumDepth = 10

    let store: RedactionSnapshotStore
    private let queue = DispatchQueue(label: "study.secondsight.ax-scanner", qos: .userInitiated)
    private var timer: DispatchSourceTimer?
    private var isRunning = false
    private var focusedApplicationObserver: AXObserver?
    private var observedProcessID: pid_t?
    private var workspaceActivationObserver: NSObjectProtocol?
    private var protectedDisplayFramePoints = CGRect.zero

    private struct SummaryNode {
        var payload: [String: Any]
        let frame: CGRect?
        let privacyProtected: Bool
    }

    private static let observerCallback: AXObserverCallback = { _, _, _, refcon in
        guard let refcon else { return }
        let scanner = Unmanaged<AccessibilityScanner>.fromOpaque(refcon).takeUnretainedValue()
        scanner.requestScan()
    }

    init(store: RedactionSnapshotStore = RedactionSnapshotStore()) {
        self.store = store
    }

    func protect(displayFramePoints: CGRect) {
        queue.sync {
            protectedDisplayFramePoints = displayFramePoints.standardized
        }
    }

    func start() {
        queue.sync {
            guard timer == nil else { return }
            isRunning = true
            workspaceActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.didActivateApplicationNotification,
                object: nil,
                queue: nil
            ) { [weak self] _ in
                self?.requestScan()
            }
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
            isRunning = false
            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil
            if let workspaceActivationObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(workspaceActivationObserver)
                self.workspaceActivationObserver = nil
            }
            removeFocusedApplicationObserver()
            let system = AXUIElementCreateSystemWide()
            AXUIElementSetMessagingTimeout(system, 0)
            store.update(RedactionSnapshot(
                axRects: [],
                secureInputEnabled: false,
                protectionUnavailable: true,
                axSummary: nil
            ))
        }
    }

    private struct VisibleWindow {
        let processID: pid_t
        let frame: CGRect
        let visibleRegions: [CGRect]
    }

    private struct FocusedInput {
        let frame: CGRect
        let needsSuggestionFallback: Bool
    }

    private func scan() {
        let secureInput = IsSecureEventInputEnabled()
        let isTrusted = AXIsProcessTrusted()
        let displayReady = !protectedDisplayFramePoints.isNull && !protectedDisplayFramePoints.isEmpty
        let visibleWindows = displayReady ? visibleWindowsOnProtectedDisplay() : nil
        guard isTrusted,
              displayReady,
              let visibleWindows
        else {
            publishUnavailable(secureInput: secureInput)
            return
        }

        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, Self.messagingTimeout)
        if let focusedApplication = elementAttribute(system, kAXFocusedApplicationAttribute as CFString) {
            refreshFocusedApplicationObserver(for: focusedApplication)
        }

        let deadline = DispatchTime.now().uptimeNanoseconds + Self.maximumScanDurationNanoseconds
        var rects: [CGRect] = []
        var suggestionSurfaceRects: [CGRect] = []
        var focusedInput: FocusedInput?
        var summaryNodes: [SummaryNode] = []
        var unframedSensitiveContent = false
        var unavailableWindow = false
        var visited = 0
        var seen: [CFHashCode: [AXUIElement]] = [:]

        var processOrder: [pid_t] = []
        for visibleWindow in visibleWindows where !processOrder.contains(visibleWindow.processID) {
            processOrder.append(visibleWindow.processID)
        }

        for processID in processOrder {
            guard !scanLimitReached(visited: visited, deadline: deadline) else { break }
            let descriptors = visibleWindows.filter { $0.processID == processID }
            let application = AXUIElementCreateApplication(processID)
            AXUIElementSetMessagingTimeout(application, Self.messagingTimeout)
            let applicationWindows = elementArrayAttribute(application, kAXWindowsAttribute as CFString)
            let matchedWindows = applicationWindows.filter { window in
                guard let frame = elementFrame(window) else { return false }
                return descriptors.contains { framesOverlapForSameWindow(frame, $0.frame) }
            }
            guard !matchedWindows.isEmpty else {
                // Do not replace the display with a full-screen mask. The frame
                // publisher pauses and keeps the last already-redacted frame
                // until this visible window becomes inspectable again.
                unavailableWindow = true
                break
            }

            let runningApplication = NSRunningApplication(processIdentifier: processID)
            let focusedElement = elementAttribute(application, kAXFocusedUIElementAttribute as CFString)
            for window in matchedWindows {
                guard let windowFrame = elementFrame(window) else {
                    unavailableWindow = true
                    break
                }
                let visibleRegions = descriptors
                    .filter { framesOverlapForSameWindow(windowFrame, $0.frame) }
                    .flatMap(\.visibleRegions)
                let privateContext = StaticPrivacyPolicy.isPrivateContext(
                    applicationName: runningApplication?.localizedName,
                    bundleIdentifier: runningApplication?.bundleIdentifier,
                    windowTitle: stringAttribute(window, kAXTitleAttribute as CFString)
                )
                walk(
                    window,
                    depth: 0,
                    focusedElement: focusedElement,
                    privateContext: privateContext,
                    visibleRegions: visibleRegions,
                    deadline: deadline,
                    visited: &visited,
                    seen: &seen,
                    rects: &rects,
                    suggestionSurfaceRects: &suggestionSurfaceRects,
                    focusedInput: &focusedInput,
                    unframedSensitiveContent: &unframedSensitiveContent,
                    summary: &summaryNodes
                )
                if scanLimitReached(visited: visited, deadline: deadline) { break }
            }
        }

        if let focusedInput {
            let nearbySuggestionSurfaces = suggestionSurfaceRects.filter {
                InputPrivacyPolicy.shouldRedactSuggestionSurface($0, near: focusedInput.frame)
            }
            if !nearbySuggestionSurfaces.isEmpty {
                rects.append(contentsOf: nearbySuggestionSurfaces)
            } else if focusedInput.needsSuggestionFallback {
                rects.append(InputPrivacyPolicy.fallbackSuggestionFrame(under: focusedInput.frame))
            }
        }

        let scanIncomplete = scanLimitReached(visited: visited, deadline: deadline)
        let protectionUnavailable = unavailableWindow || unframedSensitiveContent || scanIncomplete
            || (secureInput && rects.isEmpty)
        let redactionRects = Self.deduplicated(rects)
        let safeSummary = summaryNodes.map { summaryNode in
            var payload = summaryNode.payload
            if summaryNode.privacyProtected || (summaryNode.frame.map { frame in
                redactionRects.contains(where: { $0.intersects(frame) })
            } ?? false) {
                payload.removeValue(forKey: "title")
                payload["privacy_protected"] = true
            }
            return payload
        }
        let summary = Self.compactJSON(safeSummary, maximumBytes: 8 * 1_024)
        store.update(RedactionSnapshot(
            axRects: redactionRects,
            secureInputEnabled: secureInput,
            protectionUnavailable: protectionUnavailable,
            axSummary: protectionUnavailable ? nil : summary
        ))
    }

    private func walk(
        _ element: AXUIElement,
        depth: Int,
        focusedElement: AXUIElement?,
        privateContext: Bool,
        visibleRegions: [CGRect],
        deadline: UInt64,
        visited: inout Int,
        seen: inout [CFHashCode: [AXUIElement]],
        rects: inout [CGRect],
        suggestionSurfaceRects: inout [CGRect],
        focusedInput: inout FocusedInput?,
        unframedSensitiveContent: inout Bool,
        summary: inout [SummaryNode]
    ) {
        guard depth <= Self.maximumDepth,
              !scanLimitReached(visited: visited, deadline: deadline)
        else { return }
        let elementHash = CFHash(element)
        if seen[elementHash]?.contains(where: { CFEqual($0, element) }) == true { return }
        seen[elementHash, default: []].append(element)
        visited += 1
        guard let attributes = elementAttributes(element) else { return }
        if let frame = attributes.frame,
           !visibleRegions.contains(where: { $0.intersects(frame) }) {
            return
        }
        let role = attributes.role
        let subrole = attributes.subrole
        let titleParts = [attributes.title, attributes.description, attributes.placeholder].compactMap { $0 }
        let label = titleParts.joined(separator: " ")
        let frame = attributes.frame
        let isFocused = attributes.isFocused || focusedElement.map { CFEqual($0, element) } == true
        let isEditable = InputPrivacyPolicy.isEditable(
            role: role,
            subrole: subrole,
            reportsEditable: attributes.isEditable
        )
        let hasNonEmptyValue = isEditable && elementHasNonEmptyTextValue(element)
        let shouldRedactInput = InputPrivacyPolicy.shouldRedactEditable(
            role: role,
            subrole: subrole,
            reportsEditable: attributes.isEditable,
            isFocused: isFocused,
            hasNonEmptyValue: hasNonEmptyValue
        ) || (role == (kAXTextFieldRole as String) && SensitiveTextPolicy.isSensitiveField(label: label))
        if shouldRedactInput, let frame {
            rects.append(frame)
        }
        let visibleStaticText = isEditable
            ? label
            : (titleParts + [attributes.value].compactMap { $0 }).joined(separator: " ")
        let shouldRedactStaticText = !isEditable
            && StaticPrivacyPolicy.mayDirectlyRedactSensitiveText(
                role: role,
                hasChildren: !attributes.children.isEmpty
            )
            && StaticPrivacyPolicy.containsSensitiveContent(visibleStaticText)
        let shouldRedactSensitiveVisual = role == (kAXImageRole as String)
            && StaticPrivacyPolicy.containsSensitiveVisualDescription(visibleStaticText)
        let shouldRedactPrivateContent = StaticPrivacyPolicy.shouldRedactElement(
            role: role,
            hasChildren: !attributes.children.isEmpty,
            inPrivateContext: privateContext
        )
        if shouldRedactStaticText || shouldRedactSensitiveVisual || shouldRedactPrivateContent {
            if let frame {
                rects.append(frame)
            } else {
                unframedSensitiveContent = true
            }
        }
        if isEditable, isFocused, let frame {
            focusedInput = FocusedInput(
                frame: frame,
                needsSuggestionFallback: InputPrivacyPolicy.shouldUseSuggestionFallback(
                    subrole: subrole,
                    label: label,
                    inPrivateContext: privateContext
                )
            )
        }
        if InputPrivacyPolicy.isSuggestionSurface(role: role), let frame {
            suggestionSurfaceRects.append(frame)
        }

        if depth <= 4, summary.count < 350 {
            var node: [String: Any] = ["role": role]
            if !subrole.isEmpty { node["subrole"] = subrole }
            if !visibleStaticText.isEmpty { node["title"] = String(visibleStaticText.prefix(300)) }
            if let frame {
                node["frame"] = ["x": frame.minX, "y": frame.minY, "w": frame.width, "h": frame.height]
            }
            node["depth"] = depth
            summary.append(SummaryNode(
                payload: node,
                frame: frame,
                privacyProtected: shouldRedactInput || shouldRedactStaticText
                    || shouldRedactSensitiveVisual || shouldRedactPrivateContent
            ))
        }
        for child in attributes.children {
            walk(
                child,
                depth: depth + 1,
                focusedElement: focusedElement,
                privateContext: privateContext,
                visibleRegions: visibleRegions,
                deadline: deadline,
                visited: &visited,
                seen: &seen,
                rects: &rects,
                suggestionSurfaceRects: &suggestionSurfaceRects,
                focusedInput: &focusedInput,
                unframedSensitiveContent: &unframedSensitiveContent,
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
        let value: String?
        let frame: CGRect?
        let isFocused: Bool
        let isEditable: Bool
        let children: [AXUIElement]
    }

    private func elementAttributes(_ element: AXUIElement) -> ElementAttributes? {
        let names: [CFString] = [
            kAXRoleAttribute as CFString,
            kAXSubroleAttribute as CFString,
            kAXTitleAttribute as CFString,
            kAXDescriptionAttribute as CFString,
            "AXPlaceholderValue" as CFString,
            kAXValueAttribute as CFString,
            kAXPositionAttribute as CFString,
            kAXSizeAttribute as CFString,
            kAXVisibleChildrenAttribute as CFString,
            kAXFocusedAttribute as CFString,
            "AXEditable" as CFString,
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

        let visibleChildren = values[8] as? [AXUIElement]
        return ElementAttributes(
            role: values[0] as? String ?? "",
            subrole: values[1] as? String ?? "",
            title: values[2] as? String,
            description: values[3] as? String,
            placeholder: values[4] as? String,
            value: stringValue(values[5]),
            frame: frame(positionValue: values[6], sizeValue: values[7]),
            isFocused: booleanValue(values[9]),
            isEditable: booleanValue(values[10]),
            // Some accessibility providers do not implement AXVisibleChildren.
            // Fall back only when it is unsupported, not when it is a valid
            // empty array, so off-screen virtualized nodes stay out of the walk.
            children: visibleChildren
                ?? elementArrayAttribute(element, kAXChildrenAttribute as CFString)
        )
    }

    private func elementHasNonEmptyTextValue(_ element: AXUIElement) -> Bool {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXValueAttribute as CFString, &value) == .success,
              let value
        else { return false }
        if let string = value as? String { return !string.isEmpty }
        if let attributedString = value as? NSAttributedString { return !attributedString.string.isEmpty }
        return false
    }

    private func booleanValue(_ value: Any) -> Bool {
        (value as? NSNumber)?.boolValue ?? false
    }

    private func stringValue(_ value: Any) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSAttributedString { return value.string }
        return nil
    }

    private func visibleWindowsOnProtectedDisplay() -> [VisibleWindow]? {
        guard let windowInfo = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[CFString: Any]] else { return nil }
        var coveredRegions: [CGRect] = []
        var result: [VisibleWindow] = []
        for info in windowInfo {
            guard let processID = (info[kCGWindowOwnerPID] as? NSNumber)?.int32Value,
                  processID > 0,
                  processID != getpid(),
                  (info[kCGWindowLayer] as? NSNumber)?.intValue == 0,
                  (info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1 > 0,
                  let rawBounds = info[kCGWindowBounds] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: rawBounds),
                  bounds.width > 1,
                  bounds.height > 1,
                  bounds.intersects(protectedDisplayFramePoints)
            else { continue }
            let runningApplication = NSRunningApplication(processIdentifier: processID)
            guard !CapturePrivacyPolicy.shouldExcludeApplication(
                bundleIdentifier: runningApplication?.bundleIdentifier
            ) else { continue }
            let clipped = bounds.intersection(protectedDisplayFramePoints)
            let visibleRegions = coveredRegions.reduce([clipped]) { regions, cover in
                regions.flatMap { subtract(cover, from: $0) }
            }
            guard !visibleRegions.isEmpty else { continue }
            result.append(VisibleWindow(
                processID: processID,
                frame: bounds,
                visibleRegions: visibleRegions
            ))
            if ((info[kCGWindowAlpha] as? NSNumber)?.doubleValue ?? 1) >= 0.99 {
                coveredRegions.append(clipped)
            }
        }
        return result
    }

    private func subtract(_ cover: CGRect, from source: CGRect) -> [CGRect] {
        let intersection = source.intersection(cover)
        guard !intersection.isNull, !intersection.isEmpty else { return [source] }
        guard intersection != source else { return [] }
        var pieces: [CGRect] = []
        if source.minY < intersection.minY {
            pieces.append(CGRect(
                x: source.minX,
                y: source.minY,
                width: source.width,
                height: intersection.minY - source.minY
            ))
        }
        if intersection.maxY < source.maxY {
            pieces.append(CGRect(
                x: source.minX,
                y: intersection.maxY,
                width: source.width,
                height: source.maxY - intersection.maxY
            ))
        }
        let middleMinY = max(source.minY, intersection.minY)
        let middleMaxY = min(source.maxY, intersection.maxY)
        if source.minX < intersection.minX, middleMinY < middleMaxY {
            pieces.append(CGRect(
                x: source.minX,
                y: middleMinY,
                width: intersection.minX - source.minX,
                height: middleMaxY - middleMinY
            ))
        }
        if intersection.maxX < source.maxX, middleMinY < middleMaxY {
            pieces.append(CGRect(
                x: intersection.maxX,
                y: middleMinY,
                width: source.maxX - intersection.maxX,
                height: middleMaxY - middleMinY
            ))
        }
        return pieces.filter { !$0.isEmpty && !$0.isNull }
    }

    private func framesOverlapForSameWindow(_ accessibilityFrame: CGRect, _ compositorFrame: CGRect) -> Bool {
        let tolerance: CGFloat = 16
        return accessibilityFrame.insetBy(dx: -tolerance, dy: -tolerance).intersects(compositorFrame)
    }

    private func publishUnavailable(secureInput: Bool) {
        store.update(RedactionSnapshot(
            axRects: [],
            secureInputEnabled: secureInput,
            protectionUnavailable: true,
            axSummary: nil
        ))
    }

    private static func deduplicated(_ rects: [CGRect]) -> [CGRect] {
        var result: [CGRect] = []
        for rect in rects where !rect.isNull && !rect.isEmpty {
            let integral = rect.integral
            if !result.contains(where: { $0 == integral }) {
                result.append(integral)
            }
        }
        return result
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

    private func requestScan() {
        queue.async { [weak self] in
            guard self?.isRunning == true else { return }
            autoreleasepool { self?.scan() }
        }
    }

    private func refreshFocusedApplicationObserver(for app: AXUIElement) {
        var processID: pid_t = 0
        guard AXUIElementGetPid(app, &processID) == .success, processID > 0 else { return }
        guard processID != observedProcessID else { return }

        removeFocusedApplicationObserver()
        var observer: AXObserver?
        guard AXObserverCreate(processID, Self.observerCallback, &observer) == .success,
              let observer
        else { return }

        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for notification in [
            kAXFocusedUIElementChangedNotification,
            kAXFocusedWindowChangedNotification,
            kAXWindowCreatedNotification,
        ] {
            _ = AXObserverAddNotification(observer, app, notification as CFString, refcon)
        }
        focusedApplicationObserver = observer
        observedProcessID = processID
        let source = AXObserverGetRunLoopSource(observer)
        DispatchQueue.main.async {
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }

    private func removeFocusedApplicationObserver() {
        guard let observer = focusedApplicationObserver else {
            observedProcessID = nil
            return
        }
        focusedApplicationObserver = nil
        observedProcessID = nil
        let source = AXObserverGetRunLoopSource(observer)
        DispatchQueue.main.async {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
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

    private func elementFrame(_ element: AXUIElement) -> CGRect? {
        var position: CFTypeRef?
        var size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, kAXPositionAttribute as CFString, &position) == .success,
              AXUIElementCopyAttributeValue(element, kAXSizeAttribute as CFString, &size) == .success,
              let position,
              let size
        else { return nil }
        return frame(positionValue: position, sizeValue: size)
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
