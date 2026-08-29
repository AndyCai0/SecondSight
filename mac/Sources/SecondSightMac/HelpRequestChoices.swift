import SecondSightCore
import SwiftUI

struct HelpRequestChoices: View {
    @ObservedObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button {
                model.startHelp(using: .broadcast)
            } label: {
                Label("呼叫在线助手", systemImage: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .heavy))
                    .frame(maxWidth: .infinity, minHeight: 64)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isDisabled)

            Text("向所有在线助手发出求助，由愿意帮助的人选择响应。")
                .font(.system(size: 24, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Button {
                model.startHelp(using: .shareCode)
            } label: {
                Label("使用 6 位分享码", systemImage: "number.square.fill")
                    .font(.system(size: 24, weight: .bold))
                    .frame(maxWidth: .infinity, minHeight: 54)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .disabled(isDisabled)
        }
    }

    private var isDisabled: Bool {
        !model.permissions.allAuthorized || model.isPreparingHelp
    }
}
