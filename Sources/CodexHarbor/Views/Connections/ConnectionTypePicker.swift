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
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 42, height: 42)
                        .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))

                    Spacer(minLength: 8)

                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(color.opacity(0.8))
                }

                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)

                Spacer(minLength: 0)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(height: 150, alignment: .topLeading)
            .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(color.opacity(0.20)))
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: color, cornerRadius: 12))
    }
}
