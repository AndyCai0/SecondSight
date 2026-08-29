import SwiftUI

@main
struct SecondSightApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        MenuBarExtra("第二双眼睛", systemImage: "eye.circle.fill") {
            MenuContentView(model: model)
        }
        .menuBarExtraStyle(.window)

        Settings {
            PermissionGuideView(manager: model.permissions)
                .frame(minWidth: 620, minHeight: 520)
        }
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
                    SettingsLink {
                        Label("打开完整权限向导", systemImage: "gearshape.fill")
                            .font(.system(size: 24, weight: .bold))
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
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
            }
            .padding(26)
        }
        .frame(width: 520, height: 690)
    }
}

struct PermissionChecklist: View {
    @ObservedObject var manager: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("第一次使用，请先允许这四项")
                .font(.system(size: 24, weight: .bold))
            ForEach(PermissionManager.Kind.allCases) { kind in
                HStack {
                    Image(systemName: manager.statuses[kind] == .authorized ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(manager.statuses[kind] == .authorized ? .green : .orange)
                    Text(kind.rawValue).font(.system(size: 24, weight: .semibold))
                    Spacer()
                    Text(manager.statuses[kind]?.label ?? "检查中").font(.system(size: 24))
                }
            }
            Text("屏幕录制允许后，请退出并重新打开 App。")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.orange)
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }
}

struct PermissionGuideView: View {
    @ObservedObject var manager: PermissionManager

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("权限向导")
                .font(.system(size: 34, weight: .heavy))
            Text("按顺序完成。每一项都只用于屏幕保护、通话和语音指路。")
                .font(.system(size: 24))
            ForEach(PermissionManager.Kind.allCases) { kind in
                HStack(spacing: 16) {
                    Image(systemName: manager.statuses[kind] == .authorized ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 30))
                        .foregroundStyle(manager.statuses[kind] == .authorized ? .green : .secondary)
                    VStack(alignment: .leading) {
                        Text(kind.rawValue).font(.system(size: 24, weight: .bold))
                        Text(manager.statuses[kind]?.label ?? "检查中").font(.system(size: 24))
                    }
                    Spacer()
                    if manager.statuses[kind] != .authorized {
                        Button("请求允许") { manager.request(kind) }
                            .font(.system(size: 24, weight: .bold))
                            .controlSize(.large)
                        Button("打开系统设置") { manager.openSettings(kind) }
                            .font(.system(size: 24, weight: .bold))
                            .controlSize(.large)
                    }
                }
                .padding(.vertical, 8)
            }
            Text("注意：屏幕录制允许后必须重新启动 App，系统才会真正生效。")
                .font(.system(size: 24, weight: .bold))
                .foregroundStyle(.orange)
        }
        .padding(32)
    }
}
