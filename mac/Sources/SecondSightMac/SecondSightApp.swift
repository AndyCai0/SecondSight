import AppKit
import SwiftUI

@main
struct SecondSightApp: App {
    @NSApplicationDelegateAdaptor(SecondSightApplicationDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup("第二双眼睛") {
            MenuContentView(model: model)
                .onAppear {
                    NSApp.activate(ignoringOtherApps: true)
                }
        }
        .defaultSize(width: 520, height: 760)
        .windowResizability(.contentSize)

        MenuBarExtra("第二双眼睛", systemImage: "eye.circle.fill") {
            MenuContentView(model: model)
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
                Text("第二双眼睛")
                    .font(.system(size: 32, weight: .heavy))
                Text(model.statusMessage)
                    .font(.system(size: 24, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)

                if !model.permissions.allAuthorized {
                    PermissionChecklist(manager: model.permissions)
                }

                if let error = model.errorMessage {
                    Text(error)
                        .font(.system(size: 24, weight: .bold))
                        .foregroundStyle(.red)
                        .padding(14)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                }

                if model.phase == .idle || model.phase == .ended {
                    Button(action: model.startHelp) {
                        Label("求助", systemImage: "hand.raised.fill")
                            .font(.system(size: 30, weight: .heavy))
                            .frame(maxWidth: .infinity, minHeight: 64)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!model.permissions.allAuthorized)
                } else {
                    if let code = model.roomCode, model.phase == .waiting {
                        Text("房间号码：\(code)")
                            .font(.system(size: 32, weight: .heavy, design: .rounded))
                            .monospacedDigit()
                    }

                    VStack(alignment: .leading, spacing: 10) {
                        Text("AI 帮我")
                            .font(.system(size: 26, weight: .bold))
                        Text(model.guideStatus)
                            .font(.system(size: 24))
                        Text(model.isGuideRecording ? "松开就发送" : "按住说话")
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

                    Button(role: .destructive, action: model.endSession) {
                        Text("结束本次求助")
                            .font(.system(size: 24, weight: .bold))
                            .frame(maxWidth: .infinity, minHeight: 52)
                    }
                    .buttonStyle(.bordered)
                }

                Color.clear
                    .frame(height: 44)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 26)
            .padding(.top, 26)
        }
        .frame(width: 520, height: 760)
    }
}

struct PermissionChecklist: View {
    @ObservedObject var manager: PermissionManager
    @State private var startedKinds: Set<PermissionManager.Kind> = []

    private var completedCount: Int {
        PermissionManager.Kind.allCases.filter { manager.statuses[$0] == .authorized }.count
    }

    private var currentKind: PermissionManager.Kind? {
        PermissionManager.Kind.allCases.first { manager.statuses[$0] != .authorized }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .firstTextBaseline) {
                Text("第一次使用，跟着步骤设置")
                    .font(.system(size: 24, weight: .bold))
                Spacer()
                Text("已完成 \(completedCount) / 4")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.secondary)
            }

            ForEach(PermissionManager.Kind.allCases) { kind in
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
                    Label("四项都完成了！", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 26, weight: .heavy))
                        .foregroundStyle(.green)
                    Text("最后需要重新打开一次，屏幕录制才会生效。")
                        .font(.system(size: 24, weight: .semibold))
                    Button("重新打开第二双眼睛") {
                        manager.restartApplication()
                    }
                    .font(.system(size: 24, weight: .bold))
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .frame(maxWidth: .infinity)
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
        let stepNumber = (PermissionManager.Kind.allCases.firstIndex(of: kind) ?? 0) + 1
        let hasStarted = startedKinds.contains(kind)

        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("第 \(stepNumber) 步")
                    .font(.system(size: 20, weight: .heavy))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 5)
                    .background(.blue, in: Capsule())
                Text(kind.rawValue)
                    .font(.system(size: 26, weight: .heavy))
                Spacer()
                Text("现在设置")
                    .font(.system(size: 20, weight: .bold))
                    .foregroundStyle(.blue)
            }

            if hasStarted {
                Text("在系统设置里找到“SecondSightMac”，把右边的开关打开。打开后，本页会自动进入下一步。")
                    .font(.system(size: 23, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button("打开“\(kind.rawValue)”系统设置") {
                    manager.openSettings(kind)
                }
                .buttonStyle(.borderedProminent)
            } else {
                Text("先点下面的蓝色按钮。系统询问时，请点“允许”。")
                    .font(.system(size: 23, weight: .semibold))
                    .fixedSize(horizontal: false, vertical: true)
                Button("开始设置\(kind.rawValue)") {
                    startedKinds.insert(kind)
                    manager.request(kind)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .font(.system(size: 24, weight: .bold))
        .controlSize(.large)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
    }

    private func completedRow(_ kind: PermissionManager.Kind) -> some View {
        HStack {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(kind.rawValue)
                .font(.system(size: 24, weight: .semibold))
            Spacer()
            Text("已完成")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(.green)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }

    private func pendingRow(_ kind: PermissionManager.Kind) -> some View {
        HStack {
            Image(systemName: "circle")
                .foregroundStyle(.secondary)
            Text(kind.rawValue)
                .font(.system(size: 24, weight: .semibold))
            Spacer()
            Text("稍后设置")
                .font(.system(size: 22))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
    }
}
