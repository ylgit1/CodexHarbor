import SwiftUI
import AppKit
import ChatGPTBridgeCore

struct HarborSettingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: ChatGPTBridgeViewModel
    @ObservedObject private var environment = HarborRuntimeEnvironment.shared
    @ObservedObject private var proxy = HarborProxyManager.shared
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("设置")
                    .font(.system(size: 22, weight: .bold, design: .rounded))

                HarborCard(padding: 0) {
                    VStack(spacing: 0) {
                        sectionHeader("运行环境")
                        environmentRow("macOS 14 或更新", available:
                            ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 14,
                            detail: "系统要求")
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        environmentRow("ChatGPT 桌面版", available: environment.chatGPTDesktop,
                                       detail: "ChatGPT 接入")
                        if !environment.chatGPTDesktop {
                            HStack {
                                Text("尚未安装 ChatGPT macOS 桌面版")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("获取官方安装包") {
                                    NSWorkspace.shared.open(URL(string: "https://chatgpt.com/download/")!)
                                }
                                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                                Button("重新检测") { environment.refresh() }
                                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                            }
                            .padding(.horizontal, 16)
                            .frame(height: 41)
                        }
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        environmentRow("OpenAI 本地管道", available: environment.tunnelClient,
                                       detail: "本地管道启用时下载")
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        environmentRow("Cloudflared", available: environment.cloudflared,
                                       detail: "公网 HTTPS 启用时下载")
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        environmentRow("Xray 与路由数据", available: proxy.coreInstalled,
                                       detail: "网络代理使用")
                        Divider().opacity(0.4).padding(.horizontal, 16)
                        environmentRow("Git", available: environment.git,
                                       detail: "本地项目 Git 工具")
                        if !proxy.coreInstalled {
                            Divider().opacity(0.4).padding(.horizontal, 16)
                            HStack {
                                Text(proxy.installingCore ? "正在从应用安装包恢复 Xray" : "Xray 内置资源未就绪，可离线恢复")
                                    .font(.system(size: 10.5))
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(proxy.installingCore ? "恢复中…" : "恢复内置 Xray") {
                                    Task {
                                        await proxy.installBundledXray()
                                        environment.refresh()
                                    }
                                }
                                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                                .disabled(proxy.busy || proxy.installingCore || proxy.running || proxy.requiresRecovery)
                            }
                            .padding(.horizontal, 16)
                            .frame(minHeight: 48)
                        }
                    }
                }
                .frame(maxWidth: 760)

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

                        HarborUIAutomationSettings()
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
        .onAppear { environment.refresh() }
    }

    private func environmentRow(_ title: String, available: Bool, detail: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: available ? "checkmark.circle.fill" : "circle.dotted")
                .foregroundStyle(available ? HarborColors.green : Color.secondary)
                .font(.system(size: 12))
                .frame(width: 18)
            Text(title)
                .font(.system(size: 11.5, weight: .medium))
            Spacer()
            Text(available ? "已就绪" : "按需配置")
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(available ? HarborColors.green : Color.secondary)
            Text(detail)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .frame(width: 125, alignment: .trailing)
        }
        .padding(.horizontal, 16)
        .frame(height: 43)
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
