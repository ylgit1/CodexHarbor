import AppKit
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

/// On-demand per-application approval. App identity is resolved locally from
/// the actual bundle ID, never taken from model-provided descriptive text.
struct HarborUIAppApprovalDialog: View {
    static let panelSize = CGSize(width: 500, height: 280)
    let request: BridgeApprovalRequest
    let capability: HarborUIConsentStore.Capability
    let onDeny: () -> Void
    let onAllow: () -> Bool
    @State private var saveFailed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let remaining = request.remainingSeconds(at: timeline.date)
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 10) {
                    Image(systemName: "app.badge.checkmark")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HarborColors.blue)
                        .frame(width: 34, height: 34)
                        .background(HarborColors.blue.opacity(0.09),
                                    in: RoundedRectangle(cornerRadius: 10))
                    Text("应用界面授权")
                        .font(.system(size: 16, weight: .semibold, design: .rounded))
                    Spacer()
                    Text("\(remaining) 秒")
                        .font(.system(size: 11, design: .monospaced))
                        .monospacedDigit()
                        .foregroundStyle(remaining <= 15 ? HarborColors.orange : .secondary)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text(verbatim: appName)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(1)
                    Text(verbatim: bundleID)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .lineLimit(1)
                    Divider().opacity(0.5)
                    Text(permissionTitle)
                        .font(.system(size: 12, weight: .semibold))
                    Text(permissionDetail)
                        .font(.system(size: 11))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(11)
                .background(Color.primary.opacity(0.035),
                            in: RoundedRectangle(cornerRadius: 10))

                Text(saveFailed
                     ? "授权保存失败，请重试或拒绝。"
                     : "仅授权以上应用及所列能力；其他应用和更高权限仍需单独确认。授权后同类操作无需再次询问。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(saveFailed ? HarborColors.red : .secondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: 9) {
                    Button("拒绝", role: .cancel, action: onDeny)
                        .keyboardShortcut(.cancelAction)
                        .buttonStyle(HarborActionButtonStyle(
                            tint: HarborColors.red, prominence: .secondary
                        ))
                    Spacer()
                    Button(remaining == 0 ? "已超时" : "允许此应用") {
                        saveFailed = !onAllow()
                    }
                    .buttonStyle(HarborActionButtonStyle(
                        tint: HarborColors.blue, prominence: .prominent
                    ))
                    .disabled(remaining == 0)
                }
            }
            .padding(16)
            // Use the content's intrinsic height. A fixed window height leaves
            // empty space below the buttons when the text fits on one line.
            .frame(width: Self.panelSize.width, alignment: .topLeading)
            .fixedSize(horizontal: false, vertical: true)
            .background(HarborColors.cardBackground)
        }
    }

    private var bundleID: String { request.target ?? "" }

    private var appName: String {
        if let running = NSRunningApplication.runningApplications(
            withBundleIdentifier: bundleID
        ).first?.localizedName {
            return running
        }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path)
        }
        return bundleID
    }

    private var permissionTitle: String {
        switch capability {
        case .read: return "申请权限：读取界面"
        case .control: return "申请权限：读取并操作界面"
        case .capture: return "申请权限：按需单帧截图"
        }
    }

    private var permissionDetail: String {
        switch capability {
        case .read:
            return "读取此应用的窗口、按钮、标签和可用状态；不读取密码或输入框内容。"
        case .control:
            return "读取此应用界面，并按指定控件执行点击、输入或滚动；安全敏感控件仍禁止自动操作。"
        case .capture:
            return "仅在主动调用截图工具时捕获指定窗口的一帧，包含必要的窗口定位读取；macOS 屏幕录制权限需要另外授权。"
        }
    }
}

struct HarborToolApprovalDialog: View {
    static let panelSize = CGSize(width: 500, height: 282)
    let request: BridgeApprovalRequest
    let onDeny: () -> Void
    let onAllow: () -> Void
    let onRemember: () -> Bool
    @State private var saveFailed = false

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            approvalContent(remaining: request.remainingSeconds(at: timeline.date))
        }
    }

    private func approvalContent(remaining: Int) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 9) {
                Image(systemName: "hand.raised.fill")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(HarborColors.orange)
                    .frame(width: 30, height: 30)
                    .background(HarborColors.orange.opacity(0.08),
                                in: RoundedRectangle(cornerRadius: 8))
                Text(presentation.title.isEmpty ? "授权确认" : "授权确认 · \(presentation.title)")
                    .font(.system(size: 15, weight: .semibold, design: .rounded))
                    .lineLimit(1)
                Spacer(minLength: 4)
                Text("\(remaining) 秒")
                    .font(.system(size: 11, weight: .medium, design: .monospaced))
                    .foregroundStyle(remaining <= 15 ? HarborColors.orange : .secondary)
                    .monospacedDigit()
                    .frame(width: 48, alignment: .trailing)
                    .fixedSize()
            }

            VStack(alignment: .leading, spacing: 5) {
                if !presentation.message.isEmpty {
                    Text(verbatim: presentation.message)
                        .font(.system(size: 13))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("作用位置")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .padding(.top, 6)
                ScrollView(.horizontal) {
                    Text(verbatim: presentation.location)
                        .font(.system(size: 12))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: true, vertical: false)
                        .padding(.bottom, 6)
                }
                .frame(height: 30)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 9))

            HStack(spacing: 6) {
                if saveFailed {
                    Text("无法保存授权，请选择允许本次。")
                        .foregroundStyle(HarborColors.red)
                } else if request.rememberScope != nil {
                        Text("相同项目、操作和参数，24 小时内免重复确认")
                        .foregroundStyle(.secondary)
                } else {
                    Text(remaining == 0 ? "已超时，自动拒绝" : "仅本次有效，超时自动拒绝")
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .font(.system(size: 10.5))
            .frame(minHeight: 22, alignment: .leading)

            HStack(spacing: 8) {
                Button("拒绝", role: .cancel, action: onDeny)
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(HarborActionButtonStyle(
                        tint: HarborColors.red, prominence: .secondary
                    ))
                Spacer(minLength: 0)
                Button("允许本次", action: onAllow)
                    .buttonStyle(HarborActionButtonStyle(
                        tint: HarborColors.blue, prominence: .secondary
                    ))
                    .disabled(remaining == 0)
                if request.rememberScope != nil {
                    Button("相同操作免询问") {
                        saveFailed = !onRemember()
                    }
                    .buttonStyle(HarborActionButtonStyle(
                        tint: HarborColors.blue, prominence: .prominent
                    ))
                    .disabled(remaining == 0)
                    .help("仅记住完全相同的项目、命令或文件修改及参数，24 小时有效")
                }
            }
        }
        .padding(16)
        .frame(width: Self.panelSize.width, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .background(HarborColors.cardBackground)
    }

    private var presentation: BridgeApprovalPresentation { BridgeApprovalPresentation(request: request) }
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
