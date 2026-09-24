import CodexHarborCore
import AppKit
import SwiftUI

struct MenuBarView: View {
    @ObservedObject var model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            Section("当前连接") {
                Label(currentConnectionTitle, systemImage: currentConnectionIcon)
                if model.requiresCodexReload {
                    Button("重新载入 Codex") {
                        Task { await model.reloadCodex() }
                    }
                }
            }

            Section("账户登录") {
                ForEach(model.accountProfiles) { profile in
                    Button {
                        Task {
                            await model.switchAccount(to: profile.id)
                            guard model.errorMessage == nil else { return }
                            await model.reloadCodex()
                        }
                    } label: {
                        Label(profile.name, systemImage: isActive(profile) ? "checkmark.circle.fill" : "person.crop.circle")
                    }
                    .disabled(model.isBusy || isActive(profile))
                }
                if model.accountProfiles.isEmpty {
                    Text("暂无账户")
                }
            }

            Section("密钥连接") {
                ForEach(model.profiles) { profile in
                    Button {
                        Task { await model.switchProfile(to: profile.id) }
                    } label: {
                        Label(
                            profile.name,
                            systemImage: isActive(profile)
                                ? "checkmark.circle.fill"
                                : (profile.kind == .harbor ? "key" : "network")
                        )
                    }
                    .disabled(model.isBusy || isActive(profile))
                }
                if model.profiles.isEmpty {
                    Text("暂无密钥连接")
                }
            }

            Divider()

            Button("检查所有连接") {
                Task { await model.refreshConnectionHealth() }
            }
            .disabled(model.isBusy || model.isCheckingConnectionHealth)

            Button("显示 Codex Harbor") {
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
        if let id = model.activeProfileID,
           let profile = model.profiles.first(where: { $0.id == id }) {
            return profile.name
        }
        return "未连接"
    }

    private var currentConnectionIcon: String {
        switch model.environment.activeMode {
        case .chatGPT: "person.crop.circle.badge.checkmark"
        case .harbor: "point.3.connected.trianglepath.dotted"
        case nil: "exclamationmark.circle"
        }
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
