import SwiftUI
import SecondSightCore

struct RoomCodeView: View {
    let code: String
    let discoveryMode: AssistanceDiscoveryMode
    let notifiedAssistantCount: Int?

    var body: some View {
        VStack(spacing: 14) {
            if discoveryMode == .broadcast {
                ProgressView()
                    .controlSize(.large)
                Label("正在呼叫在线助手", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 24, weight: .bold))
                Text(broadcastDetail)
                    .font(.system(size: 21, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Label("请把这个号码告诉帮助您的人", systemImage: "person.2.wave.2.fill")
                    .font(.system(size: 24, weight: .bold))
            }

            Text(code)
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .tracking(8)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(.blue)

            Text(discoveryMode == .broadcast ? "备用分享码；对方接入后会自动收起" : "对方加入后，号码会自动收起")
                .font(.system(size: 21))
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .padding(22)
        .frame(maxWidth: .infinity)
        .background(.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 18))
        .accessibilityElement(children: .combine)
    }

    private var broadcastDetail: String {
        guard let notifiedAssistantCount else {
            return "在线助手可以选择响应，第一位响应者会接入"
        }
        if notifiedAssistantCount == 0 {
            return "暂时没有助手在线；广播会继续等待"
        }
        return "已通知 \(notifiedAssistantCount) 位在线助手，第一位响应者会接入"
    }
}
