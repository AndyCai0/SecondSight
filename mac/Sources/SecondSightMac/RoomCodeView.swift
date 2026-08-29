import SwiftUI
import SecondSightCore

struct RoomCodeView: View {
    let code: String
    let discoveryMode: AssistanceDiscoveryMode
    let notifiedAssistantCount: Int?
    let language: AppLanguage

    var body: some View {
        VStack(spacing: 14) {
            if discoveryMode == .broadcast {
                ProgressView()
                    .controlSize(.large)
                Label(
                    localized("正在呼叫在线助手", "Calling Online Volunteers", for: language),
                    systemImage: "antenna.radiowaves.left.and.right"
                )
                    .font(.system(size: 24, weight: .bold))
                Text(broadcastDetail)
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                Label(
                    localized(
                        "请把这个号码告诉帮助您的人",
                        "Tell this code to the person helping you",
                        for: language
                    ),
                    systemImage: "person.2.wave.2.fill"
                )
                    .font(.system(size: 24, weight: .bold))
            }

            Text(code)
                .font(.system(size: 64, weight: .heavy, design: .rounded))
                .monospacedDigit()
                .tracking(8)
                .lineLimit(1)
                .minimumScaleFactor(0.65)
                .foregroundStyle(.blue)

            Text(discoveryMode == .broadcast
                 ? localized(
                    "备用分享码；对方接入后会自动收起",
                    "Backup room code; it will hide when someone joins",
                    for: language
                 )
                 : localized(
                    "对方加入后，号码会自动收起",
                    "The code will hide when the other person joins",
                    for: language
                 ))
                .font(.system(size: 24))
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
            return localized(
                "在线助手可以选择响应，第一位响应者会接入",
                "Online volunteers can respond; the first responder will join",
                for: language
            )
        }
        if notifiedAssistantCount == 0 {
            return localized(
                "暂时没有助手在线；广播会继续等待",
                "No volunteers are online yet; the request will keep waiting",
                for: language
            )
        }
        return localized(
            "已通知 \(notifiedAssistantCount) 位在线助手，第一位响应者会接入",
            "Notified \(notifiedAssistantCount) online volunteer(s); the first responder will join",
            for: language
        )
    }
}
