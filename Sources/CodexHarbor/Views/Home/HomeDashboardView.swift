import SwiftUI
import CodexHarborCore
import ChatGPTBridgeCore

private enum HarborQuickConnectionTarget: Hashable {
    case account(UUID)
    case profile(UUID)
}

struct HarborHomeDashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: ChatGPTBridgeViewModel

    let effectiveConnectionKind: CodexConnectionKind?
    let activeDisplayName: String
    let connected: Bool
    let accountExpiryText: String?
    let accountExpiryColor: Color?
    let onManageConnections: (CodexConnectionKind?) -> Void
    let onOpenLocalAccess: () -> Void
    let onOpenNetworkProxy: () -> Void
    let onOpenSettings: () -> Void

    @State private var showingQuickSwitcher = false
    @State private var quickSelection: HarborQuickConnectionTarget?

    var body: some View {
        HarborTechDashboardContent(
            model: model,
            bridge: bridge,
            proxy: HarborProxyManager.shared,
            effectiveConnectionKind: effectiveConnectionKind,
            activeDisplayName: activeDisplayName,
            connected: connected,
            accountExpiryText: accountExpiryText,
            onSwitchCodex: {
                quickSelection = activeQuickConnectionTarget
                showingQuickSwitcher = true
            },
            onManageCodex: { onManageConnections(nil) },
            onOpenLocalAccess: onOpenLocalAccess,
            onOpenNetworkProxy: onOpenNetworkProxy
        )
        .popover(isPresented: $showingQuickSwitcher, arrowEdge: .top) {
            quickConnectionSwitcher
        }
    }

    private var quickConnectionSwitcher: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("切换连接")
                        .font(.system(size: 16, weight: .semibold))
                    Text("选择连接后点击“立即切换”，切换完成会自动重载 Codex。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showingQuickSwitcher = false
                    quickSelection = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            }

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("账户")
                    ForEach(model.accountProfiles) { profile in
                        switcherRow(
                            name: profile.name,
                            detail: "ChatGPT 账户",
                            icon: "person.crop.circle.fill",
                            active: effectiveConnectionKind == .account && model.selectedAccountProfileID == profile.id,
                            available: isAvailable(model.accountProfileHealth[profile.id]),
                            selected: quickSelection == .account(profile.id)
                        ) {
                            quickSelection = .account(profile.id)
                        }
                    }

                    let hosted = model.profiles.filter { $0.kind == .harbor }
                    if !hosted.isEmpty {
                        sectionTitle("托管密钥")
                        ForEach(hosted) { profile in
                            switcherRow(
                                name: profile.name,
                                detail: profile.model.isEmpty ? "托管连接" : profile.model,
                                icon: "key.fill",
                                active: effectiveConnectionKind == .harborKey && model.activeProfileID == profile.id,
                                available: isAvailable(model.apiProfileHealth[profile.id]),
                                selected: quickSelection == .profile(profile.id)
                            ) {
                                quickSelection = .profile(profile.id)
                            }
                        }
                    }

                    let custom = model.profiles.filter { $0.kind == .customResponses }
                    if !custom.isEmpty {
                        sectionTitle("自定义 API")
                        ForEach(custom) { profile in
                            switcherRow(
                                name: profile.name,
                                detail: profile.model.isEmpty ? profile.provider.title : "\(profile.provider.title) · \(profile.model)",
                                icon: "network",
                                active: effectiveConnectionKind == .apiKey && model.activeProfileID == profile.id,
                                available: isAvailable(model.apiProfileHealth[profile.id]),
                                selected: quickSelection == .profile(profile.id)
                            ) {
                                quickSelection = .profile(profile.id)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 330)

            Divider().opacity(0.35)

            HStack {
                Button("管理连接") {
                    showingQuickSwitcher = false
                    quickSelection = nil
                    onManageConnections(nil)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))

                Spacer()

                Button("取消") {
                    showingQuickSwitcher = false
                    quickSelection = nil
                }
                .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))

                Button {
                    applyQuickSelection()
                } label: {
                    if model.isBusy {
                        Label("切换中", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("立即切换", systemImage: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                .disabled(
                    quickSelection == nil
                        || quickSelection == activeQuickConnectionTarget
                        || model.isBusy
                )
            }
        }
        .padding(18)
        .frame(width: 430)
        .background(HarborColors.cardBackground)
        .presentationBackground(HarborColors.cardBackground)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func switcherRow(
        name: String,
        detail: String,
        icon: String,
        active: Bool,
        available: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HarborColors.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)

                        if active {
                            HarborStatusBadge(title: "当前使用", color: HarborColors.green)
                        }
                    }

                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !active {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(available ? HarborColors.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(available ? "可用" : "待检查")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(available ? HarborColors.green : .secondary)
                    }
                }

                Image(systemName: active ? "checkmark.circle.fill" : (selected ? "record.circle.fill" : "circle"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        active
                            ? HarborColors.green
                            : (selected ? HarborColors.blue : Color.secondary.opacity(0.34))
                    )
            }
            .padding(.horizontal, 11)
            .frame(height: 54)
            .background(
                selected
                    ? HarborColors.blue.opacity(0.13)
                    : (active ? HarborColors.green.opacity(0.045) : Color.primary.opacity(0.018)),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? HarborColors.blue.opacity(0.48) : Color.primary.opacity(0.055), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 11))
        .disabled(active)
    }

    private var activeQuickConnectionTarget: HarborQuickConnectionTarget? {
        switch effectiveConnectionKind {
        case .account:
            if let id = model.selectedAccountProfileID {
                return .account(id)
            }
        case .harborKey, .apiKey:
            if let id = model.activeProfileID {
                return .profile(id)
            }
        case nil:
            break
        }
        return nil
    }

    private func applyQuickSelection() {
        guard let quickSelection,
              quickSelection != activeQuickConnectionTarget else { return }

        Task {
            switch quickSelection {
            case let .account(id):
                await model.switchAccount(to: id)
            case let .profile(id):
                await model.switchProfile(to: id)
            }

            if model.errorMessage == nil {
                await MainActor.run {
                    showingQuickSwitcher = false
                    self.quickSelection = nil
                }
            }
        }
    }

    private func isAvailable(_ health: ConnectionHealth?) -> Bool {
        guard let health else { return false }
        if case .available = health { return true }
        return false
    }

}
