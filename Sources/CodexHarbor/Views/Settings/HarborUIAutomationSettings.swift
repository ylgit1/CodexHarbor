import AppKit
import SwiftUI

/// GUI access is requested only when an MCP UI tool first targets an app.
/// This page explains the system prerequisite, not an app allowlist editor.
struct HarborUIAutomationSettings: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("界面自动化")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button("打开辅助功能设置") {
                    guard let url = URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
                    else { return }
                    NSWorkspace.shared.open(url)
                }
                .buttonStyle(HarborActionButtonStyle(
                    tint: HarborColors.blue, prominence: .secondary
                ))
            }
            Text("使用时授权：AI 首次访问某个应用，会弹出授权窗口，显示应用名称、Bundle ID 及本次所需权限。读取、操作与单帧截图分别确认，无需预先配置应用列表。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("macOS 仍需单独允许 HarborChatGPTAgent 使用辅助功能；单帧截图还需要系统屏幕录制权限。敏感窗口和安全确认按钮始终禁止自动操作。")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
    }
}
