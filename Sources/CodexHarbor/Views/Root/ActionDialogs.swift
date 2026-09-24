import ChatGPTBridgeCore
import SwiftUI

struct HarborRenameDialog: View {
    let title: String
    let subtitle: String
    @Binding var text: String
    let onCancel: () -> Void
    let onSave: () -> Void

    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(action: onCancel) {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("连接名称")
                    .font(.system(size: 11, weight: .semibold))
                TextField("输入新的连接名称", text: $text)
                    .textFieldStyle(.plain)
                    .focused($focused)
                    .padding(.horizontal, 12)
                    .frame(height: 42)
                    .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(focused ? HarborColors.blue.opacity(0.55) : Color.primary.opacity(0.10))
                    )
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                Button("保存", action: onSave)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                    .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(HarborColors.cardBackground)
        .onAppear { focused = true }
    }
}

struct HarborToolApprovalDialog: View {
    let request: BridgeApprovalRequest
    let onDeny: () -> Void
    let onAllow: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HarborColors.orange)
                    .frame(width: 38, height: 38)
                    .background(HarborColors.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 5) {
                    Text("ChatGPT 请求执行本地操作")
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(request.summary)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let target = request.target, !target.isEmpty {
                        Text(target)
                            .font(.system(size: 9.5, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }

                Spacer()
            }

            HStack {
                Text("仅本次生效")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("拒绝", action: onDeny)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                Button("允许一次", action: onAllow)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
            }
        }
        .padding(24)
        .frame(width: 480)
        .background(HarborColors.cardBackground)
    }
}

struct HarborDestructiveConfirmDialog: View {
    let title: String
    let message: String
    var confirmTitle: String = "删除"
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash.fill")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(HarborColors.red)
                    .frame(width: 38, height: 38)
                    .background(HarborColors.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                    Text(message)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer()
            }

            HStack {
                Spacer()
                Button("取消", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                Button(confirmTitle, role: .destructive, action: onConfirm)
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .prominent))
            }
        }
        .padding(24)
        .frame(width: 440)
        .background(HarborColors.cardBackground)
    }
}
