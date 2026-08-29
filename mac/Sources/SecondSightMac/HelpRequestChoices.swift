import SecondSightCore
import SwiftUI

struct HelpRequestChoices: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
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
        !model.permissions.allAuthorized || model.isPreparingHelp
    }
}
