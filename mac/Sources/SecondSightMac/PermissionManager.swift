import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Speech
import SecondSightCore
import SwiftUI

private enum PermissionGuidePresentation: Equatable {
    case permissionPrompt
    case systemSettings
}

private struct PermissionPromptGuideView: View {
    let presentation: PermissionGuidePresentation

    @ViewBuilder
    var body: some View {
        switch presentation {
        case .permissionPrompt:
            VStack(spacing: 2) {
                Image(systemName: "arrow.up")
                    .font(.system(size: 46, weight: .heavy))
                    .foregroundStyle(.orange)
                VStack(spacing: 2) {
                    Text("点击这里")
                        .font(.system(size: 30, weight: .heavy))
                    Text("打开系统设置")
                        .font(.system(size: 24, weight: .bold))
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 12)
                .background(.yellow, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        case .systemSettings:
            VStack(spacing: -8) {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("找到 SecondSightMac")
                            .font(.system(size: 30, weight: .heavy))
                        Text("打开下面的开关")
                            .font(.system(size: 26, weight: .bold))
                    }
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.black)
                .padding(.horizontal, 22)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.yellow, in: RoundedRectangle(cornerRadius: 18))
                .shadow(color: .black.opacity(0.35), radius: 10, y: 5)

                HStack {
                    Spacer()
                    Image(systemName: "arrow.down")
                        .font(.system(size: 52, weight: .heavy))
                        .foregroundStyle(.orange)
                }
                .padding(.trailing, 28)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }
}

@MainActor
private final class PermissionPromptGuideController {
    private static let systemSettingsBundleIdentifier = "com.apple.systempreferences"

    struct Context {
        let existingWindowIDs: Set<CGWindowID>
        let anchorFrame: CGRect
        let displayID: CGDirectDisplayID
    }

    private var panel: NSPanel?
    private var presentation: PermissionGuidePresentation?
    private var promptWatchTask: Task<Void, Never>?
    private var settingsWatchTask: Task<Void, Never>?
    private var panelHideTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?
    private var guidedPermissionName: String?
    private var settingsApplicationPID: pid_t?

