import SecondSightCore
import SwiftUI

struct HelpRequestChoices: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(localized(
                "您想让志愿者帮您做什么？",
                "What would you like the volunteer to help with?",
                for: model.language
            ))
                .font(.system(size: 25, weight: .bold))

            TextField(
                localized(
                    "例如：帮我在医院网站预约复诊",
                    "For example: help me book a follow-up appointment",
                    for: model.language
                ),
                text: $model.helpRequestGoal,
                axis: .vertical
            )
            .font(.system(size: 24))
            .lineLimit(2 ... 4)
            .textFieldStyle(.roundedBorder)
            .accessibilityLabel(localized(
                "本次求助目标",
                "Goal for this help session",
                for: model.language
            ))

            Text(localized(
                "这会帮助安全 AI 判断志愿者的指导是否偏离您的需求；不填写也可以继续。",
                "This helps the safety AI notice guidance that does not match your request. You may leave it blank.",
                for: model.language
            ))
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.startHelp(using: .broadcast)
            } label: {
                ActionButtonLabel(
                    title: localized("呼叫在线助手", "Call an Online Volunteer", for: model.language),
                    systemImage: "antenna.radiowaves.left.and.right"
                )
            }
            .buttonStyle(.borderedProminent)
            .secondSightActionButton()
            .disabled(isDisabled)

            Text(localized(
                "向所有在线助手发出求助，由愿意帮助的人选择响应。",
                "Send a request to every online volunteer. The first available person can respond.",
                for: model.language
            ))
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.startHelp(using: .shareCode)
            } label: {
                ActionButtonLabel(
                    title: localized("使用 6 位分享码", "Use a 6-Digit Room Code", for: model.language),
                    systemImage: "number.square.fill"
                )
            }
            .buttonStyle(.bordered)
            .secondSightActionButton()
            .disabled(isDisabled)
        }
    }

    private var isDisabled: Bool {
        !model.permissions.allAuthorized || model.isPreparingHelp || model.isEndingSession
    }
}
