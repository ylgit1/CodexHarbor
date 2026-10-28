import CodexHarborCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var proxy: HarborProxyManager
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Label("Codex：\(currentConnectionTitle)", systemImage: currentConnectionIcon)
            Text(currentConnectionStatus)

            if model.errorMessage != nil {
                Button("操作未完成 · 查看详情") { showMainWindow() }
            }
            if model.requiresCodexReload {
                Button("重新载入 Codex") {
                    Task { await model.reloadCodex() }
                }
                .disabled(model.isBusy)
            }
            if proxy.requiresRecovery {
                Button("恢复系统代理设置") { proxy.clearSystemProxy() }
            }

            Divider()

            Menu("切换连接", systemImage: "arrow.triangle.2.circlepath") {
                if model.accountProfiles.isEmpty && model.profiles.isEmpty {
                    Text("尚未添加连接")
                }
                if !model.accountProfiles.isEmpty {
                    Section("账户登录") {
                        ForEach(model.accountProfiles) { profile in
                            Button {
                                Task { await model.switchAccount(to: profile.id) }
                            } label: {
                                Label(profile.name, systemImage: isActive(profile) ? "checkmark" : "person.crop.circle")
                            }
                            .disabled(model.isBusy || isActive(profile))
                        }
                    }
                }
                if !model.profiles.isEmpty {
                    Section("密钥连接") {
                        ForEach(model.profiles) { profile in
                            Button {
                                Task { await model.switchProfile(to: profile.id) }
                            } label: {
                                Label(
                                    profile.name,
                                    systemImage: isActive(profile)
                                        ? "checkmark"
                                        : (profile.kind == .harbor ? "key" : "network")
                                )
                            }
                            .disabled(model.isBusy || isActive(profile))
                        }
                    }
                }
            }

            Menu(proxyMenuTitle, systemImage: proxy.running ? "network" : "network.slash") {
                Text(proxy.status)
                if proxy.running, let node = proxy.activeNode {
                    Text("当前节点：\(node.displayName)")
                }
                if proxy.running {
                    Button("关闭代理") { Task { _ = await proxy.stop() } }
                        .disabled(proxy.busy)
                } else {
                    Button("开启代理") {
                        guard let node = proxy.selectedNode else { return }
                        Task { await proxy.activate(node.id) }
                    }
                    .disabled(proxy.selectedNode == nil || !proxy.coreInstalled || proxy.busy || proxy.requiresRecovery)
                }
            }
            Divider()

            Button("打开 Codex Harbor") {
                showMainWindow()
            }

            Button("退出 Codex Harbor") {
                NSApplication.shared.terminate(nil)
            }
        }
    }

    private var currentConnectionTitle: String {
        if model.environment.activeMode == .chatGPT {
            return model.accountProfiles.first(where: { $0.id == model.selectedAccountProfileID })?.name ?? "ChatGPT 账户"
        }
        if model.environment.activeMode == .harbor {
            if let id = model.activeProfileID,
               let profile = model.profiles.first(where: { $0.id == id }) {
                return profile.name
            }
            return "未识别的密钥连接"
        }
        return "未连接"
    }

    private var currentConnectionStatus: String {
        if model.isBusy { return "正在处理连接…" }
        if model.environment.configurationDrift { return "Codex 配置已被外部更改" }
        if model.requiresCodexReload { return "等待重新载入 Codex" }
        guard model.environment.activeMode != nil else { return "未连接" }
        if model.isCheckingConnectionHealth { return "正在检查连接…" }

        let health: ConnectionHealth?
        let checkedAt: Date?
        if model.environment.activeMode == .chatGPT, let id = model.selectedAccountProfileID {
            health = model.accountProfileHealth[id]
            checkedAt = model.accountProfileDiagnostics[id]?.checkedAt
        } else if let id = model.activeProfileID {
            health = model.apiProfileHealth[id]
            checkedAt = model.apiProfileDiagnostics[id]?.checkedAt
        } else {
            return "当前配置已生效 · 待检查"
        }

        if HarborConnectionReadiness.recentlyVerified(health: health, checkedAt: checkedAt) {
            return "当前连接已验证"
        }
        switch health {
        case .expired: return "当前连接已过期"
        case .unavailable: return "当前连接不可用"
        case .checking: return "正在检查连接…"
        default: return "当前配置已生效 · 待复检"
        }
    }

    private var currentConnectionIcon: String {
        switch model.environment.activeMode {
        case .chatGPT: "person.crop.circle.badge.checkmark"
        case .harbor: "point.3.connected.trianglepath.dotted"
        case nil: "exclamationmark.circle"
        }
    }

    private var proxyMenuTitle: String {
        if proxy.requiresRecovery { return "网络代理 · 待恢复" }
        if proxy.running && proxy.checkingConnectivity { return "网络代理 · 检测中" }
        if proxy.running && !proxy.healthy { return "网络代理 · 异常" }
        return proxy.running ? "网络代理 · 已开启" : "网络代理 · 已关闭"
    }

    private func isActive(_ profile: CodexAccountProfile) -> Bool {
        model.environment.activeMode == .chatGPT && model.selectedAccountProfileID == profile.id
    }

    private func isActive(_ profile: HarborProfile) -> Bool {
        model.environment.activeMode == .harbor && model.activeProfileID == profile.id
    }

    private func showMainWindow() {
        if let window = NSApplication.shared.windows.first(where: { $0.canBecomeKey && $0.title.contains("Codex Harbor") }) {
            window.makeKeyAndOrderFront(nil)
        } else {
            openWindow(id: "main")
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
    }
}
