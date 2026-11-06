import SwiftUI
import CodexHarborCore

struct HarborConnectionManagementView: View {
    @ObservedObject var model: AppModel
    @Binding var filter: ConnectionCatalogFilter

    let effectiveConnectionKind: CodexConnectionKind?
    let onCreate: () -> Void
    let onOpenAccount: (CodexAccountProfile) -> Void
    let onOpenProfile: (HarborProfile) -> Void
    let onRenameAccount: (CodexAccountProfile) -> Void
    let onRenameProfile: (HarborProfile) -> Void
    let onDeleteAccount: (CodexAccountProfile) -> Void
    let onDeleteProfile: (HarborProfile) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedSections: Set<ConnectionCatalogFilter> = []
    @State private var usageCardEnabled = HarborCodexUsageCard.isInstalled
    @State private var usageCardBusy = false
    @State private var usageCardMessage: String?
    @State private var usageCardError = false
    @State private var usageCardRuntime = HarborCodexUsageCard.runtimeDescription()

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("Codex 连接")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()

                    Button {
                        Task { await model.refreshConnectionHealth() }
                    } label: {
                        if model.isCheckingConnectionHealth {
                            Label("测试中", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("测试连接", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(model.isBusy || model.isCheckingConnectionHealth)

                    Button(action: onCreate) {
                        Label("新建连接", systemImage: "plus")
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                }

                HarborSegmentControl(
                    options: ConnectionCatalogFilter.allCases.map { ($0, $0.rawValue) },
                    selection: $filter
                )
                .frame(width: 360)

                usageCardSettings

                catalog
            }
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
        .task {
            // Migrate users who enabled the older injected sidebar/top mode.
            if HarborCodexUsageCard.requiresNotchMigration {
                performUsageCardAction(.enable)
            }
            while !Task.isCancelled {
                usageCardRuntime = HarborCodexUsageCard.runtimeDescription()
                try? await Task.sleep(for: .seconds(10))
            }
        }
    }

    private var usageCardSettings: some View {
        HarborCard(padding: 16) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "chart.donut.fill")
                        .font(.system(size: 18))
                        .foregroundStyle(HarborColors.blue)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Codex 套餐额度卡片")
                            .font(.system(size: 13, weight: .semibold))
                        Text("仅 ChatGPT 在前台时显示刘海额度，不占用其他 App 菜单栏")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if usageCardBusy {
                        ProgressView().controlSize(.small)
                    }
                    Toggle("启用", isOn: Binding(
                        get: { usageCardEnabled },
                        set: { enabled in performUsageCardAction(enabled ? .enable : .disable) }
                    ))
                    .labelsHidden()
                    .disabled(usageCardBusy)
                    .accessibilityLabel("启用 Codex 套餐额度显示")
                }

                HStack(spacing: 9) {
                    Label("唯一显示方式：MacBook 刘海", systemImage: "laptopcomputer")
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                    Text(usageCardEnabled ? "已开启" : "未开启")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(usageCardEnabled ? HarborColors.green : Color.secondary)
                }
                if usageCardEnabled {
                    Label(usageCardRuntime, systemImage: "waveform.path.ecg.rectangle")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Text("只有 macOS 菜单栏当前应用为 ChatGPT 时，刘海两侧才显示小圆环；切换到其他 App 立即隐藏。悬停可查看详细额度和只读重置卡数量，无需调试端口。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                if HarborCodexUsageCard.legacyPluginDetected {
                    Label("检测到旧版第三方额度插件，请先卸载，避免重复显示。", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 10))
                        .foregroundStyle(HarborColors.orange)
                }

                if let usageCardMessage {
                    Text(usageCardMessage)
                        .font(.system(size: 10))
                        .foregroundStyle(usageCardError ? HarborColors.red : Color.secondary)
                        .textSelection(.enabled)
                } else {
                    Text("完全自研 Swift 后台服务，使用 Codex App Server 获取真实额度；无需安装 Node.js 或第三方插件。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func performUsageCardAction(_ action: HarborCodexUsageCard.Action) {
        guard !usageCardBusy else { return }
        usageCardBusy = true
        usageCardError = false
        usageCardMessage = "正在处理刘海额度设置…"

        Task {
            do {
                let result = try await Task.detached(priority: .userInitiated) {
                    try HarborCodexUsageCard.perform(action)
                }.value
                usageCardEnabled = HarborCodexUsageCard.isInstalled
                UserDefaults.standard.set(usageCardEnabled, forKey: HarborCodexUsageCard.enabledKey)
                usageCardRuntime = HarborCodexUsageCard.runtimeDescription()
                usageCardMessage = result
            } catch {
                usageCardEnabled = HarborCodexUsageCard.isInstalled
                usageCardError = true
                usageCardMessage = error.localizedDescription
            }
            usageCardBusy = false
        }
    }

    private var catalog: some View {
        LazyVStack(spacing: 0) {
            if isEmpty && filter != .all {
                VStack(spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 24))
                        .foregroundStyle(HarborColors.blue)
                    Text("暂无\(filter.rawValue)连接")
                        .font(.callout.weight(.semibold))
                    Text("可使用右上角“新建连接”添加")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 154)
            }

            accountSection
            hostedSection
            apiSection
        }
        .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: HarborRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HarborRadius.card).stroke(HarborColors.cardBorder))
    }

    private var isEmpty: Bool {
        let hasAccounts = (filter == .all || filter == .account) && !model.accountProfiles.isEmpty
        let hasHosted = (filter == .all || filter == .hosted) && model.profiles.contains { $0.kind == .harbor }
        let hasAPI = (filter == .all || filter == .api) && model.profiles.contains { $0.kind == .customResponses }
        return !(hasAccounts || hasHosted || hasAPI)
    }

    @ViewBuilder
    private var accountSection: some View {
        if filter == .all || filter == .account {
            let accounts = model.accountProfiles
            if !accounts.isEmpty {
                sectionHeader("账户", count: accounts.count, section: .account)
                if !collapsedSections.contains(.account) {
                    ForEach(accounts) { profile in
                        HarborConnectionCatalogRow(
                            model: model,
                            id: profile.id,
                            name: profile.name,
                            type: profile.method.title,
                            icon: "person.crop.circle.fill",
                            providerIdentity: nil,
                            health: model.accountProfileHealth[profile.id] ?? .unchecked,
                            active: effectiveConnectionKind == .account && model.selectedAccountProfileID == profile.id,
                            show: { onOpenAccount(profile) },
                            activate: { Task { await model.switchAccount(to: profile.id) } },
                            rename: { onRenameAccount(profile) },
                            delete: { onDeleteAccount(profile) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hostedSection: some View {
        let profiles = model.profiles.filter { $0.kind == .harbor }
        if (filter == .all || filter == .hosted), !profiles.isEmpty {
            sectionHeader("托管密钥", count: profiles.count, section: .hosted)
            if !collapsedSections.contains(.hosted) {
                ForEach(profiles) { profile in
                    HarborConnectionCatalogRow(
                        model: model,
                        id: profile.id,
                        name: profile.name,
                        type: "托管密钥",
                        icon: "key.fill",
                        providerIdentity: nil,
                        health: model.apiProfileHealth[profile.id] ?? .unchecked,
                        active: effectiveConnectionKind == .harborKey && model.activeProfileID == profile.id,
                        show: { onOpenProfile(profile) },
                        activate: { Task { await model.switchProfile(to: profile.id) } },
                        rename: { onRenameProfile(profile) },
                        delete: { onDeleteProfile(profile) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var apiSection: some View {
        let profiles = model.profiles.filter { $0.kind == .customResponses }
        if (filter == .all || filter == .api), !profiles.isEmpty {
            sectionHeader("自定义 API", count: profiles.count, section: .api)
            if !collapsedSections.contains(.api) {
                ForEach(profiles) { profile in
                    HarborConnectionCatalogRow(
                        model: model,
                        id: profile.id,
                        name: profile.name,
                        type: "\(profile.provider.title) · 自定义 API",
                        icon: "globe",
                        providerIdentity: ProviderCatalog.identity(for: profile.apiBaseURL),
                        health: model.apiProfileHealth[profile.id] ?? .unchecked,
                        active: effectiveConnectionKind == .apiKey && model.activeProfileID == profile.id,
                        show: { onOpenProfile(profile) },
                        activate: { Task { await model.switchProfile(to: profile.id) } },
                        rename: { onRenameProfile(profile) },
                        delete: { onDeleteProfile(profile) }
                    )
                }
            }
        }
    }

    private func sectionHeader(
        _ title: String,
        count: Int,
        section: ConnectionCatalogFilter
    ) -> some View {
        let collapsed = collapsedSections.contains(section)

        return Button {
            if collapsed {
                collapsedSections.remove(section)
            } else {
                collapsedSections.insert(section)
            }
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text("(\(count))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(collapsed ? "展开" : "收起")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color.primary.opacity(0.018))
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
    }
}
