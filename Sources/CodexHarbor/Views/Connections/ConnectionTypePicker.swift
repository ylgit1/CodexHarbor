import SwiftUI

struct HarborConnectionTypePicker: View {
    let onChooseAccount: () -> Void
    let onChooseHosted: () -> Void
    let onChooseAPI: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("新建连接")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            }

            HStack(spacing: 10) {
                choice(
                    "账户",
                    detail: "官方 ChatGPT 账户登录",
                    icon: "person.crop.circle.fill",
                    color: HarborColors.blue,
                    action: onChooseAccount
                )

                choice(
                    "托管密钥",
                    detail: "使用 Harbor 托管连接",
                    icon: "key.fill",
                    color: .teal,
                    action: onChooseHosted
                )

                choice(
                    "自定义 API",
                    detail: "Responses API 兼容服务",
                    icon: "network",
                    color: HarborColors.purple,
                    action: onChooseAPI
                )
            }
        }
        .padding(24)
        .frame(width: 650)
        .onExitCommand(perform: onClose)
    }

    private func choice(
        _ title: String,
        detail: String,
        icon: String,
        color: Color,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 44, height: 44)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 13.5, weight: .semibold))
                    Text(detail)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(color.opacity(0.8))
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 74)
            .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.20)))
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: color, cornerRadius: 12))
    }
}
