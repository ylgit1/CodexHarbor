import AppKit
import ChatGPTBridgeCore
import CodexHarborCore
import SwiftUI
import UniformTypeIdentifiers

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

private enum ProfileRenameTarget: Identifiable {
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

struct AppShellView: View {
    @ObservedObject var model: AppModel
    @StateObject private var chatGPTBridge = ChatGPTBridgeViewModel()

    @State private var mainPage: HarborMainPage = .home
    @State private var catalogFilter: ConnectionCatalogFilter = .all
    @State private var libraryMode: CodexConnectionKind = .account

    @State private var previewAccountID: UUID?
    @State private var previewAPIProfileID: UUID?
    @State private var showingConnectionDetail = false
    @State private var showingConnectionTypePicker = false

    @State private var showsActivationSheet = false
    @State private var showsAccountSetupSheet = false
    @State private var showsCustomAPISheet = false

    @State private var deletionTarget: ProfileDeletionTarget?
    @State private var renameTarget: ProfileRenameTarget?
    @State private var renameText = ""

    @State private var localConfigurationMode: BridgeTransportMode?
    @State private var localTunnelID = ""
    @State private var localRuntimeKey = ""
    @State private var localHostnameSuffix = ""
    @State private var localPort = "19473"

    @State private var showingRootPicker = false
    @State private var rootToRemove: String?

    var body: some View {
        content
            .background(Color(nsColor: .textBackgroundColor))
            .sheet(isPresented: $showsActivationSheet) {
                HarborHostedKeySheet(
                    model: model,
                    onClose: { showsActivationSheet = false }
                )
            }
            .sheet(isPresented: $showsAccountSetupSheet) {
                HarborAccountSetupSheet(
                    model: model,
                    onClose: { showsAccountSetupSheet = false }
                )
            }
            .sheet(isPresented: $showsCustomAPISheet) {
                HarborCustomAPISheet(
                    model: model,
                    onClose: { showsCustomAPISheet = false }
                )
            }
            .sheet(isPresented: $showingConnectionTypePicker) {
                connectionTypePicker
            }
            .sheet(
                isPresented: Binding(
                    get: { localConfigurationMode != nil },
                    set: { if !$0 { localConfigurationMode = nil } }
                )
            ) {
                if let mode = localConfigurationMode {
                    HarborLocalTransportConfigurationSheet(
                        bridge: chatGPTBridge,
                        mode: mode,
                        tunnelID: $localTunnelID,
                        runtimeKey: $localRuntimeKey,
                        hostnameSuffix: $localHostnameSuffix,
                        localPort: $localPort,
                        onClose: { localConfigurationMode = nil }
                    )
                }
            }
            .fileImporter(
                isPresented: $showingRootPicker,
                allowedContentTypes: [.folder]
            ) { result in
                if case let .success(url) = result {
                    Task { await chatGPTBridge.addAllowedRoot(url) }
                }
            }
            .sheet(
                isPresented: Binding(
                    get: { rootToRemove != nil },
                    set: { if !$0 { rootToRemove = nil } }
                )
            ) {
                HarborDestructiveConfirmDialog(
                    title: "移除授权目录",
                    message: "该目录将不再允许 ChatGPT 本地访问，目录中的文件不会被删除。",
                    confirmTitle: "移除目录",
                    onCancel: { rootToRemove = nil },
                    onConfirm: {
                        guard let root = rootToRemove else { return }
                        rootToRemove = nil
                        Task { await chatGPTBridge.removeAllowedRoot(root) }
                    }
                )
            }
            .sheet(
                item: Binding(
                    get: { chatGPTBridge.pendingApprovalRequests.first },
                    set: { _ in }
                )
            ) { request in
                HarborToolApprovalDialog(
                    request: request,
                    onDeny: {
                        Task { await chatGPTBridge.decideApproval(request, allow: false) }
                    },
                    onAllow: {
                        Task { await chatGPTBridge.decideApproval(request, allow: true) }
                    }
                )
            }
            .sheet(
                isPresented: Binding(
                    get: { deletionTarget != nil },
                    set: { if !$0 { deletionTarget = nil } }
                )
            ) {
                HarborDestructiveConfirmDialog(
                    title: "删除连接",
                    message: "将删除“\(deletionTarget?.name ?? "")”及其本地凭据；Codex 会话记录不会被删除。",
                    onCancel: { deletionTarget = nil },
                    onConfirm: { deleteSelectedProfile() }
                )
            }
            .sheet(
                isPresented: Binding(
                    get: { renameTarget != nil },
                    set: { if !$0 { renameTarget = nil } }
                )
            ) {
                HarborRenameDialog(
                    title: "重命名连接",
                    subtitle: "只修改 Harbor 中的显示名称，不会改变 Codex 配置。",
                    text: $renameText,
                    onCancel: { renameTarget = nil },
                    onSave: { renameSelectedProfile() }
                )
            }
            .task {
                // AppShell owns the single Bridge runtime monitor.
                // Healthy connections are intentionally cheap; recovery states
                // get a short interval so the UI still converges quickly.
                await chatGPTBridge.reconcileRuntime()
                while !Task.isCancelled {
                    let interval = BridgeHealthPolicy.healthInterval(
                        for: chatGPTBridge.runtime.pipelineDiagnostics
                    )
                    do {
                        try await Task.sleep(for: .seconds(interval))
                    } catch {
                        return
                    }
                    guard !Task.isCancelled else { return }
                    await chatGPTBridge.refresh()
                }
            }
            .onReceive(
                NSWorkspace.shared.notificationCenter.publisher(
                    for: NSWorkspace.didWakeNotification
                )
            ) { _ in
                Task { await chatGPTBridge.reconcileRuntime() }
            }
    }

