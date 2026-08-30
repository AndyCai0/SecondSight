import AppKit
import SwiftUI

@main
struct SecondSightApp: App {
    @NSApplicationDelegateAdaptor(SecondSightApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("SecondSight") {
            MenuContentView(model: model)
                .frame(minWidth: 520, minHeight: 560)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 520, height: 760)
        .windowResizability(.contentMinSize)

        MenuBarExtra("SecondSight", systemImage: "eye.circle.fill") {
            MenuContentView(model: model)
                .frame(width: 520, height: 760)
        }
        .menuBarExtraStyle(.window)
    }
}

@MainActor
final class SecondSightApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct MenuContentView: View {
    @ObservedObject var model: AppModel
    @State private var pressingGuide = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                HStack(spacing: 16) {
                    Text("SecondSight")
                        .font(.system(size: 32, weight: .heavy))
                    Spacer()
                    Picker(
                        localized("语言", "Language", for: model.language),
                        selection: $model.language
                    ) {
                        ForEach(AppLanguage.allCases) { language in
                            Text(language.displayName).tag(language)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 210)
                    .accessibilityLabel(localized("语言", "Language", for: model.language))
                }
                Text(model.statusMessage.text(for: model.language))
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !model.permissions.allAuthorized {
                    PermissionChecklist(manager: model.permissions, language: model.language)
                }

                if let error = model.errorMessage {
                    Text(error.text(for: model.language))
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                if model.cameraNeedsSettings {
                    Button(action: model.openCameraSettings) {
                        ActionButtonLabel(title: localized(
                            "打开摄像头设置",
                            "Open Camera Settings",
                            for: model.language
                        ))
                    }
                        .buttonStyle(.borderedProminent)
                        .secondSightActionButton()
                }

                if let mediaIssue = model.mediaRecoveryMessage {
                    VStack(alignment: .leading, spacing: 12) {
                        Text(mediaIssue.text(for: model.language))
                            .font(.system(size: 24, weight: .bold))
                        Button(action: model.retryFailedMedia) {
                            ActionButtonLabel(title: localized(
                                "重新连接视频",
                                "Reconnect Video",
                                for: model.language
                            ))
                        }
                            .buttonStyle(.borderedProminent)
                            .secondSightActionButton()
                    }
                    .padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.14), in: RoundedRectangle(cornerRadius: 12))
                }

                if model.phase == .idle || model.phase == .ended {
                    HelpRequestChoices(model: model)
                } else {
                    if let code = model.roomCode, model.phase == .waiting {
                        RoomCodeView(
                            code: code,
                            discoveryMode: model.assistanceDiscoveryMode ?? .shareCode,
                            notifiedAssistantCount: model.notifiedAssistantCount,
                            language: model.language
                        )
                    }

                    if model.phase == .connected {
                        SafetyMonitoringCard(model: model)
                    }

                    if let broadcastMessage = model.broadcastMessage {
                        Text(broadcastMessage.text(for: model.language))
                            .font(.system(size: 24, weight: .semibold))
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                (model.assistanceDiscoveryMode == .broadcast ? Color.blue : Color.orange).opacity(0.14),
                                in: RoundedRectangle(cornerRadius: 12)
                            )
                    }

                    if model.aiFeaturesEnabled {
                        VStack(alignment: .leading, spacing: 10) {
                            Text(localized("AI 帮我", "AI Guidance", for: model.language))
                                .font(.system(size: 26, weight: .bold))
                            Text(model.guideStatus.text(for: model.language))
                                .font(.system(size: 24))
                            Text(model.isGuideRecording
                                 ? localized("松开就发送", "Release to send", for: model.language)
                                 : localized("按住说话", "Hold to speak", for: model.language))
                                .font(.system(size: 26, weight: .bold))
                                .frame(maxWidth: .infinity, minHeight: 58)
                                .foregroundStyle(.white)
                                .background(model.isGuideRecording ? Color.red : Color.blue, in: RoundedRectangle(cornerRadius: 16))
                                .contentShape(Rectangle())
                                .gesture(
                                    DragGesture(minimumDistance: 0)
                                        .onChanged { _ in
                                            guard !pressingGuide else { return }
                                            pressingGuide = true
                                            model.startGuideRecording()
                                        }
                                        .onEnded { _ in
                                            pressingGuide = false
                                            model.stopGuideRecording()
                                        }
                                )
                        }
                    }

