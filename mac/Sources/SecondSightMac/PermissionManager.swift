import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Speech
import SwiftUI

private struct PermissionPromptGuideView: View {
    var body: some View {
        VStack(spacing: 2) {
            Image(systemName: "arrow.up")
                .font(.system(size: 46, weight: .heavy))
                .foregroundStyle(.orange)
            VStack(spacing: 2) {
                Text("点击这里")
                    .font(.system(size: 30, weight: .heavy))
                Text("打开系统设置")
                    .font(.system(size: 22, weight: .bold))
            }
            .foregroundStyle(.black)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .background(.yellow, in: RoundedRectangle(cornerRadius: 18))
            .shadow(color: .black.opacity(0.35), radius: 10, y: 5)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }
}

@MainActor
private final class PermissionPromptGuideController {
    struct Context {
        let existingWindowIDs: Set<CGWindowID>
        let anchorFrame: CGRect
        let displayID: CGDirectDisplayID
    }

    private var panel: NSPanel?
    private var watchTask: Task<Void, Never>?
    private var hideTask: Task<Void, Never>?
    private var workspaceObserver: NSObjectProtocol?

    init() {
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  app.bundleIdentifier == "com.apple.systempreferences"
            else { return }
            Task { @MainActor in self?.hide() }
        }
    }

    deinit {
        watchTask?.cancel()
        hideTask?.cancel()
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

    func showWhenPromptAppears(using context: Context?) {
        guard let context else { return }
        hide()
        watchTask = Task { [weak self] in
            for _ in 0..<12 {
                guard !Task.isCancelled else { return }
                try? await Task.sleep(nanoseconds: 200_000_000)
                guard let self else { return }
                if let promptFrame = self.findPromptFrame(using: context) {
                    self.showPanel(pointingInto: promptFrame)
                    return
                }
            }
        }
    }

    func hide() {
        watchTask?.cancel()
        watchTask = nil
        hideTask?.cancel()
        hideTask = nil
        panel?.orderOut(nil)
        panel?.close()
        panel = nil
    }

    private func showPanel(pointingInto promptFrame: CGRect) {
        panel?.close()

        let target = CGPoint(
            x: promptFrame.minX + promptFrame.width * 0.71,
            y: promptFrame.minY + promptFrame.height * 0.16
        )
        let size = CGSize(width: 280, height: 170)
        let frame = CGRect(
            x: target.x - size.width / 2,
            y: target.y + 4 - size.height,
            width: size.width,
            height: size.height
        )
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
        panel.contentView = NSHostingView(rootView: PermissionPromptGuideView())
        panel.orderFrontRegardless()
        self.panel = panel

        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 14_000_000_000)
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    private func findPromptFrame(using context: Context) -> CGRect? {
        guard let items = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else { return nil }

        return items.compactMap { item -> CGRect? in
            guard let number = item[kCGWindowNumber as String] as? NSNumber,
                  !context.existingWindowIDs.contains(number.uint32Value),
                  (item[kCGWindowLayer as String] as? NSNumber)?.intValue == 0,
                  let bounds = item[kCGWindowBounds as String] as? NSDictionary,
                  let cgFrame = CGRect(dictionaryRepresentation: bounds),
                  (320...760).contains(cgFrame.width),
                  (120...360).contains(cgFrame.height),
                  let frame = appKitFrame(from: cgFrame, displayID: context.displayID),
                  frame.intersects(context.anchorFrame.insetBy(dx: -240, dy: -240))
            else { return nil }
            return frame
        }
        .min { lhs, rhs in
            distance(lhs.center, context.anchorFrame.center) < distance(rhs.center, context.anchorFrame.center)
        }
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
    }

    func request(_ kind: Kind) {
        switch kind {
        case .screen:
            let context = promptGuide.makeContext()
            _ = CGRequestScreenCaptureAccess()
            promptGuide.showWhenPromptAppears(using: context)
            refresh()
        case .accessibility:
            let context = promptGuide.makeContext()
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
            promptGuide.showWhenPromptAppears(using: context)
            refresh()
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
        promptGuide.hide()
        guard let url = kind.systemSettingsURL else { return }
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
