import CodexHarborCore
import AppKit
import Darwin
import Foundation

@MainActor
final class AppModel: ObservableObject {
    @Published var activationKey = ""
    @Published private(set) var apiBaseURLInput = HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
    @Published private(set) var environment = CodexEnvironment(
        configExists: false,
        chatGPTSessionExists: false,
        deploymentExists: false,
        activeMode: nil
    )
    @Published private(set) var isBusy = false
    @Published private(set) var activity = "正在检查 Codex 环境…"
    @Published private(set) var errorMessage: String?
    @Published private(set) var expiresAt: String?
    @Published private(set) var notice: String?
    @Published private(set) var usage: UsageSnapshot?
    @Published private(set) var usageByProfileID: [UUID: UsageSnapshot] = [:]
    @Published private(set) var isQueryingUsage = false
    @Published private(set) var logs: [HarborLogEntry] = []
    @Published private(set) var profiles: [HarborProfile] = []
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var accountProfiles: [CodexAccountProfile] = []
    @Published private(set) var selectedAccountProfileID: UUID?
    @Published private(set) var apiProfileHealth: [UUID: ConnectionHealth] = [:]
    @Published private(set) var accountProfileHealth: [UUID: ConnectionHealth] = [:]
    @Published private(set) var apiProfileDiagnostics: [UUID: ConnectionDiagnostic] = [:]
    @Published private(set) var accountProfileDiagnostics: [UUID: ConnectionDiagnostic] = [:]
    @Published private(set) var activityEvents: [ConnectionActivityEvent] = []
    @Published private(set) var codexTokenUsageRecords: [CodexTokenUsageRecord] = []
    @Published private(set) var providerBillingByProfileID: [UUID: ProviderBillingSnapshot] = [:]
    @Published private(set) var isCheckingConnectionHealth = false
    @Published private(set) var requiresCodexReload = false
    @Published private(set) var isAwaitingAccountLogin = false
    @Published private(set) var detectedAccountName: String?
    @Published private(set) var migrationPreview: CodexTaskMigrationPreview?

    private let store: LocalSecretStore
    private let manager: CodexConfigurationManager
    private let service: HarborServiceClient
    private let profileCatalog: ProfileCatalogCoordinator
    private let activityStore: ConnectionActivityStore
    private let telemetryCoordinator: CodexTelemetryCoordinator
    private let authenticationChangeMonitor: CodexAuthenticationChangeMonitor
    private let relayActivityChangeMonitor: RelayActivityChangeMonitor
    private let relayConfigurationStore: RelayConfigurationStore
    private let relayActivityStore: RelayActivityStore
    private let providerUsageAdapter: ProviderUsageAdapterClient
    private var apiBaseURLWasEdited = false
    private var didAutoQueryUsage = false
    private let accountLoginSession = AccountLoginSessionManager()
    private var requestMonitorTask: Task<Void, Never>?
    private let logStore = HarborLogStore()

    init() {
        let store = LocalSecretStore.liveMigratingLegacyKeychain()
        self.store = store
        manager = CodexConfigurationManager(store: store)
        service = HarborServiceClient()
        profileCatalog = ProfileCatalogCoordinator(store: store)
        activityStore = ConnectionActivityStore()
        let codexPaths = CodexPaths.live()
        let relayActivityStore = RelayActivityStore(paths: codexPaths)
        self.relayActivityStore = relayActivityStore
        telemetryCoordinator = CodexTelemetryCoordinator(
            paths: codexPaths,
            relayActivityStore: relayActivityStore
        )
        authenticationChangeMonitor = CodexAuthenticationChangeMonitor(paths: codexPaths)
        relayActivityChangeMonitor = RelayActivityChangeMonitor(paths: codexPaths)
        relayConfigurationStore = RelayConfigurationStore()
        providerUsageAdapter = ProviderUsageAdapterClient()
        activityEvents = (try? activityStore.load()) ?? []
        logs = logStore.load()
    }

    func bootstrap() async {
        appendLog("开始检查 Codex 环境")
        var refreshModelCatalogInBackground = false
        await perform("环境检查完成") {
            try await refreshEnvironment(recoverInterruptedDeployment: true)
            if environment.deploymentExists {
                let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                let catalogValid = await manager.isModelCatalogValid()
                if let activeProfile = activeCustomProfile,
                   environment.activeMode == .harbor,
                   (environment.model != activeProfile.model || environment.apiBaseURL != RelayConfiguration.localBaseURL || environment.modelCatalogURL == nil || activeProfile.modelsNeedRefresh || !catalogValid) {
                    refreshModelCatalogInBackground = true
                }
                if try await manager.reconcileManagedConfiguration(helperExecutable: executable) {
                    environment = try await manager.inspect()
                    markCodexReloadRequired()
                    appendLog("已升级 Harbor 托管配置", level: .success)
                }
                if let activeProfile = activeCustomProfile, environment.activeMode == .harbor {
                    try configureRelay(for: activeProfile, executable: executable)
                    if environment.apiBaseURL != RelayConfiguration.localBaseURL {
                        environment = try await manager.updateConnection(
                            apiBaseURL: RelayConfiguration.localBaseURL,
                            model: activeProfile.model,
                            helperExecutable: executable,
                            modelCatalogURL: environment.modelCatalogURL
                        )
                        markCodexReloadRequired()
                    }
                }
            }
            appendLog(environment.configExists ? "已检测到 Codex 主配置" : "Codex 主配置尚未创建")
            appendLog(
                environment.chatGPTSessionExists
                    ? "已检测到现有 \(environment.accountMethod?.title ?? "Codex 登录")"
                    : "未检测到可用的 Codex 登录",
                level: environment.chatGPTSessionExists ? .success : .info
            )
        }
        if refreshModelCatalogInBackground, errorMessage == nil {
            Task { [weak self] in await self?.refreshModelCatalog() }
        }
        if !didAutoQueryUsage, environment.activeMode == .harbor {
            didAutoQueryUsage = true
            await queryUsage()
        }
        await refreshConnectionHealth(logResult: false)
        if let activeCustomProfile { await refreshProviderBilling(for: activeCustomProfile.id) }
        startAuthenticationChangeMonitor()
        startRelayActivityChangeMonitor()
        startCodexRequestMonitor()
    }


    /// Re-reads Codex's live files so external login/configuration changes are reflected immediately.
    func refreshEnvironment() async {
        await perform("状态已刷新") {
            try await refreshEnvironment(recoverInterruptedDeployment: false)
        }
    }

    func setAPIBaseURLInput(_ value: String) {
        apiBaseURLInput = value
        apiBaseURLWasEdited = true
    }