                    Button(role: .destructive, action: model.endSession) {
                        ActionButtonLabel(title: localized(
                            "结束本次求助",
                            "End This Help Session",
                            for: model.language
                        ))
                    }
                    .buttonStyle(.bordered)
                    .secondSightActionButton()
                }

                Color.clear
                    .frame(height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
            .frame(maxWidth: 760, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .environment(\.locale, model.language.locale)
        .alert(
            localized("即将打开摄像头", "The Camera Is About to Turn On", for: model.language),
            isPresented: $model.isCameraConsentPresented
        ) {
            Button(
                localized("取消", "Cancel", for: model.language),
                role: .cancel,
                action: model.cancelCameraConsent
            )
            Button(
                localized("确认并进入视频通话", "Confirm and Start Video Call", for: model.language),
                action: model.confirmCameraAndStartHelp
            )
        } message: {
            Text(localized(
                "帮助您的人会同时看到您的摄像头画面和已经遮蔽敏感信息的电脑画面。您可以随时结束求助。",
                "Your volunteer will see both your camera and your computer screen with sensitive information masked. You can end the session at any time.",
                for: model.language
            ))
        }
    }
}

private struct SafetyMonitoringCard: View {
    @ObservedObject var model: AppModel

    private var isRunningOrConnecting: Bool {
        model.safetyState == .listening || model.safetyState == .connecting ||
            model.safetyState == .degraded
    }

    private var statusColor: Color {
        switch model.safetyState {
        case .listening: .green
        case .connecting, .degraded: .orange
        case .disconnected: .red
        case .off: .secondary
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: model.safetyState == .listening ? "shield.checkered" : "shield")
                    .font(.system(size: 30, weight: .bold))
                    .foregroundStyle(statusColor)
                Text(model.safetyState.headline(for: model.language))
                    .font(.system(size: 26, weight: .heavy))
                    .foregroundStyle(statusColor)
            }

            Text(model.safetyStatusMessage.text(for: model.language))
                .font(.system(size: 24, weight: .semibold))
                .fixedSize(horizontal: false, vertical: true)

            Button(action: model.toggleSafetyListening) {
                ActionButtonLabel(title: isRunningOrConnecting
                    ? localized("停止安全监听", "Stop Safety Monitoring", for: model.language)
                    : localized("开始安全监听", "Start Safety Monitoring", for: model.language))
            }
            .buttonStyle(.borderedProminent)
            .tint(isRunningOrConnecting ? .red : .green)
            .secondSightActionButton()
            .disabled(!isRunningOrConnecting && !model.isCallTransportConnected)

