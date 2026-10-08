import SwiftUI
import AppKit

struct HarborSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: ChatGPTBridgeViewModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                HarborCard(padding: 0) {
                    VStack(spacing: 0) {
                        sectionHeader("本地服务")
                        toggleRow(
                            "登录时启动本地服务",
                            isOn: Binding(
                                get: { bridge.configuration.launchAtLogin },
                                set: { value in Task { await bridge.setLaunchAtLogin(value) } }
                            )
                        )
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        toggleRow(
                            "可信项目开发",
                            subtitle: "对已信任目录自动执行文件修改、构建和本地项目脚本。项目脚本以当前用户权限运行，可能执行任意操作；只信任自己确认过的源码。",
                            isOn: Binding(
                                get: { bridge.trustedDevelopmentEnabled },
                                set: { value in Task { await bridge.setTrustedDevelopment(value) } }
                            )
                        )
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        toggleRow(
                            "完全授权（高风险）",
                            subtitle: "旧版兼容：直接放开 Shell、文件修改和 Git Push，仅适合明确需要的场景，不建议日常启用。",
                            isOn: Binding(
                                get: { bridge.unrestrictedDevelopmentAccessEnabled },
                                set: { value in Task { await bridge.setUnrestrictedDevelopmentAccess(value) } }
                            )
                        )

                        Divider().opacity(0.4).padding(.horizontal, 16)

                        sectionHeader("应用")
                        valueRow(
                            "版本",
                            value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                        )
                        Divider().opacity(0.4).padding(.leading, 16)
                        actionRow("GitHub", value: "ylgit1/CodexHarbor") {
                            guard let url = URL(string: "https://github.com/ylgit1/CodexHarbor") else { return }
                            NSWorkspace.shared.open(url)
                        }
                        Divider().opacity(0.4).padding(.leading, 16)
                        actionRow("开源许可", value: "查看项目许可") {
                            guard let url = URL(string: "https://github.com/ylgit1/CodexHarbor") else { return }
                            NSWorkspace.shared.open(url)
                        }
                    }
                }
                .frame(maxWidth: 760)
            }
            .frame(maxWidth: 1220, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }

    private func sectionHeader(_ title: String) -> some View {
        HStack {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .frame(height: 40, alignment: .bottom)
    }

    private func toggleRow(
        _ title: String,
        subtitle: String? = nil,
        isOn: Binding<Bool>
    ) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 11.5, weight: .medium))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer()
            Toggle(title, isOn: isOn)
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: subtitle == nil ? 50 : 60)
    }

    private func valueRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 11.5, weight: .medium))
        .padding(.horizontal, 16)
        .frame(height: 48)
    }

    private func actionRow(_ title: String, value: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                Text(value)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.tertiary)
            }
            .font(.system(size: 11.5, weight: .medium))
            .padding(.horizontal, 16)
            .frame(height: 48)
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 9))
    }
}