    init() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            else { return }
            Task { @MainActor in
                guard let self else { return }
                if app.bundleIdentifier == Self.systemSettingsBundleIdentifier,
                   self.guidedPermissionName != nil {
                    self.startSystemSettingsGuide(application: app)
                } else if self.presentation == .systemSettings {
                    self.suspendSystemSettingsGuide()
                }
            }
        }
    }

    deinit {
        promptWatchTask?.cancel()
        settingsWatchTask?.cancel()
        panelHideTask?.cancel()
        expiryTask?.cancel()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
    }

    func makeContext() -> Context? {
        guard let screen = NSApp.keyWindow?.screen ?? NSApp.mainWindow?.screen ?? NSScreen.main,
              let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        else { return nil }

        let anchorFrame = NSApp.keyWindow?.frame ?? NSApp.mainWindow?.frame ?? screen.visibleFrame
        return Context(
            existingWindowIDs: visibleWindowIDs(),
            anchorFrame: anchorFrame,
            displayID: displayID
        )
    }

    func showWhenPromptAppears(using context: Context?, permissionName: String) {
        beginGuidance(for: permissionName)
        guard let context else { return }
        if let estimatedFrame = estimatedPromptFrame(displayID: context.displayID) {
            showPanel(pointingInto: estimatedFrame)
        }
        promptWatchTask = Task { [weak self] in
            for _ in 0..<40 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 250_000_000)
                guard let self else { return }
                if let promptFrame = self.findPromptFrame(using: context) {
                    self.showPanel(pointingInto: promptFrame)
                    return
                }
            }
        }
    }

    func prepareForSystemSettings(permissionName: String) {
        beginGuidance(for: permissionName)
        if let application = NSWorkspace.shared.frontmostApplication,
           application.bundleIdentifier == Self.systemSettingsBundleIdentifier {
            startSystemSettingsGuide(application: application)
        }
    }

    func permissionDidBecomeAuthorized(_ permissionName: String) {
        guard guidedPermissionName == permissionName else { return }
        dismiss()
    }

    func dismiss() {
        promptWatchTask?.cancel()
        promptWatchTask = nil
        settingsWatchTask?.cancel()
        settingsWatchTask = nil
        panelHideTask?.cancel()
        panelHideTask = nil
        expiryTask?.cancel()
        expiryTask = nil
        guidedPermissionName = nil
        settingsApplicationPID = nil
        closePanel()
    }

    private func beginGuidance(for permissionName: String) {
        dismiss()
        guidedPermissionName = permissionName
        expiryTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    private func closePanel() {
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
        presentation = nil
    }

    private func showPanel(pointingInto promptFrame: CGRect) {
        closePanel()

        let target = CGPoint(
            x: promptFrame.minX + promptFrame.width * 0.71,
            y: promptFrame.minY + promptFrame.height * 0.04
        )
        let size = CGSize(width: 280, height: 170)
        let frame = CGRect(
            x: target.x - size.width / 2,
            y: target.y + 4 - size.height,
            width: size.width,
            height: size.height
        )
        let panel = makePanel(frame: frame, presentation: .permissionPrompt)
        panel.orderFrontRegardless()
        self.panel = panel
        presentation = .permissionPrompt

        panelHideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard !Task.isCancelled else { return }
            guard self?.presentation == .permissionPrompt else { return }
            self?.closePanel()
        }
    }

    private func startSystemSettingsGuide(application: NSRunningApplication) {
        guard guidedPermissionName != nil else { return }
        if settingsApplicationPID == application.processIdentifier,
           settingsWatchTask != nil {
            return
        }

        promptWatchTask?.cancel()
        promptWatchTask = nil
        panelHideTask?.cancel()
        panelHideTask = nil
        settingsWatchTask?.cancel()
        closePanel()
        settingsApplicationPID = application.processIdentifier

        settingsWatchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                guard NSWorkspace.shared.frontmostApplication?.bundleIdentifier == Self.systemSettingsBundleIdentifier else {
                    self.suspendSystemSettingsGuide()
                    return
                }
                if let settingsFrame = self.findSystemSettingsWindow(
                    processIdentifier: application.processIdentifier
                ) {
                    let targetFrames = self.findSystemSettingsTargetFrames(
                        processIdentifier: application.processIdentifier
                    )
                    self.showSystemSettingsPanel(
                        relativeTo: settingsFrame,
                        appRowFrame: targetFrames.appRow,
                        switchFrame: targetFrames.toggle
                    )
                }
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
        }
    }

    private func suspendSystemSettingsGuide() {
        settingsWatchTask?.cancel()
        settingsWatchTask = nil
        settingsApplicationPID = nil
        closePanel()
    }

    private func showSystemSettingsPanel(
        relativeTo settingsFrame: CGRect,
        appRowFrame: CGRect?,
        switchFrame: CGRect?
    ) {
        guard let screen = screen(containing: settingsFrame) else { return }
        let frame = PermissionSettingsGuideLayout.panelFrame(
            systemSettingsFrame: settingsFrame,
            appRowFrame: appRowFrame,
            switchFrame: switchFrame,
            visibleScreenFrame: screen.visibleFrame
        )

        if let panel, presentation == .systemSettings {
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            return
        }

        closePanel()
        let panel = makePanel(frame: frame, presentation: .systemSettings)
        panel.orderFrontRegardless()
        self.panel = panel
        presentation = .systemSettings
    }

    private func makePanel(
        frame: CGRect,
        presentation: PermissionGuidePresentation
    ) -> NSPanel {
        let panel = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.level = .screenSaver
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: PermissionPromptGuideView(presentation: presentation))
        return panel
    }

    private func findPromptFrame(using context: Context) -> CGRect? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return items.compactMap { item -> CGRect? in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: bounds),
                  (320...760).contains(cgFrame.width),
                  (120...360).contains(cgFrame.height),
                  let frame = appKitFrame(from: cgFrame, displayID: context.displayID),
                  frame.intersects(context.anchorFrame.insetBy(dx: -240, dy: -240))
            else { return nil }

            let ownerBundleIdentifier = (item[kCGWindowOwnerPID as String] as? NSNumber)
                .flatMap { NSRunningApplication(processIdentifier: $0.int32Value)?.bundleIdentifier }
            guard PermissionPromptWindowPolicy.mayUseWindow(
                bundleIdentifier: ownerBundleIdentifier,
                wasVisibleBeforeRequest: context.existingWindowIDs.contains(number.uint32Value)
            ) else { return nil }
            return frame
        }
        .min { lhs, rhs in
            distance(lhs.center, context.anchorFrame.center) < distance(rhs.center, context.anchorFrame.center)
        }
    }

    private func estimatedPromptFrame(displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) else { return nil }

        let size = CGSize(width: 461, height: 181)
        return CGRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.minY + screen.frame.height * 0.60,
            width: size.width,
            height: size.height
        )
    }

    private func findSystemSettingsWindow(processIdentifier: pid_t) -> CGRect? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return items.compactMap { item -> CGRect? in
            guard (item[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == processIdentifier,
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: bounds),
                  cgFrame.width >= 560,
                  cgFrame.height >= 420
            else { return nil }
            return appKitFrame(from: cgFrame)
        }
        .max { lhs, rhs in lhs.width * lhs.height < rhs.width * rhs.height }
    }

    private func findSystemSettingsTargetFrames(
        processIdentifier: pid_t
    ) -> (appRow: CGRect?, toggle: CGRect?) {
        // Reading another app's accessibility tree is allowed only after the
        // user has already granted Accessibility permission. Never prompt here.
        guard AXIsProcessTrusted() else { return (nil, nil) }
        let application = AXUIElementCreateApplication(processIdentifier)

        var toggleVisited = 0
        let toggleFrame = findAXElementFrame(
            in: application,
            matching: "SecondSightMac_Toggle",
            depth: 0,
            visited: &toggleVisited
        ).flatMap { appKitFrame(from: $0) }

        var rowVisited = 0
        let appRowFrame = findAXElementFrame(
            in: application,
            matching: "SecondSightMac",
            depth: 0,
            visited: &rowVisited
        ).flatMap { appKitFrame(from: $0) }
        return (appRowFrame, toggleFrame)
    }

    private func findAXElementFrame(
        in element: AXUIElement,
        matching target: String,
        depth: Int,
        visited: inout Int
    ) -> CGRect? {
        guard depth <= 16, visited < 2_500 else { return nil }
        visited += 1

        let labels = [
            axStringAttribute(element, kAXTitleAttribute as CFString),
            axStringAttribute(element, kAXDescriptionAttribute as CFString),
            axStringAttribute(element, kAXValueAttribute as CFString),
            axStringAttribute(element, kAXIdentifierAttribute as CFString),
        ].compactMap { $0 }
        if labels.contains(where: { $0.localizedCaseInsensitiveContains(target) }),
           let frame = axFrameAttribute(element) {
            return frame
        }

        for child in axElementArrayAttribute(element, kAXChildrenAttribute as CFString) {
            if let frame = findAXElementFrame(
                in: child,
                matching: target,
                depth: depth + 1,
                visited: &visited
            ) {
                return frame
            }
            if visited >= 2_500 { break }
        }
        return nil
    }

    private func axElementArrayAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> [AXUIElement] {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success
        else { return [] }
        return value as? [AXUIElement] ?? []
    }

    private func axStringAttribute(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute, &value) == .success
        else { return nil }
        return value as? String
    }

    private func axFrameAttribute(_ element: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXPositionAttribute as CFString,
            &positionValue
        ) == .success,
        AXUIElementCopyAttributeValue(
            element,
            kAXSizeAttribute as CFString,
            &sizeValue
        ) == .success,
        let positionValue,
        let sizeValue,
        CFGetTypeID(positionValue) == AXValueGetTypeID(),
        CFGetTypeID(sizeValue) == AXValueGetTypeID()
        else { return nil }

        let positionAX = positionValue as! AXValue
        let sizeAX = sizeValue as! AXValue
        var position = CGPoint.zero
        var size = CGSize.zero
        guard AXValueGetValue(positionAX, .cgPoint, &position),
              AXValueGetValue(sizeAX, .cgSize, &size)
        else { return nil }
        return CGRect(origin: position, size: size)
    }

    private func visibleWindowIDs() -> Set<CGWindowID> {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return [] }
        return Set(items.compactMap {
            ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value
        })
    }

    private func appKitFrame(from cgFrame: CGRect, displayID: CGDirectDisplayID) -> CGRect? {
        guard let screen = NSScreen.screens.first(where: {
            ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID) == displayID
        }) else { return nil }

        let displayBounds = CGDisplayBounds(displayID)
        guard displayBounds.intersects(cgFrame) else { return nil }
        return CGRect(
            x: screen.frame.minX + cgFrame.minX - displayBounds.minX,
            y: screen.frame.maxY - (cgFrame.minY - displayBounds.minY) - cgFrame.height,
            width: cgFrame.width,
            height: cgFrame.height
        )
    }

    private func appKitFrame(from cgFrame: CGRect) -> CGRect? {
        let matchingDisplay = NSScreen.screens.compactMap { screen -> (CGDirectDisplayID, CGFloat)? in
            guard let displayID = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
            else { return nil }
            let intersection = CGDisplayBounds(displayID).intersection(cgFrame)
            guard !intersection.isNull else { return nil }
            return (displayID, intersection.width * intersection.height)
        }
        .max { lhs, rhs in lhs.1 < rhs.1 }

        guard let displayID = matchingDisplay?.0 else { return nil }
        return appKitFrame(from: cgFrame, displayID: displayID)
    }

    private func screen(containing frame: CGRect) -> NSScreen? {
        NSScreen.screens.max { lhs, rhs in
            let lhsIntersection = lhs.frame.intersection(frame)
            let rhsIntersection = rhs.frame.intersection(frame)
            let lhsArea = lhsIntersection.isNull ? 0 : lhsIntersection.width * lhsIntersection.height
            let rhsArea = rhsIntersection.isNull ? 0 : rhsIntersection.width * rhsIntersection.height
            return lhsArea < rhsArea
        }
    }

    private func distance(_ lhs: CGPoint, _ rhs: CGPoint) -> CGFloat {
        hypot(lhs.x - rhs.x, lhs.y - rhs.y)
    }
}