    private var content: some View {
        HStack(alignment: .top, spacing: 0) {
            HarborSidebarView(
                selection: mainPage,
                onSelect: selectMainPage
            )
            .frame(minWidth: 228, idealWidth: 244, maxWidth: 252)

            Divider()
                .opacity(0.45)

            ZStack {
                LinearGradient(
                    colors: [
                        Color(nsColor: .textBackgroundColor),
                        Color.blue.opacity(0.018)
                    ],
                    startPoint: .top,
                    endPoint: .bottomTrailing
                )
                .ignoresSafeArea()

                Group {
                    switch mainPage {
                    case .home:
                        homeDashboard
                    case .connections:
                        connectionManagementPage
                    case .analytics:
                        HarborAnalyticsView(model: model)
                    case .localAccess:
                        localAccessPage
                    case .settings:
                        HarborSettingsView(model: model, bridge: chatGPTBridge)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .frame(minWidth: 1024, minHeight: 640, alignment: .top)
    }

    private var homeDashboard: some View {
        HarborHomeDashboardView(
            model: model,
            bridge: chatGPTBridge,
            effectiveConnectionKind: effectiveConnectionKind,
            activeDisplayName: activeCodexDisplayName,
            connected: effectiveMode != nil,
            accountExpiryText: effectiveConnectionKind == .account
                ? activeAccountExpiryNotice?.text
                : nil,
            accountExpiryColor: effectiveConnectionKind == .account
                ? activeAccountExpiryNotice?.color
                : nil,
            onManageConnections: { kind in
                showingConnectionDetail = false
                catalogFilter = catalogFilter(for: kind)
                mainPage = .connections
            },
            onOpenLocalAccess: {
                mainPage = .localAccess
            }
        )
    }

    @ViewBuilder
    private var connectionManagementPage: some View {
        if showingConnectionDetail {
            ScrollView {
                connectionDetailPage
                    .frame(maxWidth: 1220, alignment: .topLeading)
                    .frame(maxWidth: .infinity, alignment: .top)
                    .padding(.horizontal, 26)
                    .padding(.top, 24)
                    .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)
        } else {
            HarborConnectionManagementView(
                model: model,
                filter: $catalogFilter,
                effectiveConnectionKind: effectiveConnectionKind,
                onCreate: {
                    showingConnectionTypePicker = true
                },
                onOpenAccount: { profile in
                    libraryMode = .account
                    previewAccountID = profile.id
                    previewAPIProfileID = nil
                    showingConnectionDetail = true
                },
                onOpenProfile: { profile in
                    libraryMode = profile.kind.connectionKind
                    previewAPIProfileID = profile.id
                    previewAccountID = nil
                    showingConnectionDetail = true
                },
                onRenameAccount: beginRenameAccount,
                onRenameProfile: beginRenameProfile,
                onDeleteAccount: { deletionTarget = .account($0) },
                onDeleteProfile: { deletionTarget = .api($0) }
            )
        }
    }

    private var connectionTypePicker: some View {
        HarborConnectionTypePicker(
            onChooseAccount: {
                libraryMode = .account
                showingConnectionTypePicker = false
                showsAccountSetupSheet = true
            },
            onChooseHosted: {
                libraryMode = .harborKey
                showingConnectionTypePicker = false
                showsActivationSheet = true
            },
            onChooseAPI: {
                libraryMode = .apiKey
                showingConnectionTypePicker = false
                showsCustomAPISheet = true
            },
            onClose: {
                showingConnectionTypePicker = false
            }
        )
    }

    @ViewBuilder
    private var connectionDetailPage: some View {
        if libraryMode == .account,
           let profile = model.accountProfiles.first(where: { $0.id == previewAccountID }) {
            HarborConnectionDetailView(
                model: model,
                target: .account(profile),
                onBack: { showingConnectionDetail = false },
                onRenameAccount: beginRenameAccount,
                onRenameProfile: beginRenameProfile,
                onDeleteAccount: { deletionTarget = .account($0) },
                onDeleteProfile: { deletionTarget = .api($0) }
            )
        } else if let profile = model.profiles.first(where: { $0.id == previewAPIProfileID }) {
            HarborConnectionDetailView(
                model: model,
                target: .profile(profile),
                onBack: { showingConnectionDetail = false },
                onRenameAccount: beginRenameAccount,
                onRenameProfile: beginRenameProfile,
                onDeleteAccount: { deletionTarget = .account($0) },
                onDeleteProfile: { deletionTarget = .api($0) }
            )
        } else {
            Button("返回连接管理") {
                showingConnectionDetail = false
            }
        }
    }

    private var localAccessPage: some View {
        HarborLocalAccessView(
            bridge: chatGPTBridge,
            onConfigure: openLocalConfiguration,
            onAddRoot: {
                showingRootPicker = true
            },
            onRemoveRoot: {
                rootToRemove = $0
            }
        )
    }

    private var effectiveMode: CodexMode? {
        model.environment.activeMode
            ?? (model.environment.chatGPTSessionExists ? .chatGPT : nil)
    }

    private var effectiveConnectionKind: CodexConnectionKind? {
        switch effectiveMode {
        case .chatGPT:
            .account
        case .harbor:
            activeHarborProfile?.kind.connectionKind ?? .harborKey
        case nil:
            nil
        }
    }

    private var activeHarborProfile: HarborProfile? {
        guard let activeProfileID = model.activeProfileID else { return nil }
        return model.profiles.first(where: { $0.id == activeProfileID })
    }

    private var activeCodexDisplayName: String {
        switch effectiveMode {
        case .chatGPT:
            if let identifier = model.selectedAccountProfileID,
               let profile = model.accountProfiles.first(where: { $0.id == identifier }) {
                return profile.name
            }
            return model.accountProfiles.first?.name ?? "ChatGPT 账户"
        case .harbor:
            return activeHarborProfile?.name ?? "Codex 连接"
        case nil:
            return "未连接"
        }
    }

    private var activeAccountExpiryNotice: (text: String, color: Color)? {
        guard
            let identifier = model.selectedAccountProfileID,
            let profile = model.accountProfiles.first(where: { $0.id == identifier }),
            let expiry = profile.subscriptionExpiryDate()
        else {
            return nil
        }

        let plan = profile.subscriptionPlanTitle ?? "订阅"
        let formatted = expiry.formatted(date: .numeric, time: .standard)
        let remaining = expiry.timeIntervalSinceNow

        if remaining <= 0 {
            if profile.subscriptionExpiryNeedsRefresh() {
                return ("\(plan) 状态待刷新 · 上次周期至 \(formatted)", HarborColors.orange)
            }
            return ("\(plan) 已到期 · \(formatted)", HarborColors.red)
        }

        if remaining <= 7 * 24 * 60 * 60 {
            return ("\(plan) 即将到期 · \(formatted)", HarborColors.red)
        }

        return ("\(plan) 到期 \(formatted)", HarborColors.green)
    }

    private func selectMainPage(_ page: HarborMainPage) {
        mainPage = page
        if page == .connections {
            showingConnectionDetail = false
            catalogFilter = .all
        }
    }

    private func catalogFilter(for kind: CodexConnectionKind?) -> ConnectionCatalogFilter {
        switch kind {
        case .account:
            .account
        case .harborKey:
            .hosted
        case .apiKey:
            .api
        case nil:
            .all
        }
    }

    private func openLocalConfiguration(_ mode: BridgeTransportMode) {
        switch mode {
        case .secureTunnel:
            localTunnelID = chatGPTBridge.configuration.secureTunnel?.tunnelID ?? ""
            localRuntimeKey = ""

        case .httpsCompatibility:
            let config = chatGPTBridge.configuration.httpsCompatibility
            localPort = String(config?.localPort ?? 19_473)

            if let hostname = config?.hostname {
                localHostnameSuffix = hostname
                    .split(separator: ".")
                    .dropFirst()
                    .joined(separator: ".")
            } else {
                localHostnameSuffix = ""
            }
        }

        localConfigurationMode = mode
    }

    private func beginRenameAccount(_ profile: CodexAccountProfile) {
        renameText = profile.name
        renameTarget = .account(profile)
    }

    private func beginRenameProfile(_ profile: HarborProfile) {
        renameText = profile.name
        renameTarget = .api(profile)
    }

    private func deleteSelectedProfile() {
        guard let target = deletionTarget else { return }
        deletionTarget = nil

        switch target {
        case let .account(profile):
            if previewAccountID == profile.id {
                previewAccountID = nil
                showingConnectionDetail = false
            }
            Task { await model.removeAccount(profile.id) }

        case let .api(profile):
            if previewAPIProfileID == profile.id {
                previewAPIProfileID = nil
                showingConnectionDetail = false
            }
            Task { await model.removeProfile(profile.id) }
        }
    }

    private func renameSelectedProfile() {
        guard let target = renameTarget else { return }

        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        renameTarget = nil

        switch target {
        case let .account(profile):
            Task { await model.renameAccount(profile.id, to: name) }
        case let .api(profile):
            Task { await model.renameProfile(profile.id, to: name) }
        }
    }
}