    func activate() async {
        let startedAt = Date()
        await perform("Codex Harbor 已激活并通过验证") {
            let trimmed = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw HarborError.invalidActivationKey }
            activity = "正在验证激活密钥…"
            appendLog("开始验证激活密钥")
            let deviceHash = try DeviceIdentity.hash(using: store)
            let receipt = try await service.redeem(activationKey: trimmed, deviceHash: deviceHash)
            appendLog("激活密钥验证通过", level: .success)
            activity = "正在获取 Codex 服务配置…"
            let remote = try await service.fetchConfiguration()
            let apiBaseURL: URL
            if apiBaseURLWasEdited {
                guard let parsedURL = URL(string: apiBaseURLInput.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                    throw HarborError.invalidBaseURL
                }
                apiBaseURL = try HarborServiceClient.normalizedAPIBaseURL(parsedURL)
            } else {
                apiBaseURL = remote.apiBaseURL
                apiBaseURLInput = apiBaseURL.absoluteString
            }
            activity = "正在验证服务连通性…"
            try await service.validateService(baseURL: apiBaseURL, token: receipt.token)
            appendLog("服务连通性和令牌验证通过", level: .success)
            activity = "正在安全写入 Codex 配置…"
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            environment = try await manager.deploy(.init(
                token: receipt.token,
                apiBaseURL: apiBaseURL,
                model: CodexDefaults.model,
                helperExecutable: executable
            ))
            appendLog("原配置已备份，Codex 配置写入并校验完成", level: .success)
            try store.set(trimmed, for: .activationKey)
            apiBaseURLInput = apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            expiresAt = receipt.expiresAt
            notice = remote.notice ?? receipt.message
            let profile = try await profileCatalog.saveHosted(
                activationKey: trimmed,
                token: receipt.token,
                apiBaseURL: apiBaseURL,
                model: CodexDefaults.model,
                expiresAt: receipt.expiresAt
            )
            try await refreshCatalog()
            if let activeProfileID { apiProfileHealth[activeProfileID] = .available("连接验证通过") }
            recordActivity(.profileCreate, connectionKind: .harborKey, profileID: profile.id, succeeded: true, startedAt: startedAt)
            activationKey = ""
            markCodexReloadRequired()
        }
    }

    func addProfile(activationKey rawKey: String, apiBaseURL rawURL: String) async {
        let startedAt = Date()
        if !environment.deploymentExists {
            activationKey = rawKey
            setAPIBaseURLInput(rawURL)
            await activate()
            return
        }
        await perform("新密钥已激活并切换") {
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw HarborError.invalidActivationKey }
            appendLog("开始验证新激活密钥")
            let deviceHash = try DeviceIdentity.hash(using: store)
            let receipt = try await service.redeem(activationKey: key, deviceHash: deviceHash)
            let remote = try await service.fetchConfiguration()
            let apiBaseURL: URL
            let trimmedURL = rawURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmedURL.isEmpty {
                apiBaseURL = remote.apiBaseURL
            } else {
                guard let parsedURL = URL(string: trimmedURL) else { throw HarborError.invalidBaseURL }
                apiBaseURL = try HarborServiceClient.normalizedAPIBaseURL(parsedURL)
            }
            try await service.validateService(baseURL: apiBaseURL, token: receipt.token)
            let profile = try await profileCatalog.saveHosted(
                activationKey: key,
                token: receipt.token,
                apiBaseURL: apiBaseURL,
                model: CodexDefaults.model,
                expiresAt: receipt.expiresAt,
                select: false
            )
            try await activateProfile(profile.id)
            recordActivity(.profileCreate, connectionKind: .harborKey, profileID: profile.id, succeeded: true, startedAt: startedAt)
            appendLog("已激活并切换到 \(profile.name)", level: .success)
        }
    }

    func addCustomProfile(
        name rawName: String,
        apiKey rawKey: String,
        apiBaseURL rawURL: String,
        model rawModel: String,
        provider: CustomAPIProvider = .openAICompatible
    ) async {
        let startedAt = Date()
        await perform("自定义 API 已添加并切换") {
            let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
            let key = rawKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let enteredModel = rawModel.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, !key.isEmpty else {
                throw HarborError.invalidConfiguration("连接名称和 API Key 不能为空")
            }
            guard let parsedURL = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw HarborError.invalidBaseURL
            }
            let apiBaseURL = try HarborServiceClient.normalizedAPIBaseURL(parsedURL)
            appendLog("正在验证 \(provider.title) 连接：\(name)")
            try await service.validateService(baseURL: apiBaseURL, token: key)
            appendLog("正在读取 /models 获取可用模型")
            let availableModels: [String]
            do {
                availableModels = try await service.fetchModels(baseURL: apiBaseURL, token: key)
            } catch {
                guard !enteredModel.isEmpty else { throw error }
                appendLog("/models 暂不可用，使用已填写的模型：\(enteredModel)", level: .info)
                availableModels = []
            }
            let model: String
            if enteredModel.isEmpty {
                guard let firstModel = availableModels.first else { throw HarborError.invalidModel }
                model = firstModel
                appendLog("已自动选择模型：\(model)", level: .success)
            } else {
                model = enteredModel
            }
            let profile = try await profileCatalog.saveCustom(
                name: name,
                apiKey: key,
                apiBaseURL: apiBaseURL,
                model: model,
                models: availableModels.isEmpty ? [model] : availableModels,
                modelsVerified: availableModels.contains(model),
                provider: provider,
                select: false
            )
            try await activateProfile(profile.id)
            await applyTaskVisibility(for: .customAPI)
            recordActivity(.profileCreate, connectionKind: .apiKey, profileID: profile.id, succeeded: true, startedAt: startedAt)
            appendLog("\(provider.title) 验证通过并已切换：\(profile.name)", level: .success)
        }
    }

    func switchProfile(to identifier: UUID) async {
        guard !(environment.activeMode == .harbor && activeProfileID == identifier) else { return }
        let startedAt = Date()
        let connectionKind = profiles.first(where: { $0.id == identifier })?.kind.connectionKind ?? .harborKey
        await perform("密钥档案切换完成") {
            try await refreshEnvironment(recoverInterruptedDeployment: false)
            do {
                try await activateProfile(identifier)
                apiProfileHealth[identifier] = .available("连接验证通过")
                recordActivity(.connectionSwitch, connectionKind: connectionKind, profileID: identifier, succeeded: true, startedAt: startedAt)
            } catch {
                apiProfileHealth[identifier] = .unavailable(Self.connectionFailureMessage(error))
                recordActivity(.connectionSwitch, connectionKind: connectionKind, profileID: identifier, succeeded: false, startedAt: startedAt)
                throw error
            }
        }
        if environment.activeMode == .harbor,
           profiles.first(where: { $0.id == identifier })?.kind == .customResponses {
            await applyTaskVisibility(for: .customAPI)
            await refreshProviderBilling(for: identifier)
        }
        if environment.activeMode == .harbor,
           activeProfileID == identifier,
           let activeProfileID,
           profiles.first(where: { $0.id == activeProfileID })?.kind == .harbor {
            appendLog("托管密钥已切换，正在自动查询用量")
            await queryUsage()
        }
        if errorMessage == nil,
           environment.activeMode == .harbor,
           activeProfileID == identifier,
           requiresCodexReload {
            appendLog("连接切换完成，正在自动重新启动 Codex")
            await reloadCodex()
        }
    }

    func refreshModelCatalog(for identifier: UUID? = nil) async {
        let targetID = identifier ?? activeProfileID
        guard let targetID,
              let profile = profiles.first(where: { $0.id == targetID }),
              profile.kind == .customResponses else { return }
        await perform("模型列表已更新") {
            let credentials = try await profileCatalog.profileCredentials(for: profile.id)
            appendLog("正在更新 \(profile.name) 的模型列表")
            let models: [String]
            do {
                models = try await service.fetchModels(baseURL: profile.apiBaseURL, token: credentials.token)
            } catch {
                if !(await manager.isModelCatalogValid()), environment.activeMode == .harbor {
                    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    environment = try await manager.updateConnection(
                        apiBaseURL: RelayConfiguration.localBaseURL,
                        model: profile.model,
                        helperExecutable: executable,
                        modelCatalogURL: nil
                    )
                    markCodexReloadRequired()
                    appendLog("模型目录暂不可用，已回退到默认模型配置", level: .info)
                    return
                }
                throw error
            }
            guard let selectedModel = models.first else { throw HarborError.invalidModel }
            try await profileCatalog.updateModels(models, for: profile.id)
            if profile.id == activeProfileID, environment.activeMode == .harbor {
                let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                let catalogModels = models.contains(profile.model) ? models : [profile.model] + models
                let catalogURL = try await manager.writeModelCatalog(models: catalogModels)
                try configureRelay(for: profile, executable: executable)
                environment = try await manager.updateConnection(
                    apiBaseURL: RelayConfiguration.localBaseURL,
                    model: profile.model.isEmpty ? selectedModel : profile.model,
                    helperExecutable: executable,
                    modelCatalogURL: catalogURL
                )
                try? await manager.invalidateModelCatalogCache()
                markCodexReloadRequired()
            }
            try await refreshCatalog()
            appendLog("已发现 \(models.count) 个可用模型", level: .success)
        }
    }

    func removeProfile(_ identifier: UUID) async {
        await perform("API 密钥档案已删除") {
            guard !(environment.activeMode == .harbor && activeProfileID == identifier) else {
                throw HarborError.invalidConfiguration("当前正在使用的 API 密钥不能删除，请先切换")
            }
            try await profileCatalog.removeProfile(identifier)
            apiProfileHealth[identifier] = nil
            try await refreshCatalog()
        }
    }

    func renameProfile(_ identifier: UUID, to name: String) async {
        await perform("连接档案已重命名") {
            try await profileCatalog.renameProfile(identifier, to: name)
            try await refreshCatalog()
        }
    }

    func moveProfileToBoundary(_ identifier: UUID, toFront: Bool) async {
        await perform("连接档案顺序已更新", logsSuccess: false) {
            try await profileCatalog.moveProfile(identifier, toFront: toFront)
            try await refreshCatalog()
        }
    }

    func reorderProfile(moving identifier: UUID, before target: UUID) async {
        await perform("连接档案顺序已更新", logsSuccess: false) {
            try await profileCatalog.reorderProfile(identifier, before: target)
            try await refreshCatalog()
        }
    }

    func saveCurrentAccount(name: String) async {
        await perform("当前 Codex 登录已保存") {
            let profile = try await profileCatalog.saveCurrentAccount(name: name)
            try await refreshCatalog()
            accountProfileHealth[profile.id] = .available("登录凭据完整")
            appendLog("已保存账户档案：\(profile.name)", level: .success)
        }
    }

    func resetAccountLoginFlow() {
        detectedAccountName = nil
        errorMessage = nil
    }

    func beginAddingAccount() async {
        await perform("已打开 Codex 官方登录", logsSuccess: false) {
            try await profileCatalog.synchronizeCurrentAccountIfPresent()
            try await refreshCatalog()

            activity = "正在创建隔离登录环境…"
            try accountLoginSession.start(previousAccountID: selectedAccountProfileID)
            detectedAccountName = nil
            isAwaitingAccountLogin = true
            activity = "等待 Codex 官方登录完成"
            appendLog("已在隔离环境打开 Codex 官方登录，当前账户保持不变")
        }
    }

    func detectNewAccountLogin() async {
        await perform("Codex 账户已保存", logsSuccess: false) {
            let existingIdentifiers = Set(accountProfiles.map(\.id))
            let authentication = try accountLoginSession.authenticationData()
            let profile = try await profileCatalog.importAccountAuthentication(
                authentication,
                name: nil,
                select: false
            )
            guard profile.method == .chatGPT else {
                throw HarborError.invalidAccountCredentials
            }

            do {
                _ = try await profileCatalog.switchAccount(to: profile.id)
                if environment.deploymentExists, environment.activeMode != .chatGPT {
                    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    environment = try await manager.switchMode(
                        .chatGPT,
                        helperExecutable: executable,
                        preferredModel: CodexDefaults.model,
                        preferredReasoningEffort: CodexDefaults.reasoningEffort,
                        preferredServiceTier: CodexDefaults.serviceTier
                    )
                } else {
                    environment = try await manager.inspect()
                }
            } catch {
                if let previousAccountID = accountLoginSession.previousAccountID,
                   previousAccountID != profile.id {
                    _ = try? await profileCatalog.switchAccount(to: previousAccountID)
                }
                environment = (try? await manager.inspect()) ?? environment
                throw error
            }
            try await refreshCatalog()
            guard environment.chatGPTSessionExists,
                  selectedAccountProfileID == profile.id else {
                throw HarborError.missingAccountCredentials
            }

            detectedAccountName = profile.name
            isAwaitingAccountLogin = false
            await accountLoginSession.finish()
            usage = nil
            let action = existingIdentifiers.contains(profile.id) ? "已更新账户" : "已新增账户"
            accountProfileHealth[profile.id] = .available("登录凭据完整")
            appendLog("\(action)：\(profile.name)", level: .success)
            markCodexReloadRequired()
        }
    }

    func cancelAddingAccount() async {
        guard isAwaitingAccountLogin else {
            detectedAccountName = nil
            return
        }
        await perform("已取消添加账户", logsSuccess: false) {
            await accountLoginSession.finish()
            environment = try await manager.inspect()
            try await refreshCatalog()
            isAwaitingAccountLogin = false
            detectedAccountName = nil
            appendLog("已取消隔离登录，Codex 原账户未发生变化", level: .success)
        }
    }

    func switchAccount(to identifier: UUID) async {
        guard !(environment.activeMode == .chatGPT && selectedAccountProfileID == identifier) else { return }
        let startedAt = Date()
        appendLog("准备切换 Codex 账户档案")
        await perform("Codex 账户档案切换完成") {
            try await refreshEnvironment(recoverInterruptedDeployment: false)
            let previousIdentifier = selectedAccountProfileID
            let profile = try await profileCatalog.switchAccount(to: identifier)
            do {
                if environment.deploymentExists, environment.activeMode != .chatGPT {
                    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    environment = try await manager.switchMode(
                        .chatGPT,
                        helperExecutable: executable,
                        preferredModel: CodexDefaults.model,
                        preferredReasoningEffort: CodexDefaults.reasoningEffort,
                        preferredServiceTier: CodexDefaults.serviceTier
                    )
                } else {
                    environment = try await manager.inspect()
                }
                guard environment.activeMode == .chatGPT,
                      environment.chatGPTSessionExists else {
                    throw HarborError.missingAccountCredentials
                }
            } catch {
                if let previousIdentifier, previousIdentifier != identifier {
                    _ = try? await profileCatalog.switchAccount(to: previousIdentifier)
                }
                recordActivity(.connectionSwitch, connectionKind: .account, profileID: identifier, succeeded: false, startedAt: startedAt)
                throw error
            }
            try await refreshCatalog()
            usage = nil
            accountProfileHealth[identifier] = .available("已切换并加载")
            recordActivity(.connectionSwitch, connectionKind: .account, profileID: identifier, succeeded: true, startedAt: startedAt)
            appendLog("已切换账户档案：\(profile.name)", level: .success)
            await applyTaskVisibility(for: .account)
            markCodexReloadRequired()
        }
        if errorMessage == nil,
           environment.activeMode == .chatGPT,
           selectedAccountProfileID == identifier,
           requiresCodexReload {
            appendLog("账户切换完成，正在自动重新启动 Codex")
            await reloadCodex()
        }
    }

    func removeAccount(_ identifier: UUID) async {
        await perform("账户档案已删除") {
            guard !(environment.activeMode == .chatGPT && selectedAccountProfileID == identifier) else {
                throw HarborError.invalidConfiguration("当前正在使用的账户不能删除，请先切换")
            }
            try await profileCatalog.removeAccount(identifier)
            accountProfileHealth[identifier] = nil
            try await refreshCatalog()
        }
    }

    func renameAccount(_ identifier: UUID, to name: String) async {
        await perform("账户档案已重命名") {
            try await profileCatalog.renameAccount(identifier, to: name)
            try await refreshCatalog()
        }
    }

    func moveAccountToBoundary(_ identifier: UUID, toFront: Bool) async {
        await perform("账户档案顺序已更新", logsSuccess: false) {
            try await profileCatalog.moveAccount(identifier, toFront: toFront)
            try await refreshCatalog()
        }
    }

    func reorderAccount(moving identifier: UUID, before target: UUID) async {
        await perform("账户档案顺序已更新", logsSuccess: false) {
            try await profileCatalog.reorderAccount(identifier, before: target)
            try await refreshCatalog()
        }
    }

    func switchMode(to mode: CodexMode) async {
        // The user may have changed Codex outside Harbor since the last refresh.
        await refreshEnvironment()
        guard errorMessage == nil else { return }
        if mode == .harbor {
            let targetProfileID = selectedProfileID ?? profiles.first?.id
            guard let targetProfileID else {
                await perform("切换失败") { throw HarborError.missingToken }
                return
            }
            await switchProfile(to: targetProfileID)
            return
        }
        appendLog("准备切换到\(mode.title)")
        await perform("已切换到 ChatGPT 账户") {
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            environment = try await manager.switchMode(
                .chatGPT,
                helperExecutable: executable,
                preferredModel: CodexDefaults.model,
                preferredReasoningEffort: CodexDefaults.reasoningEffort,
                preferredServiceTier: CodexDefaults.serviceTier
            )
            guard environment.activeMode == .chatGPT else {
                throw HarborError.invalidConfiguration("Codex 实际连接模式未切换成功")
            }
            appendLog("已恢复 Codex 原账户配置，当前登录状态保持不变", level: .success)
            await applyTaskVisibility(for: .account)
            markCodexReloadRequired()
        }
    }

    func queryUsage(for profileID: UUID? = nil) async {
        guard !isBusy, !isQueryingUsage else { return }
        let startedAt = Date()
        let targetProfileID = profileID ?? activeProfileID
        var targetKind: CodexConnectionKind = .harborKey
        isQueryingUsage = true
        errorMessage = nil
        activity = "正在查询用量…"
        defer { isQueryingUsage = false }

        do {
            if let targetProfileID,
               let targetProfile = profiles.first(where: { $0.id == targetProfileID }) {
                targetKind = targetProfile.kind.connectionKind
                if targetProfile.kind == .customResponses {
                    throw HarborError.invalidConfiguration("自定义 API 不提供 Harbor 用量接口")
                }
            }
            let key: String
            if let targetProfileID {
                key = try await profileCatalog.profileCredentials(for: targetProfileID).activationKey
            } else {
                key = environment.deploymentExists
                    ? (try store.string(for: .activationKey) ?? "")
                    : activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            guard !key.isEmpty else { throw HarborError.invalidActivationKey }
            let deviceHash = try DeviceIdentity.hash(using: store)
            let snapshot = try await service.usage(activationKey: key, deviceHash: deviceHash)
            if let targetProfileID {
                usageByProfileID[targetProfileID] = snapshot
                if targetProfileID == activeProfileID { usage = snapshot }
            } else {
                usage = snapshot
            }
            if let expiry = snapshot.expiresAt { expiresAt = expiry }
            let used = snapshot.used.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "未知"
            let remaining = snapshot.remaining.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "未知"
            recordActivity(.usageQuery, connectionKind: targetKind, profileID: targetProfileID, succeeded: true, startedAt: startedAt)
            appendLog("用量查询完成：已用 \(used)，剩余 \(remaining)", level: .success)
        } catch {
            recordActivity(.usageQuery, connectionKind: targetKind, profileID: targetProfileID, succeeded: false, startedAt: startedAt)
            errorMessage = error.localizedDescription
            activity = "用量查询未完成"
            appendLog("操作失败：\(redacted(error.localizedDescription))", level: .error)
        }
    }

    func uninstall() async {
        appendLog("开始安全卸载 Harbor 配置")
        await perform("Codex Harbor 配置已卸载，原配置已恢复") {
            environment = try await manager.uninstall()
            expiresAt = nil
            notice = nil
            usage = nil
            apiBaseURLInput = HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            appendLog("Harbor 配置已移除，激活前的 Codex 配置已恢复", level: .success)
            markCodexReloadRequired()
        }
    }

    func clearLogs() {
        logs.removeAll(keepingCapacity: true)
        logStore.clear()
    }

    func refreshConnectionHealth(logResult: Bool = true) async {
        guard !isCheckingConnectionHealth, !isBusy else { return }
        isCheckingConnectionHealth = true
        defer { isCheckingConnectionHealth = false }

        for profile in accountProfiles {
            let startedAt = Date()
            accountProfileHealth[profile.id] = .checking
            do {
                let health = try await profileCatalog.accountCredentialHealth(for: profile.id)
                accountProfileHealth[profile.id] = health
                accountProfileDiagnostics[profile.id] = ConnectionDiagnostic(
                    checkedAt: Date(),
                    latencyMilliseconds: nil,
                    modelCount: nil,
                    failureReason: nil
                )
                recordActivity(.healthCheck, connectionKind: .account, profileID: profile.id, succeeded: Self.isAvailable(health), startedAt: startedAt)
            } catch {
                accountProfileHealth[profile.id] = .unavailable("本地凭据无法读取")
                accountProfileDiagnostics[profile.id] = ConnectionDiagnostic(
                    checkedAt: Date(),
                    latencyMilliseconds: nil,
                    modelCount: nil,
                    failureReason: "本地凭据无法读取"
                )
                recordActivity(.healthCheck, connectionKind: .account, profileID: profile.id, succeeded: false, startedAt: startedAt)
            }
        }

        for profile in profiles {
            let startedAt = Date()
            if Self.isExpired(profile.expiresAt) {
                apiProfileHealth[profile.id] = .expired("激活密钥已过期")
                recordActivity(.healthCheck, connectionKind: profile.kind.connectionKind, profileID: profile.id, succeeded: false, startedAt: startedAt)
                continue
            }
            apiProfileHealth[profile.id] = .checking
            do {
                let credentials = try await profileCatalog.profileCredentials(for: profile.id)
                let probe = try await service.probeService(baseURL: profile.apiBaseURL, token: credentials.token)
                apiProfileHealth[profile.id] = .available("服务验证通过")
                apiProfileDiagnostics[profile.id] = ConnectionDiagnostic(
                    checkedAt: Date(),
                    latencyMilliseconds: probe.latencyMilliseconds,
                    modelCount: probe.modelCount,
                    failureReason: nil
                )
                recordActivity(.healthCheck, connectionKind: profile.kind.connectionKind, profileID: profile.id, succeeded: true, startedAt: startedAt)
                if profile.kind == .customResponses {
                    await refreshProviderBilling(for: profile.id)
                }
            } catch {
                let message = Self.connectionFailureMessage(error)
                apiProfileHealth[profile.id] = .unavailable(message)
                apiProfileDiagnostics[profile.id] = ConnectionDiagnostic(
                    checkedAt: Date(),
                    latencyMilliseconds: nil,
                    modelCount: nil,
                    failureReason: message
                )
                recordActivity(.healthCheck, connectionKind: profile.kind.connectionKind, profileID: profile.id, succeeded: false, startedAt: startedAt)
            }
        }

        if logResult {
            let states = Array(apiProfileHealth.values) + Array(accountProfileHealth.values)
            let failedCount = states.filter {
                if case .unavailable = $0 { return true }
                if case .expired = $0 { return true }
                return false
            }.count
            appendLog(
                failedCount == 0
                    ? "连接状态检查完成：全部档案可用"
                    : "连接状态检查完成：发现 \(failedCount) 个过期或不可用档案，未自动切换",
                level: failedCount == 0 ? .success : .info
            )
        }
    }

    func reloadCodex() async {
        migrationPreview = nil
        let targetVisibilityGroup = currentTaskVisibilityGroup
        await perform("Codex 已重新载入") {
            appendLog("正在退出 Codex 并整理连接任务")
            let harborProcessIdentifier = ProcessInfo.processInfo.processIdentifier
            let harborApplicationURL = Bundle.main.bundleURL.standardizedFileURL
            guard let applicationURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex")?.standardizedFileURL,
                  applicationURL != harborApplicationURL else {
                throw HarborError.invalidConfiguration("没有找到独立的 Codex 应用，已停止重启")
            }
            let applications = NSRunningApplication
                .runningApplications(withBundleIdentifier: "com.openai.codex")
                .filter {
                    $0.processIdentifier != harborProcessIdentifier
                        && $0.bundleURL?.standardizedFileURL != harborApplicationURL
                }
            for application in applications where !application.isTerminated {
                guard Darwin.kill(application.processIdentifier, SIGTERM) == 0 else {
                    throw HarborError.invalidConfiguration("无法直接结束正在运行的 Codex，请手动重新打开")
                }
            }
            for _ in 0..<30 {
                if applications.allSatisfy(\.isTerminated) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            for application in applications where !application.isTerminated {
                _ = application.forceTerminate()
            }
            for _ in 0..<20 {
                if applications.allSatisfy(\.isTerminated) { break }
                try await Task.sleep(for: .milliseconds(100))
            }
            guard applications.allSatisfy(\.isTerminated) else {
                throw HarborError.invalidConfiguration("Codex 未能正常退出，请手动重新打开")
            }

            do {
                let externalModelIDs = Set(profiles.filter { $0.kind == .customResponses }.flatMap { [$0.model] + $0.models })
                let visibility = try await manager.switchTaskVisibility(to: targetVisibilityGroup, externalModelIDs: externalModelIDs)
                if visibility.hiddenTaskCount > 0 || visibility.shownTaskCount > 0 {
                    appendLog("已隔离连接任务：隐藏 \(visibility.hiddenTaskCount) 个，显示 \(visibility.shownTaskCount) 个", level: .success)
                }
                if targetVisibilityGroup == .customAPI {
                    appendLog("外部 API 仅用于新任务，历史任务已隐藏", level: .success)
                } else {
                    let visibleIDs = try await manager.visibleTaskIDs()
                    let result = try await manager.migrateAllTasksToCurrentConnection(visibleTaskIDs: visibleIDs)
                    appendLog(
                        result.migratedTaskCount > 0
                            ? "兼容连接任务迁移完成：\(result.migratedTaskCount) 个"
                            : "兼容连接任务已校验，无需迁移",
                        level: .success
                    )
                }
                try? await manager.invalidateModelCatalogCache()
                appendLog("已刷新连接提供商的模型列表")
                try Self.openCodex(at: applicationURL)
                requiresCodexReload = false
            } catch {
                try? Self.openCodex(at: applicationURL)
                throw error
            }
        }
    }

    func prepareCodexReload() async {
        await perform("已生成任务迁移预览", logsSuccess: false) {
            let preview = try await manager.previewTaskMigrationToCurrentConnection()
            migrationPreview = preview
            appendLog("迁移预览：检查 \(preview.inspectedTaskCount) 个任务，将处理 \(preview.migratableTaskCount) 个任务")
        }
    }

    func cancelCodexReload() {
        migrationPreview = nil
    }

    private static func openCodex(at applicationURL: URL) throws {
        guard NSWorkspace.shared.open(applicationURL) else {
            throw HarborError.invalidConfiguration("Codex 应用重新打开失败")
        }
    }

    func updateConnection(apiBaseURL rawURL: String) async {
        appendLog("开始验证新的连接设置")
        await perform("连接设置已更新") {
            guard let parsedURL = URL(string: rawURL.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                throw HarborError.invalidBaseURL
            }
            let apiBaseURL = try HarborServiceClient.normalizedAPIBaseURL(parsedURL)
            guard let model = environment.model else { throw HarborError.invalidModel }
            guard let token = try store.string(for: .apiToken), !token.isEmpty else {
                throw HarborError.missingToken
            }
            activity = "正在验证连接设置…"
            try await service.validateService(baseURL: apiBaseURL, token: token)
            let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
            let modelCatalogURL: URL?
            if let activeProfile = activeCustomProfile {
                let models = try await service.fetchModels(baseURL: apiBaseURL, token: token)
                let catalogModels = models.contains(model) ? models : [model] + models
                try await profileCatalog.updateCustomConnection(
                    activeProfile.id,
                    apiBaseURL: apiBaseURL,
                    model: model,
                    models: models
                )
                modelCatalogURL = try await manager.writeModelCatalog(models: catalogModels)
                try relayConfigurationStore.save(RelayConfiguration(
                    profileID: activeProfile.id,
                    upstreamBaseURL: apiBaseURL,
                    model: model,
                    upstreamProtocol: activeProfile.relayProtocol
                ))
                try HarborRelayProcess.ensureRunning(executable: executable)
            } else {
                modelCatalogURL = nil
            }
            environment = try await manager.updateConnection(
                apiBaseURL: activeCustomProfile == nil ? apiBaseURL : RelayConfiguration.localBaseURL,
                model: model,
                helperExecutable: executable,
                modelCatalogURL: modelCatalogURL
            )
            if let activationKey = try store.string(for: .activationKey),
               let token = try store.string(for: .apiToken) {
                _ = try await profileCatalog.saveHosted(
                    activationKey: activationKey,
                    token: token,
                    apiBaseURL: apiBaseURL,
                    model: model,
                    expiresAt: expiresAt
                )
                try await refreshCatalog()
            }
            apiBaseURLInput = apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            try await refreshCatalog()
            markCodexReloadRequired()
        }
    }

    private func activateProfile(_ identifier: UUID) async throws {
        let credentials = try await profileCatalog.profileCredentials(for: identifier)
        let selectedModel = credentials.profile.kind == .harbor ? CodexDefaults.model : credentials.profile.model
        var activeToken = credentials.token
        var latestProbe = recentlyValidatedProbe(for: identifier)
        let modelCatalogURL: URL?
        if credentials.profile.kind == .customResponses {
            if latestProbe == nil {
                latestProbe = try await service.probeService(baseURL: credentials.profile.apiBaseURL, token: activeToken)
            }
            let models: [String]
            if !credentials.profile.models.isEmpty {
                models = credentials.profile.models
            } else {
                models = (try? await service.fetchModels(baseURL: credentials.profile.apiBaseURL, token: activeToken))
                    ?? [credentials.profile.model]
                try await profileCatalog.updateModels(models, for: credentials.profile.id)
            }
            modelCatalogURL = try await manager.writeModelCatalog(models: models)
        } else {
            modelCatalogURL = nil
            if latestProbe == nil {
                do {
                    latestProbe = try await service.probeService(baseURL: credentials.profile.apiBaseURL, token: activeToken)
                } catch let error as HarborError {
                    guard case .serverRejected = error else { throw error }
                    appendLog("当前服务令牌已失效，正在使用激活密钥刷新")
                    let deviceHash = try DeviceIdentity.hash(using: store)
                    let receipt = try await service.redeem(
                        activationKey: credentials.activationKey,
                        deviceHash: deviceHash
                    )
                    activeToken = receipt.token
                    latestProbe = try await service.probeService(baseURL: credentials.profile.apiBaseURL, token: activeToken)
                    _ = try await profileCatalog.saveHosted(
                        activationKey: credentials.activationKey,
                        token: activeToken,
                        apiBaseURL: credentials.profile.apiBaseURL,
                        model: selectedModel,
                        expiresAt: receipt.expiresAt ?? credentials.profile.expiresAt,
                        select: false
                    )
                    appendLog("服务令牌刷新并验证通过", level: .success)
                }
            }
        }
        let previousToken = try store.data(for: .apiToken)
        let previousActivationKey = try store.data(for: .activationKey)
        let previousAPIBaseURL = environment.apiBaseURL
        let previousModel = environment.model
        let previousMode = environment.activeMode
        let previousModelCatalog = try? await manager.modelCatalogSnapshot()
        let previousRelayConfiguration = try? relayConfigurationStore.load()
        var modelCatalogWasChanged = false
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        do {
            try store.set(activeToken, for: .apiToken)
            if credentials.profile.kind == .customResponses {
                try store.remove(.activationKey)
                modelCatalogWasChanged = true
            } else {
                try store.set(credentials.activationKey, for: .activationKey)
            }
            let configuredBaseURL: URL
            if credentials.profile.kind == .customResponses {
                try configureRelay(for: credentials.profile, executable: executable)
                configuredBaseURL = RelayConfiguration.localBaseURL
            } else {
                configuredBaseURL = credentials.profile.apiBaseURL
            }
            if environment.deploymentExists {
                environment = try await manager.updateConnection(
                    apiBaseURL: configuredBaseURL,
                    model: selectedModel,
                    helperExecutable: executable,
                    modelCatalogURL: modelCatalogURL
                )
            } else {
                environment = try await manager.deploy(.init(
                    token: activeToken,
                    apiBaseURL: configuredBaseURL,
                    model: selectedModel,
                    helperExecutable: executable,
                    modelCatalogURL: modelCatalogURL
                ))
            }
            if environment.activeMode != .harbor {
                environment = try await manager.switchMode(.harbor, helperExecutable: executable)
            }
            guard environment.activeMode == .harbor else {
                throw HarborError.invalidConfiguration("API 配置未生效，未完成切换")
            }
            try await profileCatalog.selectProfile(identifier)
            try await refreshCatalog()
            if credentials.profile.kind == .harbor {
                HarborRelayProcess.stopIfRunning()
            }
            try? await manager.invalidateModelCatalogCache()
            usage = nil
            expiresAt = credentials.profile.kind == .harbor ? credentials.profile.expiresAt : nil
            apiBaseURLInput = credentials.profile.apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            if let latestProbe {
                apiProfileDiagnostics[identifier] = ConnectionDiagnostic(
                    checkedAt: Date(),
                    latencyMilliseconds: latestProbe.latencyMilliseconds,
                    modelCount: latestProbe.modelCount,
                    failureReason: nil
                )
            }
            appendLog("当前密钥档案：\(credentials.profile.name)", level: .success)
            markCodexReloadRequired()
        } catch {
            if let previousRelayConfiguration {
                try? relayConfigurationStore.save(previousRelayConfiguration)
            } else {
                try? relayConfigurationStore.clear()
            }
            if let previousToken {
                try? store.set(previousToken, for: .apiToken)
            } else {
                try? store.remove(.apiToken)
            }
            if let previousActivationKey {
                try? store.set(previousActivationKey, for: .activationKey)
            } else {
                try? store.remove(.activationKey)
            }
            if let previousAPIBaseURL, let previousModel {
                _ = try? await manager.updateConnection(
                    apiBaseURL: previousAPIBaseURL,
                    model: previousModel,
                    helperExecutable: executable
                )
                if previousMode == .chatGPT {
                    _ = try? await manager.switchMode(.chatGPT, helperExecutable: executable)
                }
            }
            if modelCatalogWasChanged {
                try? await manager.restoreModelCatalog(previousModelCatalog ?? nil)
            }
            throw error
        }
    }

    private func refreshCatalog() async throws {
        let activeToken = environment.activeMode == .harbor
            ? try store.data(for: .apiToken)
            : nil
        let snapshot = try await profileCatalog.snapshot(
            environment: environment,
            activeAPIToken: activeToken
        )

        profiles = snapshot.profiles
        selectedProfileID = snapshot.selectedProfileID
        activeProfileID = snapshot.activeProfileID

        apiProfileHealth = apiProfileHealth.filter { key, _ in
            profiles.contains(where: { $0.id == key })
        }
        apiProfileDiagnostics = apiProfileDiagnostics.filter { key, _ in
            profiles.contains(where: { $0.id == key })
        }
        for profile in profiles where apiProfileHealth[profile.id] == nil {
            apiProfileHealth[profile.id] = Self.isExpired(profile.expiresAt)
                ? .expired("激活密钥已过期")
                : .unchecked
        }

        if accountProfiles != snapshot.accountProfiles {
            accountProfiles = snapshot.accountProfiles
        }
        selectedAccountProfileID = snapshot.selectedAccountProfileID
        accountProfileHealth = accountProfileHealth.filter { key, _ in
            accountProfiles.contains(where: { $0.id == key })
        }
        accountProfileDiagnostics = accountProfileDiagnostics.filter { key, _ in
            accountProfiles.contains(where: { $0.id == key })
        }
        for profile in accountProfiles where accountProfileHealth[profile.id] == nil {
            accountProfileHealth[profile.id] = .unchecked
        }
    }

    private var activeCustomProfile: HarborProfile? {
        guard let activeProfileID,
              let profile = profiles.first(where: { $0.id == activeProfileID }),
              profile.kind == .customResponses else { return nil }
        return profile
    }

    private func recentlyValidatedProbe(for identifier: UUID) -> ServiceProbe? {
        guard case .available = apiProfileHealth[identifier],
              let diagnostic = apiProfileDiagnostics[identifier],
              diagnostic.failureReason == nil,
              Date().timeIntervalSince(diagnostic.checkedAt) < 90,
              let latency = diagnostic.latencyMilliseconds else { return nil }
        return ServiceProbe(
            latencyMilliseconds: latency,
            modelCount: diagnostic.modelCount
        )
    }

    private var currentTaskVisibilityGroup: CodexTaskVisibilityGroup {
        if environment.activeMode == .chatGPT {
            return .account
        }
        if activeCustomProfile != nil {
            return .customAPI
        }
        return .harborKey
    }

    private func applyTaskVisibility(for group: CodexTaskVisibilityGroup) async {
        do {
            let externalModelIDs = Set(profiles.filter { $0.kind == .customResponses }.flatMap { [$0.model] + $0.models })
            let result = try await manager.switchTaskVisibility(to: group, externalModelIDs: externalModelIDs)
            if result.hiddenTaskCount > 0 || result.shownTaskCount > 0 {
                appendLog("已更新会话显示：隐藏 \(result.hiddenTaskCount) 个，显示 \(result.shownTaskCount) 个", level: .success)
            }
        } catch {
            appendLog("会话显示更新失败：\(redacted(error.localizedDescription))", level: .error)
        }
    }

    private func syncModelCatalog(for profile: HarborProfile) async throws -> URL {
        let credentials = try await profileCatalog.profileCredentials(for: profile.id)
        let models = try await service.fetchModels(baseURL: profile.apiBaseURL, token: credentials.token)
        try await profileCatalog.updateModels(models, for: profile.id)
        let catalogModels = models.contains(profile.model) ? models : [profile.model] + models
        return try await manager.writeModelCatalog(models: catalogModels)
    }

    private func refreshEnvironment(recoverInterruptedDeployment: Bool) async throws {
        if recoverInterruptedDeployment {
            try await manager.recoverInterruptedDeploymentIfNeeded()
        }
        environment = try await manager.inspect()
        try await profileCatalog.migrateLegacyIfNeeded(environment: environment)
        try await profileCatalog.synchronizeCurrentAccountIfPresent()
        await telemetryCoordinator.markAuthenticationCurrent()
        try await refreshCatalog()
        if environment.activeMode != .harbor || activeCustomProfile == nil {
            HarborRelayProcess.stopIfRunning()
        }
        if let apiURL = environment.apiBaseURL {
            apiBaseURLInput = activeCustomProfile?.apiBaseURL.absoluteString ?? apiURL.absoluteString
        }
    }

    private func configureRelay(for profile: HarborProfile, executable: URL) throws {
        try relayConfigurationStore.save(RelayConfiguration(
            profileID: profile.id,
            upstreamBaseURL: profile.apiBaseURL,
            model: profile.model,
            upstreamProtocol: profile.relayProtocol
        ))
        try HarborRelayProcess.ensureRunning(executable: executable)
    }

    private nonisolated static func isExpired(_ value: String?) -> Bool {
        guard let date = expiryDate(value) else { return false }
        return date <= Date()
    }

    private nonisolated static func expiryDate(_ value: String?) -> Date? {
        guard let value, !value.isEmpty else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value.replacingOccurrences(of: "T", with: " ")) {
                return date
            }
        }
        return nil
    }

    private nonisolated static func isAvailable(_ health: ConnectionHealth) -> Bool {
        if case .available = health { return true }
        return false
    }

    private nonisolated static func connectionFailureMessage(_ error: Error) -> String {
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return "连接超时，请检查服务地址或网络"
            case .cannotFindHost, .dnsLookupFailed: return "无法解析服务域名"
            case .notConnectedToInternet, .networkConnectionLost: return "网络连接不可用"
            case .serverCertificateUntrusted, .serverCertificateHasBadDate, .secureConnectionFailed:
                return "TLS 证书或安全连接异常"
            default: break
            }
        }
        if let harborError = error as? HarborError {
            switch harborError {
            case .serverRejected(let message): return message
            case .missingToken: return "本地凭据不存在"
            case .invalidBaseURL: return "API 地址无效"
            default: break
            }
        }
        return "网络或服务暂时不可用"
    }

    private nonisolated static func runCodexCommand(
        executable: URL,
        arguments: [String]
    ) async throws {
        try await Task.detached {
            let process = Process()
            let errorPipe = Pipe()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = CodexProcessSupport.environment()
            process.standardOutput = FileHandle.nullDevice
            process.standardError = errorPipe
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                let data = errorPipe.fileHandleForReading.readDataToEndOfFile()
                let detail = String(data: data, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw HarborError.invalidConfiguration(
                    detail?.isEmpty == false ? detail! : "Codex 官方命令执行失败"
                )
            }
        }.value
    }

    private func perform(
        _ success: String,
        logsSuccess: Bool = true,
        operation: () async throws -> Void
    ) async {
        guard !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            try await operation()
            activity = success
            if logsSuccess {
                appendLog(success, level: .success)
            }
        } catch {
            errorMessage = error.localizedDescription
            activity = "操作未完成"
            appendLog("操作失败：\(redacted(error.localizedDescription))", level: .error)
            if let refreshed = try? await manager.inspect() {
                environment = refreshed
            }
        }
    }

    private func markCodexReloadRequired() {
        requiresCodexReload = true
        appendLog("切换已安全写入；重新载入后仅新任务使用当前连接，历史任务保持原连接")
    }

    func providerBilledTokenTotal(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        since: Date? = nil
    ) -> Int {
        guard connectionKind == .apiKey else { return 0 }
        return (try? relayActivityStore.billedTokenTotal(
            profileID: profileID,
            since: since
        )) ?? 0
    }

    func refreshProviderBilling(for profileID: UUID) async {
        guard let profile = profiles.first(where: { $0.id == profileID }),
              profile.kind == .customResponses,
              let credentials = try? await profileCatalog.profileCredentials(for: profileID) else { return }
        do {
            if let snapshot = try await providerUsageAdapter.billing(profile: profile, token: credentials.token) {
                providerBillingByProfileID[profileID] = snapshot
            }
        } catch {
            // Billing access can require a management-scoped key. It must not
            // affect connection health or interrupt normal model requests.
        }
    }

    private func startAuthenticationChangeMonitor() {
        authenticationChangeMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, !self.isBusy else { return }
                await self.telemetryCoordinator.markAuthenticationCurrent()
                await self.synchronizeAccountProfileAfterAuthenticationChange()
            }
        }
    }

    private func startRelayActivityChangeMonitor() {
        relayActivityChangeMonitor.start { [weak self] in
            Task { @MainActor [weak self] in
                guard let self,
                      self.telemetryConnectionSnapshot?.kind == .apiKey else { return }
                await self.refreshCodexTelemetry(seedRequests: false)
            }
        }
    }

    private func startCodexRequestMonitor() {
        guard requestMonitorTask == nil else { return }
        requestMonitorTask = Task { [weak self] in
            guard let self else { return }
            var shouldSeed = await self.telemetryCoordinator.shouldSeedRequests

            while !Task.isCancelled {
                await self.refreshCodexTelemetry(seedRequests: shouldSeed)
                shouldSeed = false

                let interval: Int
                switch self.telemetryConnectionSnapshot?.kind {
                case .apiKey:
                    // Relay SQLite changes wake telemetry immediately. Keep a
                    // slower fallback in case vnode delivery is unavailable.
                    interval = 60
                case .account, .harborKey:
                    interval = 10
                case nil:
                    interval = 30
                }

                do {
                    try await Task.sleep(for: .seconds(interval))
                } catch {
                    break
                }
            }
        }
    }

    private func refreshCodexTelemetry(seedRequests: Bool) async {
        let existingSources = Set(activityEvents.compactMap(\.sourceID))
        let update = await telemetryCoordinator.poll(
            connection: telemetryConnectionSnapshot,
            existingActivitySourceIDs: existingSources,
            seedRequests: seedRequests
        )

        if update.authenticationChanged {
            await synchronizeAccountProfileAfterAuthenticationChange()
        }

        if codexTokenUsageRecords != update.tokenUsageRecords {
            codexTokenUsageRecords = update.tokenUsageRecords
        }

        var changed = false
        for event in update.activityEvents {
            if let updated = try? activityStore.append(event, to: activityEvents) {
                activityEvents = updated
                changed = true
            }
        }
        if changed {
            objectWillChange.send()
        }
    }

    private func synchronizeAccountProfileAfterAuthenticationChange() async {
        do {
            try await profileCatalog.synchronizeCurrentAccountIfPresent()
            try await refreshCatalog()
            appendLog("检测到 Codex 登录凭据更新，账户档案已同步", level: .success)
        } catch {
            appendLog("Codex 登录凭据更新暂未同步：\(redacted(error.localizedDescription))", level: .error)
        }
    }

    private var telemetryConnectionSnapshot: CodexTelemetryConnectionSnapshot? {
        switch environment.activeMode {
        case .chatGPT:
            return CodexTelemetryConnectionSnapshot(
                kind: .account,
                profileID: selectedAccountProfileID
            )
        case .harbor:
            guard let activeProfileID,
                  let profile = profiles.first(where: { $0.id == activeProfileID }) else {
                return nil
            }
            return CodexTelemetryConnectionSnapshot(
                kind: profile.kind.connectionKind,
                profileID: activeProfileID
            )
        case nil:
            return nil
        }
    }

    private func recordActivity(
        _ kind: ConnectionActivityKind,
        connectionKind: CodexConnectionKind,
        profileID: UUID?,
        succeeded: Bool,
        startedAt: Date,
        durationMilliseconds: Int? = nil,
        sourceID: String? = nil
    ) {
        let event = ConnectionActivityEvent(
            connectionKind: connectionKind,
            profileID: profileID,
            kind: kind,
            succeeded: succeeded,
            durationMilliseconds: durationMilliseconds ?? elapsedMilliseconds(since: startedAt),
            sourceID: sourceID
        )
        if let updatedEvents = try? activityStore.append(event, to: activityEvents) {
            activityEvents = updatedEvents
        }
    }

    private func elapsedMilliseconds(since startDate: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(startDate) * 1000))
    }

    private func appendLog(_ message: String, level: HarborLogEntry.Level = .info) {
        logs.append(HarborLogEntry(
            timeText: Date().formatted(date: .omitted, time: .standard),
            level: level,
            message: redacted(message)
        ))
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        logStore.save(logs)
    }

    private func redacted(_ message: String) -> String {
        let key = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return message }
        return message.replacingOccurrences(of: key, with: "••••••")
    }
}
