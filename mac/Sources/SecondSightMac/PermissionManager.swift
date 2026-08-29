import AppKit
import ApplicationServices
import AVFoundation
import Combine
import CoreGraphics
import Speech

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
            _ = CGRequestScreenCaptureAccess()
            refresh()
        case .accessibility:
            let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
            _ = AXIsProcessTrustedWithOptions(options)
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