private extension CGRect {
    var center: CGPoint { CGPoint(x: midX, y: midY) }
}

@MainActor
final class PermissionManager: ObservableObject {
    enum Status: Equatable {
        case authorized
        case denied
        case notDetermined

        var label: String {
            switch self {
            case .authorized: "已允许"
            case .denied: "还没允许"
            case .notDetermined: "等待设置"
            }
        }
    }

    enum Kind: String, CaseIterable, Identifiable {
        case screen = "屏幕录制"
        case accessibility = "辅助功能"
        case microphone = "麦克风"
        case speech = "语音识别"
        var id: String { rawValue }

        var systemSettingsURL: URL? {
            let pane: String
            switch self {
            case .screen: pane = "Privacy_ScreenCapture"
            case .accessibility: pane = "Privacy_Accessibility"
            case .microphone: pane = "Privacy_Microphone"
            case .speech: pane = "Privacy_SpeechRecognition"
            }
            return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")
        }
    }

    @Published private(set) var statuses: [Kind: Status] = [:]
    @Published private(set) var screenRestartRequired = false
    private let screenWasAuthorizedAtLaunch: Bool
    private let promptGuide = PermissionPromptGuideController()
    private var timer: Timer?

    init() {
        screenWasAuthorizedAtLaunch = CGPreflightScreenCaptureAccess()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    deinit { timer?.invalidate() }

    var allGranted: Bool { Kind.allCases.allSatisfy { statuses[$0] == .authorized } }
    var allAuthorized: Bool { allGranted && !screenRestartRequired }

    func refresh() {
        let screenIsAuthorized = CGPreflightScreenCaptureAccess()
        statuses[.screen] = screenIsAuthorized ? .authorized : .denied
        if screenIsAuthorized && !screenWasAuthorizedAtLaunch {
            screenRestartRequired = true
        }
        statuses[.accessibility] = AXIsProcessTrusted() ? .authorized : .denied
        statuses[.microphone] = Self.status(AVCaptureDevice.authorizationStatus(for: .audio))
        switch SFSpeechRecognizer.authorizationStatus() {
        case .authorized: statuses[.speech] = .authorized
        case .notDetermined: statuses[.speech] = .notDetermined
        default: statuses[.speech] = .denied
        }
        for kind in Kind.allCases where statuses[kind] == .authorized {
            promptGuide.permissionDidBecomeAuthorized(kind.rawValue)
        }
    }

    func request(_ kind: Kind) {
        switch kind {
        case .screen:
            let context = promptGuide.makeContext()
            promptGuide.showWhenPromptAppears(using: context, permissionName: kind.rawValue)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                _ = CGRequestScreenCaptureAccess()
                self?.refresh()
            }
        case .accessibility:
            let context = promptGuide.makeContext()
            promptGuide.showWhenPromptAppears(using: context, permissionName: kind.rawValue)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 200_000_000)
                let options = [
                    kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true
                ] as CFDictionary
                _ = AXIsProcessTrustedWithOptions(options)
                self?.refresh()
            }
        case .microphone:
            Task {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refresh()
            }
        case .speech:
            SFSpeechRecognizer.requestAuthorization { [weak self] _ in
                Task { @MainActor in self?.refresh() }
            }
        }
    }

    func openSettings(_ kind: Kind) {
        guard let url = kind.systemSettingsURL else { return }
        promptGuide.prepareForSystemSettings(permissionName: kind.rawValue)
        NSWorkspace.shared.open(url)
    }

    func restartApplication() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", Bundle.main.bundleURL.path]
        try? process.run()
        NSApp.terminate(nil)
    }

    private static func status(_ status: AVAuthorizationStatus) -> Status {
        switch status {
        case .authorized: .authorized
        case .notDetermined: .notDetermined
        default: .denied
        }
    }
}
