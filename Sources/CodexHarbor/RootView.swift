import CodexHarborCore
import AppKit
import SwiftUI

private enum ProfileDeletionTarget: Identifiable {
    case account(CodexAccountProfile)
    case api(HarborProfile)

    var id: String {
        switch self {
        case let .account(profile): "account-\(profile.id.uuidString)"
        case let .api(profile): "api-\(profile.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case let .account(profile): profile.name
        case let .api(profile): profile.name
        }
    }
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @State private var showsActivationKey = false
    @State private var showsNewActivationKey = false
    @State private var newActivationKey = ""
    @State private var newProfileAPIBaseURL = HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
    @State private var showsActivationSheet = false
    @State private var showsAccountSetupSheet = false
    @State private var showsCustomAPISheet = false
    @State private var showsSessionManager = false
    @State private var customAPIName = ""
    @State private var customAPIKey = ""
    @State private var customAPIProvider: CustomAPIProvider = .openAI
    @State private var customAPIBaseURL = CustomAPIProvider.openAI.defaultBaseURL
    @State private var customAPIModel = ""
    @State private var showsCustomAPIKey = false
    @State private var deletionTarget: ProfileDeletionTarget?
    @State private var libraryMode: CodexConnectionKind = .harborKey

    var body: some View {
        content
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showsActivationSheet) {
            activationSheet
        }
        .sheet(isPresented: $showsAccountSetupSheet) {
            accountSetupSheet
        }
        .sheet(isPresented: $showsCustomAPISheet) {
            customAPISheet
        }
        .sheet(isPresented: $showsSessionManager) { SessionManagerView(model: model).frame(minWidth: 650, minHeight: 440).padding(20) }
        .confirmationDialog(
            "删除连接档案？",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteSelectedProfile() }
            Button("取消", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("将删除“\(deletionTarget?.name ?? "")”及其本地凭据；Codex 会话记录不会被删除。")
        }
        .onChange(of: model.environment.apiBaseURL) {
            guard newActivationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let apiBaseURL = model.environment.apiBaseURL else { return }
            newProfileAPIBaseURL = apiBaseURL.absoluteString
        }
        .onChange(of: showsAccountSetupSheet) {
            if showsAccountSetupSheet {
                model.resetAccountLoginFlow()
            }
        }
        .onChange(of: model.environment.activeMode) {
            if let activeMode = model.environment.activeMode {
                if activeMode == .chatGPT {
                    libraryMode = .account
                } else if let activeKind = activeHarborProfile?.kind.connectionKind {
                    libraryMode = activeKind
                } else {
                    libraryMode = .harborKey
                }
            }
        }
        .onChange(of: model.activeProfileID) {
            guard model.environment.activeMode == .harbor,
                  let activeKind = activeHarborProfile?.kind.connectionKind else { return }
            libraryMode = activeKind
        }
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            ScrollView(.vertical) {
                connectionDashboard
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)
            logCard
        }
        .padding(24)
        .frame(maxWidth: 980, maxHeight: .infinity, alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
            .frame(width: 46, height: 46)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 9) {
                    Text("Codex Harbor")
                        .font(.headline)
                    Text(effectiveMode == nil ? "连接你的 Codex" : "Codex 已就绪")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
                Text(effectiveMode == nil
                     ? "添加账户、托管密钥或自定义 API 密钥，然后明确选择连接。"
                     : "管理三类连接，并查看每个连接的可用状态。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer()
            Button { showsSessionManager = true; Task { await model.refreshSessions() } } label: { Label("会话管理", systemImage: "rectangle.3.group") }.buttonStyle(.bordered)
            statusPill
        }
    }

    private var effectiveMode: CodexMode? {
        model.environment.activeMode
            ?? (model.environment.chatGPTSessionExists ? .chatGPT : nil)
    }

    private var activeModeTitle: String {
        switch effectiveMode {
        case .harbor: "\(activeHarborProfile?.kind.title ?? CodexConnectionKind.harborKey.title) · \(selectedProfileName)"
        case .chatGPT: model.accountProfiles.first(where: { $0.id == model.selectedAccountProfileID })?.name ?? "Codex 账户"
        case nil: "未连接"
        }
    }

    private var activeModeIcon: String {
        switch effectiveMode {
        case .harbor: "network"
        case .chatGPT: "person.crop.circle.badge.checkmark"
        case nil: "exclamationmark.circle"
        }
    }

    private var activeModeColor: Color {
        switch effectiveMode {
        case .harbor: .blue
        case .chatGPT: .green
        case nil: .orange
        }
    }

    private var activeModeDetail: String {
        switch effectiveMode {
        case .harbor:
            return "使用当前托管供应商连接"
        case .chatGPT:
            return "使用当前 \(model.environment.accountMethod?.title ?? "Codex 账户") 连接"
        case nil:
            return "请选择一个可用账户或 API 密钥"
        }
    }

    private var effectiveConnectionKind: CodexConnectionKind? {
        switch effectiveMode {
        case .chatGPT: .account
        case .harbor: activeHarborProfile?.kind.connectionKind ?? .harborKey
        case nil: nil
        }
    }

    private func modeSelector(mode: CodexConnectionKind, title: String, icon: String) -> some View {
        let selected = libraryMode == mode
        let active = effectiveConnectionKind == mode
        return Button {
            libraryMode = mode
        } label: {
            HStack(spacing: 7) {
                Image(systemName: icon)
                Text(title)
                if active {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 8, height: 8)
                        .overlay(Circle().stroke(Color.white.opacity(0.9), lineWidth: 1.5))
                        .accessibilityLabel("当前已激活")
                }
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(selected ? Color.white : Color.primary)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(selected ? Color.accentColor : Color(nsColor: .controlBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(selected ? Color.clear : Color.secondary.opacity(0.18)))
        }
        .buttonStyle(.plain)
        .disabled(model.isBusy)
        .help(active ? "当前正在使用；点击查看档案" : "查看\(title)档案")
    }

    private var selectedProfileName: String {
        model.profiles.first(where: { $0.id == model.selectedProfileID })?.name ?? "密钥档案"
    }

    private var connectionDashboard: some View {
        VStack(alignment: .leading, spacing: 14) {
            profileLibrary
            currentConnectionCard
        }
    }

    private var profileLibrary: some View {
        card {
            VStack(alignment: .leading, spacing: 13) {
                HStack(alignment: .center, spacing: 10) {
                    Label("连接管理", systemImage: "point.3.connected.trianglepath.dotted")
                        .font(.headline)
                    Spacer()
                    Label("本地保护", systemImage: "lock.shield.fill")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                    HStack(spacing: 6) {
                        modeSelector(mode: .account, title: "账户登录", icon: "person.crop.circle.fill")
                        modeSelector(mode: .harborKey, title: "托管密钥", icon: "key.fill")
                        modeSelector(mode: .apiKey, title: "自定义 API 密钥", icon: "network")
                    }
                }

                Divider()

                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(libraryMode.title)
                            .font(.caption.weight(.semibold))
                        Text(libraryMode == .account
                             ? "切换 Codex 当前使用的登录凭据"
                             : (libraryMode == .harborKey ? "切换 Codex 当前使用的托管凭据" : "切换 Codex 当前使用的 API 凭据"))
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    profileLibraryAction
                }

                if libraryMode == .account {
                    if model.accountProfiles.isEmpty {
                        profileEmptyState(
                            title: "还没有 Codex 账户",
                            detail: "点击“添加账户”，通过 Codex 官方登录保存第一个账户。"
                        )
                    } else {
                        LazyVGrid(
                            columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 9)],
                            alignment: .leading,
                            spacing: 9
                        ) {
                            ForEach(model.accountProfiles) { profile in
                                let isCurrent = model.selectedAccountProfileID == profile.id
                                let isActive = isCurrent && model.environment.activeMode == .chatGPT
                                profileRow(
                                    title: profile.name,
                                    subtitle: profile.method.title,
                                    icon: "person.crop.circle.fill",
                                    color: .green,
                                    selected: isActive,
                                    health: model.accountProfileHealth[profile.id] ?? .unchecked,
                                    selectionDisabled: isActive,
                                    deletionTarget: .account(profile),
                                    deletionDisabled: isActive,
                                    action: { Task { await model.switchAccount(to: profile.id) } }
                                )
                            }
                        }
                    }
                } else if model.profiles.filter({ $0.kind.connectionKind == libraryMode }).isEmpty {
                    profileEmptyState(
                        title: "没有可用的\(libraryMode.title)",
                        detail: libraryMode == .harborKey
                            ? "点击右上角“添加托管密钥”，验证后即可使用。"
                            : "点击右上角“添加自定义 API 密钥”，验证后即可使用。"
                    )
                } else {
                    LazyVGrid(
                        columns: [GridItem(.adaptive(minimum: 210, maximum: 280), spacing: 9)],
                        alignment: .leading,
                        spacing: 9
                    ) {
                        ForEach(model.profiles.filter({ $0.kind.connectionKind == libraryMode })) { profile in
                            let isCurrent = model.activeProfileID == profile.id && model.environment.activeMode == .harbor
                            profileRow(
                                title: profile.name,
                                subtitle: profile.kind == .customResponses ? profile.provider.title : profile.kind.title,
                                icon: profile.kind == .customResponses ? profile.provider.icon : "key.fill",
                                color: .blue,
                                selected: isCurrent,
                                health: model.apiProfileHealth[profile.id] ?? .unchecked,
                                selectionDisabled: isCurrent,
                                deletionTarget: .api(profile),
                                deletionDisabled: isCurrent,
                                action: { Task { await model.switchProfile(to: profile.id) } }
                            )
                        }
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var profileLibraryAction: some View {
        if libraryMode == .account {
            HStack(spacing: 12) {
                Button {
                    Task {
                        await model.refreshEnvironment()
                        await model.refreshConnectionHealth()
                    }
                } label: {
                    Label("检查状态", systemImage: "checkmark.shield")
                }
                .foregroundStyle(.secondary)

                Button {
                    showsAccountSetupSheet = true
                } label: {
                    Label("添加账户", systemImage: "plus")
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.isCheckingConnectionHealth)
        } else if libraryMode == .harborKey {
            HStack(spacing: 12) {
                Button {
                    Task { await model.refreshConnectionHealth() }
                } label: {
                    Label("检查状态", systemImage: "checkmark.shield")
                }
                .foregroundStyle(.secondary)

                Button {
                    newActivationKey = ""
                    newProfileAPIBaseURL = model.environment.apiBaseURL?.absoluteString
                        ?? HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
                    showsActivationSheet = true
                } label: {
                    Label("添加托管密钥", systemImage: "plus")
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.isCheckingConnectionHealth)
        } else {
            HStack(spacing: 12) {
                Button {
                    Task { await model.refreshModelCatalog() }
                } label: {
                    Label("更新模型", systemImage: "arrow.triangle.2.circlepath")
                }
                .foregroundStyle(.secondary)

                Button {
                    Task { await model.refreshConnectionHealth() }
                } label: {
                    Label("检查状态", systemImage: "checkmark.shield")
                }
                .foregroundStyle(.secondary)

                Button {
                    customAPIName = ""
                    customAPIKey = ""
                    customAPIProvider = .openAI
                    customAPIBaseURL = customAPIProvider.defaultBaseURL
                    customAPIModel = ""
                    showsCustomAPISheet = true
                } label: {
                    Label("添加自定义 API 密钥", systemImage: "slider.horizontal.3")
                }
                .foregroundStyle(.blue)
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy || model.isCheckingConnectionHealth)
        }
    }

    private func profileEmptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
        .foregroundStyle(.tertiary)
    }

    private func profileRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        selected: Bool,
        health: ConnectionHealth,
        selectionDisabled: Bool,
        deletionTarget target: ProfileDeletionTarget,
        deletionDisabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 9) {
                Image(systemName: icon)
                    .font(.callout)
                    .foregroundStyle(color)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if selected {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("当前")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(healthColor(health)).frame(width: 6, height: 6)
                        Text(healthTitle(health))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(healthColor(health))
                    }
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy)
            .allowsHitTesting(!selectionDisabled && !model.isBusy)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(healthDetail(health) ?? (selectionDisabled ? "当前正在使用" : "切换到此连接"))

            Menu {
                Button("删除档案", role: .destructive) {
                    deletionTarget = target
                }
                .disabled(deletionDisabled)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(deletionDisabled ? "请先切换到其他连接，再删除当前档案" : "更多操作")
        }
        .padding(.leading, 8)
        .padding(.trailing, 4)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 52)
        .background(
            selected ? color.opacity(0.16) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 9)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(selected ? color.opacity(0.72) : Color.secondary.opacity(0.12), lineWidth: selected ? 1.5 : 1)
        )
        .contextMenu {
            Button("删除档案", role: .destructive) {
                deletionTarget = target
            }
            .disabled(deletionDisabled)
        }
    }

    private func healthTitle(_ health: ConnectionHealth) -> String {
        switch health {
        case .unchecked: "待检查"
        case .checking: "检查中"
        case .available: "可用"
        case .expired: "已过期"
        case .unavailable: "不可用"
        }
    }

    private func healthColor(_ health: ConnectionHealth) -> Color {
        switch health {
        case .unchecked: .secondary
        case .checking: .blue
        case .available: .green
        case .expired: .orange
        case .unavailable: .red
        }
    }

    private func healthDetail(_ health: ConnectionHealth) -> String? {
        switch health {
        case let .available(detail), let .expired(detail), let .unavailable(detail): detail
        case .unchecked: "尚未检查此连接"
        case .checking: "正在检查此连接"
        }
    }

    private func deleteSelectedProfile() {
        guard let target = deletionTarget else { return }
        deletionTarget = nil
        switch target {
        case let .account(profile):
            Task { await model.removeAccount(profile.id) }
        case let .api(profile):
            Task { await model.removeProfile(profile.id) }
        }
    }

    private func profileSectionHeader(title: String, detail: String, color: Color, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(.primary)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var currentConnectionCard: some View {
        card {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    ZStack {
                        Circle().fill(activeModeColor.opacity(0.12))
                        Image(systemName: activeModeIcon)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(activeModeColor)
                    }
                    .frame(width: 42, height: 42)

                    VStack(alignment: .leading, spacing: 2) {
                        Text("当前连接")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        Text(activeModeTitle)
                            .font(.headline)
                        Text(activeModeDetail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if effectiveMode == .harbor,
                       activeHarborProfile?.kind == .harbor {
                        Button {
                            Task { await model.queryUsage() }
                        } label: {
                            Label("查询", systemImage: "arrow.clockwise")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .disabled(model.isBusy)
                    } else if effectiveMode == .chatGPT {
                        Label("已连接", systemImage: "checkmark.circle.fill")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.green)
                    } else {
                        Label("等待选择", systemImage: "circle.dashed")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                }

                if effectiveMode == .harbor,
                   let profile = activeHarborProfile,
                   profile.kind == .harbor {
                    HStack(spacing: 8) {
                        detailMetric(title: "已用", value: formatCurrency(model.usage?.used), color: .orange)
                        detailMetric(title: "剩余", value: formatCurrency(model.usage?.remaining), color: .green)
                        detailMetric(
                            title: "有效期",
                            value: displayExpiry(
                                model.usage?.expiresAt
                                    ?? model.profiles.first(where: { $0.id == model.activeProfileID })?.expiresAt
                                    ?? model.expiresAt
                            ),
                            color: .blue
                        )
                    }
                } else if effectiveMode == .harbor, let profile = activeHarborProfile {
                    HStack(spacing: 8) {
                        detailMetric(title: "连接类型", value: profile.kind.title, color: .blue)
                        detailMetric(title: "模型", value: profile.model, color: .green)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        if profile.kind == .customResponses {
                            Text(!profile.modelsVerified
                                 ? "当前模型未由服务商 /models 验证"
                                 : (profile.modelsNeedRefresh
                                    ? "模型目录超过 24 小时未更新，可点击“更新模型”"
                                    : "模型目录已就绪，当前模型：\(profile.model)"))
                                .font(.caption2)
                                .foregroundStyle(!profile.modelsVerified || profile.modelsNeedRefresh ? .orange : .secondary)
                            Text("外部 API 仅用于新任务，已有任务保持原连接，避免会话协议不兼容")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                        if model.environment.configurationDrift {
                            Label("检测到 Codex 配置被外部修改，请先刷新状态", systemImage: "exclamationmark.triangle.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                
                } else if effectiveMode == .chatGPT {
                    HStack(spacing: 8) {
                        detailMetric(title: "登录状态", value: "凭据可用", color: .green)
                        detailMetric(
                            title: "账户类型",
                            value: model.environment.accountMethod?.title ?? "Codex 账户",
                            color: .blue
                        )
                        detailMetric(title: "会话目录", value: "保持不变", color: .secondary)
                    }
                } else {
                    HStack(spacing: 8) {
                        detailMetric(title: "连接状态", value: "未连接", color: .orange)
                        detailMetric(title: "账户档案", value: "\(model.accountProfiles.count) 个", color: .green)
                        detailMetric(title: "API 密钥", value: "\(model.profiles.count) 个", color: .blue)
                    }
                }

            }
        }
    }

    private var activeHarborProfile: HarborProfile? {
        guard let activeProfileID = model.activeProfileID else { return nil }
        return model.profiles.first(where: { $0.id == activeProfileID })
    }

    private func detailMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(.horizontal, 11)
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .leading)
        .background(color.opacity(0.11), in: RoundedRectangle(cornerRadius: 9))
        .overlay(
            RoundedRectangle(cornerRadius: 9)
                .stroke(color.opacity(0.16), lineWidth: 1)
        )
    }

    private var accountSetupSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeader(
                title: "添加 Codex 账户",
                subtitle: "Harbor 保存当前账户后，通过 Codex 官方登录添加另一个账户"
            )

            accountSetupStep(
                number: "1",
                title: "保护当前账户",
                detail: "新登录在隔离环境中完成，当前 Codex 登录不会退出或被覆盖。",
                color: .green
            )

            Divider()

            HStack(alignment: .center, spacing: 14) {
                accountSetupStep(
                    number: "2",
                    title: "登录新账户",
                    detail: "在浏览器中完成 OpenAI 官方授权，不影响正在运行的 Codex。",
                    color: model.isAwaitingAccountLogin ? .green : .blue
                )
                Spacer()
                Button(model.isAwaitingAccountLogin ? "等待登录完成" : "开始官方登录") {
                    Task { await model.beginAddingAccount() }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || model.isAwaitingAccountLogin)
            }

            Divider()

            HStack(alignment: .center, spacing: 14) {
                accountSetupStep(
                    number: "3",
                    title: "检测登录完成",
                    detail: "读取 Codex 当前真实登录，自动识别名称并加入账户列表。",
                    color: model.detectedAccountName == nil ? .secondary : .green
                )
                Spacer()
                Button("检测登录完成") {
                    Task { await model.detectNewAccountLogin() }
                }
                .buttonStyle(.bordered)
                .disabled(model.isBusy || !model.isAwaitingAccountLogin)
            }

            if let accountName = model.detectedAccountName {
                Label("账户已添加：\(accountName)", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.isAwaitingAccountLogin {
                Label("浏览器登录完成后返回这里，再点击“检测登录完成”。", systemImage: "safari.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Harbor 不会读取账号密码或验证码", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button(
                    model.isAwaitingAccountLogin && model.detectedAccountName == nil
                        ? "取消添加"
                        : (model.detectedAccountName == nil ? "关闭" : "完成")
                ) {
                    if model.isAwaitingAccountLogin && model.detectedAccountName == nil {
                        Task {
                            await model.cancelAddingAccount()
                            if model.errorMessage == nil {
                                showsAccountSetupSheet = false
                            }
                        }
                    } else {
                        showsAccountSetupSheet = false
                    }
                }
                .keyboardShortcut(.cancelAction)
                .disabled(model.isBusy)
            }
        }
        .padding(26)
        .frame(width: 590)
        .interactiveDismissDisabled(
            model.isBusy || (model.isAwaitingAccountLogin && model.detectedAccountName == nil)
        )
    }

    private func accountSetupStep(
        number: String,
        title: String,
        detail: String,
        color: Color
    ) -> some View {
        HStack(alignment: .center, spacing: 11) {
            Text(number)
                .font(.caption.weight(.bold))
                .foregroundStyle(Color.white)
                .frame(width: 25, height: 25)
                .background(color.opacity(0.9), in: Circle())
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var activationSheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeader(title: "添加托管密钥", subtitle: "验证后保存，之后可直接点击档案切换")
            VStack(alignment: .leading, spacing: 8) {
                secureKeyField(title: "托管密钥", text: $newActivationKey, reveals: $showsNewActivationKey)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("服务地址").font(.headline)
                TextField("留空则使用服务默认地址", text: $newProfileAPIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("只支持 HTTPS；密钥和服务令牌仅保存在 Harbor 私有凭据文件中。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { showsActivationSheet = false }
                Button {
                    Task {
                        await model.addProfile(activationKey: newActivationKey, apiBaseURL: newProfileAPIBaseURL)
                        if model.errorMessage == nil { showsActivationSheet = false; newActivationKey = "" }
                    }
                } label: {
                    if model.isBusy { ProgressView().controlSize(.small) } else { Text("验证并添加") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.isBusy || newActivationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 520)
    }

    private var customAPISheet: some View {
        VStack(alignment: .leading, spacing: 18) {
            sheetHeader(
                title: "添加自定义 API 密钥",
                subtitle: "选择协议模板，再填写连接信息"
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("连接提供商").font(.headline)
                Picker("连接提供商", selection: $customAPIProvider) {
                    ForEach(CustomAPIProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
                Text(customAPIProvider.subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("连接名称").font(.headline)
                TextField("例如：公司网关、OpenAI", text: $customAPIName)
                    .textFieldStyle(.roundedBorder)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("API Key").font(.headline)
                HStack(spacing: 8) {
                    Group {
                        if showsCustomAPIKey {
                            TextField("输入 API Key", text: $customAPIKey)
                        } else {
                            SecureField("输入 API Key", text: $customAPIKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .textContentType(.oneTimeCode)
                    .font(.system(.body, design: .monospaced))
                    Button { showsCustomAPIKey.toggle() } label: {
                        Image(systemName: showsCustomAPIKey ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 38)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).stroke(.quaternary))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("API 地址").font(.headline)
                TextField("https://api.example.com/v1", text: $customAPIBaseURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("模型").font(.headline)
                TextField("例如：gpt-5.3-codex", text: $customAPIModel)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                Text("可留空，保存时会从 API 的 /models 自动选择第一个模型")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(customAPIProvider.capabilityNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("取消") { showsCustomAPISheet = false }
                Button {
                    Task {
                        await model.addCustomProfile(
                            name: customAPIName,
                            apiKey: customAPIKey,
                            apiBaseURL: customAPIBaseURL,
                            model: customAPIModel,
                            provider: customAPIProvider
                        )
                        if model.errorMessage == nil {
                            showsCustomAPISheet = false
                            customAPIKey = ""
                        }
                    }
                } label: {
                    if model.isBusy { ProgressView().controlSize(.small) } else { Text("验证并添加") }
                }
                .buttonStyle(.borderedProminent)
                .disabled(
                    model.isBusy ||
                    customAPIName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    customAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(26)
        .frame(width: 540)
        .onChange(of: customAPIProvider) {
            customAPIBaseURL = customAPIProvider.defaultBaseURL
            customAPIModel = ""
        }
    }

    private func sheetHeader(title: String, subtitle: String) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private func secureKeyField(title: String, text: Binding<String>, reveals: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.headline)
            HStack(spacing: 8) {
                Group {
                    if reveals.wrappedValue { TextField("输入托管密钥", text: text) }
                    else { SecureField("输入托管密钥", text: text) }
                }
                .textFieldStyle(.plain)
                .textContentType(.oneTimeCode)
                .font(.system(.body, design: .monospaced))
                Button { reveals.wrappedValue.toggle() } label: {
                    Image(systemName: reveals.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .frame(height: 42)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
        }
    }

    private var additionalProfileActivationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("托管密钥", systemImage: "key.fill")
                    .font(.headline)
                Spacer()
                Text("激活后保存为独立密钥档案，并立即切换")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Group {
                            if showsNewActivationKey {
                                TextField("输入新的托管密钥", text: $newActivationKey)
                            } else {
                                SecureField("输入新的托管密钥", text: $newActivationKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .textContentType(.oneTimeCode)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            showsNewActivationKey.toggle()
                        } label: {
                            Image(systemName: showsNewActivationKey ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(showsNewActivationKey ? "隐藏托管密钥" : "显示托管密钥")
                    }
                    .padding(.leading, 13)
                    .padding(.trailing, 9)
                    .frame(height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

                    Button {
                        Task {
                            await model.addProfile(
                                activationKey: newActivationKey,
                                apiBaseURL: newProfileAPIBaseURL
                            )
                            if model.errorMessage == nil {
                                newActivationKey = ""
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Text("激活并切换")
                        }
                        .frame(minWidth: 102)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(
                        model.isBusy ||
                        newActivationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("API 地址", systemImage: "network")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("仅支持 HTTPS")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    TextField("https://example.com/v1", text: $newProfileAPIBaseURL)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                        .disabled(model.isBusy)
                }
                Divider()
                HStack(spacing: 16) {
                    usageSummary
                    Spacer(minLength: 12)
                    Button {
                        Task { await model.queryUsage() }
                    } label: {
                        Label("查询", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy)

                    Button(role: .destructive) {
                        Task { await model.uninstall() }
                    } label: {
                        Label("卸载配置", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var usageSummary: some View {
        if let usage = model.usage {
            compactUsageItem(title: "已用", value: formatCurrency(usage.used), color: .orange)
            compactUsageItem(title: "剩余", value: formatCurrency(usage.remaining), color: .green)
            compactUsageItem(
                title: "有效期",
                value: displayExpiry(usage.expiresAt ?? model.expiresAt),
                color: .blue
            )
        } else {
            Label("当前密钥用量尚未查询", systemImage: "chart.bar.xaxis")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func compactUsageItem(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func displayExpiry(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let normalized = value.replacingOccurrences(of: "T", with: " ")
        guard normalized.count >= 19 else { return normalized }
        return String(normalized.prefix(19))
    }

    private var statusPill: some View {
        let connected = effectiveMode != nil
        return HStack(spacing: 7) {
            Circle()
                .fill(connected ? Color.green : Color.secondary.opacity(0.5))
                .frame(width: 8, height: 8)
            Text(connected ? "已连接" : "未连接")
                .font(.caption.weight(.semibold))
            if model.requiresCodexReload {
                Divider().frame(height: 14)
                Button {
                    Task { await model.reloadCodex() }
                } label: {
                    Label("需重载", systemImage: "arrow.clockwise")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                }
                .buttonStyle(.plain)
                .disabled(model.isBusy)
                .help("连接已切换，点击重新载入 Codex")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(.quaternary))
    }

    private var activationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                Label("托管密钥", systemImage: "key.fill")
                    .font(.headline)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Group {
                            if showsActivationKey {
                                TextField("输入你的托管密钥", text: $model.activationKey)
                            } else {
                                SecureField("输入你的托管密钥", text: $model.activationKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .textContentType(.oneTimeCode)

                        Button {
                            showsActivationKey.toggle()
                        } label: {
                            Image(systemName: showsActivationKey ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(showsActivationKey ? "隐藏托管密钥" : "显示托管密钥")
                        .accessibilityLabel(showsActivationKey ? "隐藏托管密钥" : "显示托管密钥")
                    }
                    .padding(.leading, 13)
                    .padding(.trailing, 9)
                    .frame(height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    Button {
                        Task { await model.activate() }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Text("激活并配置")
                        }
                        .frame(minWidth: 102)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(model.isBusy || model.activationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("API 地址", systemImage: "network")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("仅支持 HTTPS")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    TextField("https://example.com/v1", text: Binding(
                        get: { model.apiBaseURLInput },
                        set: { model.setAPIBaseURLInput($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                    .disabled(model.isBusy)
                }
                HStack {
                    Button("查询用量") {
                        Task { await model.queryUsage() }
                    }
                    .buttonStyle(.link)
                    .disabled(model.isBusy || model.activationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                Text("密钥和服务令牌保存在 Harbor 私有凭据文件中，不会写入 Codex 配置或日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logCard: some View {
        card {
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Label("运行日志", systemImage: "text.alignleft")
                        .font(.headline)
                    Spacer()
                    Text("最多保留 200 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Button("清空") { model.clearLogs() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            if model.logs.isEmpty {
                                Text("暂无日志")
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
                            } else {
                                ForEach(model.logs) { entry in
                                    logRow(entry)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(maxHeight: .infinity)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
                    .onChange(of: model.logs.count) {
                        guard let last = model.logs.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .frame(height: 190)
        .layoutPriority(2)
    }

    private func logRow(_ entry: HarborLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timeText)
                .foregroundStyle(.tertiary)
                .frame(width: 68, alignment: .leading)
            Image(systemName: logIcon(entry.level))
                .foregroundStyle(logColor(entry.level))
                .frame(width: 13)
            Text(entry.message)
                .foregroundStyle(entry.level == .error ? Color.red : Color.primary.opacity(0.82))
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logIcon(_ level: HarborLogEntry.Level) -> String {
        switch level {
        case .info: "circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func logColor(_ level: HarborLogEntry.Level) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .error: .red
        }
    }

    private func formatCurrency(_ value: Double?) -> String {
        guard let value else { return "—" }
        return "$" + value.formatted(.number.precision(.fractionLength(4)))
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.secondary.opacity(0.13)))
    }
}