            VStack(alignment: .leading, spacing: 8) {
                Text(localized("实时字幕", "Live Captions", for: model.language))
                    .font(.system(size: 24, weight: .heavy))
                if model.recentTranscriptLines.isEmpty && model.livePartialTranscript.isEmpty {
                    Text(localized(
                        "开始监听后，字幕会显示在这里。",
                        "Captions will appear here after monitoring starts.",
                        for: model.language
                    ))
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(Array(model.recentTranscriptLines.enumerated()), id: \.offset) { _, line in
                        Text(localized("志愿者：", "Volunteer: ", for: model.language) + line)
                            .font(.system(size: 24, weight: .medium))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !model.livePartialTranscript.isEmpty {
                        Text(localized("志愿者：", "Volunteer: ", for: model.language) + model.livePartialTranscript)
                            .font(.system(size: 24, weight: .bold))
                            .foregroundStyle(.blue)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.background.opacity(0.7), in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(16)
        .background(statusColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(statusColor.opacity(0.7), lineWidth: 2))
    }
}

struct PermissionChecklist: View {
    @ObservedObject var manager: PermissionManager
    let language: AppLanguage
    @State private var startedKinds: Set<PermissionManager.Kind> = []

    private var completedCount: Int {
        manager.requiredKinds.filter { manager.statuses[$0] == .authorized }.count
    }

    private var currentKind: PermissionManager.Kind? {
        manager.requiredKinds.first { manager.statuses[$0] != .authorized }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text(localized("第一次使用，跟着步骤设置", "First use: follow these setup steps", for: language))
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                Text(localized(
                    "已完成 \(completedCount) / \(manager.requiredKinds.count)",
                    "Completed \(completedCount) / \(manager.requiredKinds.count)",
                    for: language
                ))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            ForEach(manager.requiredKinds) { kind in
                if manager.statuses[kind] == .authorized {
                    completedRow(kind)
                } else if kind == currentKind {
                    activeStep(kind)
                } else {
                    pendingRow(kind)
                }
            }

            if manager.allGranted && manager.screenRestartRequired {
                VStack(alignment: .leading, spacing: 12) {
                    Label(
                        localized("四项都完成了！", "All setup steps are complete!", for: language),
                        systemImage: "checkmark.circle.fill"
                    )
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.green)
                    Text(localized(
                        "最后需要重新打开一次，屏幕录制才会生效。",
                        "Restart the app once so screen recording can take effect.",
                        for: language
                    ))
                        .font(.system(size: 24, weight: .semibold))
                    Button {
                        manager.restartApplication()
                    } label: {
                        ActionButtonLabel(title: localized(
                            "重新打开 SecondSight",
                            "Restart SecondSight",
                            for: language
                        ))
                    }
                    .buttonStyle(.borderedProminent)
                    .secondSightActionButton()
                }
                .padding(16)
                .background(.green.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private func activeStep(_ kind: PermissionManager.Kind) -> some View {
        let stepNumber = (manager.requiredKinds.firstIndex(of: kind) ?? 0) + 1
        let hasStarted = startedKinds.contains(kind)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(localized("第 \(stepNumber) 步", "Step \(stepNumber)", for: language))
                    .font(.system(size: 24, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.blue, in: Capsule())
                Text(kind.displayName(for: language))
                    .font(.system(size: 26, weight: .heavy))
                Spacer()
                Text(localized("现在设置", "Set up now", for: language))
                    .font(.system(size: 24, weight: .bold))
                    .foregroundStyle(.blue)
            }

            if hasStarted {
                Text(localized(
                    "在系统设置里找到“SecondSightMac”，把右边的开关打开。打开后，本页会自动进入下一步。",
                    "Find “SecondSightMac” in System Settings and turn on the switch. This page will move to the next step automatically.",
                    for: language
                ))
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    manager.openSettings(kind)
                } label: {
                    ActionButtonLabel(title: localized(
                        "打开“\(kind.displayName(for: language))”系统设置",
                        "Open \(kind.displayName(for: language)) Settings",
                        for: language
                    ))
                }
                .buttonStyle(.borderedProminent)
                .secondSightActionButton()
            } else {
                Text(requestInstruction(for: kind))
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    startedKinds.insert(kind)
                    manager.request(kind)
                } label: {
                    ActionButtonLabel(title: localized(
                        "开始设置\(kind.displayName(for: language))",
                        "Set Up \(kind.displayName(for: language))",
                        for: language
                    ))
                }
                .buttonStyle(.borderedProminent)
                .secondSightActionButton()
            }
        }
        .font(.system(size: 24, weight: .bold))
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func requestInstruction(for kind: PermissionManager.Kind) -> String {
        switch kind {
        case .screen, .accessibility:
            localized(
                "先点下面的蓝色按钮。系统弹出提示后，请按箭头点击“打开系统设置”。",
                "Select the blue button below. When macOS asks, follow the arrow and choose “Open System Settings”.",
                for: language
            )
        case .microphone, .speech:
            localized(
                "先点下面的蓝色按钮。系统询问时，请点“允许”。",
                "Select the blue button below, then choose “Allow” when macOS asks.",
                for: language
            )
        }
    }

    private func completedRow(_ kind: PermissionManager.Kind) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(kind.displayName(for: language))
                .font(.system(size: 24, weight: .semibold))
            Spacer()
            Text(localized("已完成", "Completed", for: language))
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func pendingRow(_ kind: PermissionManager.Kind) -> some View {
        HStack {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
            Text(kind.displayName(for: language))
                .font(.system(size: 24, weight: .semibold))
            Spacer()
            Text(localized("稍后设置", "Set up later", for: language))
                .font(.system(size: 24))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
