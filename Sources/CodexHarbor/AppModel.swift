import CodexHarborCore
import AppKit
import Darwin
import Foundation

struct HarborLogEntry: Identifiable, Equatable, Codable {
    enum Level: String, Codable {
        case info
        case success
        case error
    }

    var id = UUID()
    let timeText: String
    let level: Level
    let message: String
}

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
    @Published private(set) var logs: [HarborLogEntry] = []
    @Published private(set) var profiles: [HarborProfile] = []
    @Published private(set) var selectedProfileID: UUID?
    @Published private(set) var activeProfileID: UUID?
    @Published private(set) var accountProfiles: [CodexAccountProfile] = []
    @Published private(set) var selectedAccountProfileID: UUID?
    @Published private(set) var apiProfileHealth: [UUID: ConnectionHealth] = [:]
    @Published private(set) var accountProfileHealth: [UUID: ConnectionHealth] = [:]
    @Published private(set) var isCheckingConnectionHealth = false
    @Published private(set) var requiresCodexReload = false
    @Published private(set) var isAwaitingAccountLogin = false
    @Published private(set) var detectedAccountName: String?
    @Published private(set) var migrationPreview: CodexTaskMigrationPreview?
    @Published private(set) var sessions: [CodexSessionEntry] = []

    private let store: LocalSecretStore
    private let manager: CodexConfigurationManager
    private let service: HarborServiceClient
    private let profileRepository: HarborProfileRepository
    private let accountProfileRepository: CodexAccountProfileRepository
    private let sessionManager: CodexSessionManager
    private var apiBaseURLWasEdited = false
    private var didAutoQueryUsage = false
    private var codexLoginProcess: Process?
    private var accountBeforeLoginID: UUID?
    private var accountLoginHomeURL: URL?

    private let logsStorageKey = "codex-harbor.run-logs"

    init() {
        let store = LocalSecretStore.liveMigratingLegacyKeychain()
        self.store = store
        manager = CodexConfigurationManager(store: store)
        service = HarborServiceClient()
        profileRepository = HarborProfileRepository(store: store)
        accountProfileRepository = CodexAccountProfileRepository(store: store)
        sessionManager = CodexSessionManager()
        if let data = UserDefaults.standard.data(forKey: logsStorageKey),
           let savedLogs = try? JSONDecoder().decode([HarborLogEntry].self, from: data) {
            logs = Array(savedLogs.suffix(200))
        }
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
                   (environment.model != activeProfile.model || environment.apiBaseURL != activeProfile.apiBaseURL || environment.modelCatalogURL == nil || activeProfile.modelsNeedRefresh || !catalogValid) {
                    refreshModelCatalogInBackground = true
                }
                if try await manager.reconcileManagedConfiguration(helperExecutable: executable) {
                    environment = try await manager.inspect()
                    markCodexReloadRequired()
                    appendLog("已升级 Harbor 托管配置", level: .success)
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
        await refreshSessions()
    }

    func refreshSessions() async { do { sessions = try sessionManager.reconcile() } catch { appendLog("会话列表读取失败：\(redacted(error.localizedDescription))", level: .error) } }
    func deleteSessions(_ ids: Set<String>) async { guard !ids.isEmpty else { return }; do { sessions = try sessionManager.setDeleted(true, for: ids); appendLog("已移入会话回收站：\(ids.count) 个", level: .success) } catch { appendLog("删除会话失败：\(redacted(error.localizedDescription))", level: .error) } }
    func restoreSessions(_ ids: Set<String>) async { guard !ids.isEmpty else { return }; do { sessions = try sessionManager.setDeleted(false, for: ids); appendLog("已恢复会话：\(ids.count) 个", level: .success) } catch { appendLog("恢复会话失败：\(redacted(error.localizedDescription))", level: .error) } }
    func groupSessions(_ ids: Set<String>, group: String?) async { do { sessions = try sessionManager.setGroup(group, for: ids) } catch { appendLog("会话分组失败：\(redacted(error.localizedDescription))", level: .error) } }
    func renameSession(_ id: String, title: String) async { do { sessions = try sessionManager.rename(id, to: title) } catch { appendLog("重命名会话失败：\(redacted(error.localizedDescription))", level: .error) } }
    func renameSessionGroup(_ old: String, new: String) async { do { sessions = try sessionManager.renameGroup(old, to: new) } catch { appendLog("重命名目录失败：\(redacted(error.localizedDescription))", level: .error) } }
    func deleteSessionGroup(_ name: String) async { do { sessions = try sessionManager.deleteGroup(name) } catch { appendLog("删除目录失败：\(redacted(error.localizedDescription))", level: .error) } }

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
                model: remote.model,
                helperExecutable: executable
            ))
            appendLog("原配置已备份，Codex 配置写入并校验完成", level: .success)
            try store.set(trimmed, for: .activationKey)
            apiBaseURLInput = apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            expiresAt = receipt.expiresAt
            notice = remote.notice ?? receipt.message
            _ = try await profileRepository.save(
                activationKey: trimmed,
                token: receipt.token,
                apiBaseURL: apiBaseURL,
                model: remote.model,
                expiresAt: receipt.expiresAt
            )
            try await refreshProfiles()
            if let activeProfileID { apiProfileHealth[activeProfileID] = .available("连接验证通过") }
            activationKey = ""
            markCodexReloadRequired()
        }
    }

    func addProfile(activationKey rawKey: String, apiBaseURL rawURL: String) async {
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
            let profile = try await profileRepository.save(
                activationKey: key,
                token: receipt.token,
                apiBaseURL: apiBaseURL,
                model: remote.model,
                expiresAt: receipt.expiresAt,
                select: false
            )
            try await activateProfile(profile.id)
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
            let profile = try await profileRepository.saveCustomResponses(
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
            appendLog("\(provider.title) 验证通过并已切换：\(profile.name)", level: .success)
        }
    }

    func switchProfile(to identifier: UUID) async {
        guard !(environment.activeMode == .harbor && activeProfileID == identifier) else { return }
        await perform("密钥档案切换完成") {
            try await refreshEnvironment(recoverInterruptedDeployment: false)
            do {
                try await activateProfile(identifier)
                apiProfileHealth[identifier] = .available("连接验证通过")
            } catch {
                apiProfileHealth[identifier] = .unavailable(Self.connectionFailureMessage(error))
                throw error
            }
        }
        if environment.activeMode == .harbor,
           profiles.first(where: { $0.id == identifier })?.kind == .customResponses {
            await applyTaskVisibility(for: .customAPI)
        }
        if environment.activeMode == .harbor,
           activeProfileID == identifier,
           let activeProfileID,
           profiles.first(where: { $0.id == activeProfileID })?.kind == .harbor {
            appendLog("托管密钥已切换，正在自动查询用量")
            await queryUsage()
        }
    }

    func refreshModelCatalog(for identifier: UUID? = nil) async {
        let targetID = identifier ?? activeProfileID
        guard let targetID,
              let profile = profiles.first(where: { $0.id == targetID }),
              profile.kind == .customResponses else { return }
        await perform("模型列表已更新") {
            let credentials = try await profileRepository.credentials(for: profile.id)
            appendLog("正在更新 \(profile.name) 的模型列表")
            let models: [String]
            do {
                models = try await service.fetchModels(baseURL: profile.apiBaseURL, token: credentials.token)
            } catch {
                if !(await manager.isModelCatalogValid()), environment.activeMode == .harbor {
                    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    environment = try await manager.updateConnection(
                        apiBaseURL: profile.apiBaseURL,
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
            try await profileRepository.updateModels(models, for: profile.id)
            if profile.id == activeProfileID, environment.activeMode == .harbor {
                let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                let catalogModels = models.contains(profile.model) ? models : [profile.model] + models
                let catalogURL = try await manager.writeModelCatalog(models: catalogModels)
                environment = try await manager.updateConnection(
                    apiBaseURL: profile.apiBaseURL,
                    model: profile.model.isEmpty ? selectedModel : profile.model,
                    helperExecutable: executable,
                    modelCatalogURL: catalogURL
                )
                try? await manager.invalidateModelCatalogCache()
                markCodexReloadRequired()
            }
            try await refreshProfiles()
            appendLog("已发现 \(models.count) 个可用模型", level: .success)
        }
    }

    func removeProfile(_ identifier: UUID) async {
        await perform("API 密钥档案已删除") {
            guard !(environment.activeMode == .harbor && activeProfileID == identifier) else {
                throw HarborError.invalidConfiguration("当前正在使用的 API 密钥不能删除，请先切换")
            }
            try await profileRepository.remove(identifier)
            apiProfileHealth[identifier] = nil
            try await refreshProfiles()
        }
    }

    func saveCurrentAccount(name: String) async {
        await perform("当前 Codex 登录已保存") {
            let profile = try await accountProfileRepository.saveCurrentLogin(name: name)
            try await refreshAccountProfiles()
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
            try await accountProfileRepository.synchronizeCurrentLoginIfPresent()
            try await refreshAccountProfiles()

            let executable = try Self.codexExecutableURL()
            let previousAccountID = selectedAccountProfileID
            activity = "正在创建隔离登录环境…"
            let loginHome = FileManager.default.temporaryDirectory
                .appendingPathComponent("CodexHarbor-Login-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: loginHome, withIntermediateDirectories: true)
            do {
                try launchCodexLogin(executable: executable, codexHome: loginHome)
            } catch {
                try? FileManager.default.removeItem(at: loginHome)
                throw error
            }

            accountBeforeLoginID = previousAccountID
            accountLoginHomeURL = loginHome
            detectedAccountName = nil
            isAwaitingAccountLogin = true
            activity = "等待 Codex 官方登录完成"
            appendLog("已在隔离环境打开 Codex 官方登录，当前账户保持不变")
        }
    }

    func detectNewAccountLogin() async {
        await perform("Codex 账户已保存", logsSuccess: false) {
            guard let loginHome = accountLoginHomeURL else {
                throw HarborError.invalidConfiguration("隔离登录环境不存在，请重新开始添加账户")
            }
            let stagedAuthenticationURL = loginHome.appendingPathComponent("auth.json")
            guard FileManager.default.fileExists(atPath: stagedAuthenticationURL.path) else {
                throw HarborError.invalidConfiguration("尚未检测到登录完成，请在浏览器完成授权后重试")
            }
            let existingIdentifiers = Set(accountProfiles.map(\.id))
            let authentication = try Data(contentsOf: stagedAuthenticationURL)
            let profile = try await accountProfileRepository.importAuthentication(
                authentication,
                name: nil,
                select: false
            )
            guard profile.method == .chatGPT else {
                throw HarborError.invalidAccountCredentials
            }

            do {
                _ = try await accountProfileRepository.switchToProfile(profile.id)
                if environment.deploymentExists, environment.activeMode != .chatGPT {
                    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    environment = try await manager.switchMode(.chatGPT, helperExecutable: executable)
                } else {
                    environment = try await manager.inspect()
                }
            } catch {
                if let previousAccountID = accountBeforeLoginID, previousAccountID != profile.id {
                    _ = try? await accountProfileRepository.switchToProfile(previousAccountID)
                }
                environment = (try? await manager.inspect()) ?? environment
                throw error
            }
            try await refreshAccountProfiles()
            guard environment.chatGPTSessionExists,
                  selectedAccountProfileID == profile.id else {
                throw HarborError.missingAccountCredentials
            }

            detectedAccountName = profile.name
            isAwaitingAccountLogin = false
            accountBeforeLoginID = nil
            await stopAccountLoginProcess()
            cleanupAccountLoginHome()
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
            await stopAccountLoginProcess()
            cleanupAccountLoginHome()
            environment = try await manager.inspect()
            try await refreshAccountProfiles()
            isAwaitingAccountLogin = false
            accountBeforeLoginID = nil
            detectedAccountName = nil
            appendLog("已取消隔离登录，Codex 原账户未发生变化", level: .success)
        }
    }

    func switchAccount(to identifier: UUID) async {
        guard !(environment.activeMode == .chatGPT && selectedAccountProfileID == identifier) else { return }
        appendLog("准备切换 Codex 账户档案")
        await perform("Codex 账户档案切换完成") {
            try await refreshEnvironment(recoverInterruptedDeployment: false)
            let previousIdentifier = selectedAccountProfileID
            let profile = try await accountProfileRepository.switchToProfile(identifier)
            do {
                if environment.deploymentExists, environment.activeMode != .chatGPT {
                    let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
                    environment = try await manager.switchMode(.chatGPT, helperExecutable: executable)
                } else {
                    environment = try await manager.inspect()
                }
                guard environment.activeMode == .chatGPT,
                      environment.chatGPTSessionExists else {
                    throw HarborError.missingAccountCredentials
                }
            } catch {
                if let previousIdentifier, previousIdentifier != identifier {
                    _ = try? await accountProfileRepository.switchToProfile(previousIdentifier)
                }
                throw error
            }
            try await refreshAccountProfiles()
            usage = nil
            accountProfileHealth[identifier] = .available("已切换并加载")
            appendLog("已切换账户档案：\(profile.name)", level: .success)
            await applyTaskVisibility(for: .account)
            markCodexReloadRequired()
        }
    }

    func removeAccount(_ identifier: UUID) async {
        await perform("账户档案已删除") {
            guard !(environment.activeMode == .chatGPT && selectedAccountProfileID == identifier) else {
                throw HarborError.invalidConfiguration("当前正在使用的账户不能删除，请先切换")
            }
            try await accountProfileRepository.remove(identifier)
            accountProfileHealth[identifier] = nil
            try await refreshAccountProfiles()
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
            environment = try await manager.switchMode(.chatGPT, helperExecutable: executable)
            guard environment.activeMode == .chatGPT else {
                throw HarborError.invalidConfiguration("Codex 实际连接模式未切换成功")
            }
            appendLog("已恢复 Codex 原账户配置，当前登录状态保持不变", level: .success)
            await applyTaskVisibility(for: .account)
            markCodexReloadRequired()
        }
    }

    func queryUsage() async {
        await perform("用量查询完成", logsSuccess: false) {
            if let activeProfileID,
               let activeProfile = profiles.first(where: { $0.id == activeProfileID }),
               activeProfile.kind == .customResponses {
                throw HarborError.invalidConfiguration("自定义 API 不提供 Harbor 用量接口")
            }
            let key = environment.deploymentExists
                ? (try store.string(for: .activationKey) ?? "")
                : activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !key.isEmpty else { throw HarborError.invalidActivationKey }
            activity = "正在查询用量…"
            let deviceHash = try DeviceIdentity.hash(using: store)
            let snapshot = try await service.usage(activationKey: key, deviceHash: deviceHash)
            usage = snapshot
            if let activeProfileID { apiProfileHealth[activeProfileID] = .available("用量查询成功") }
            if let expiry = snapshot.expiresAt { expiresAt = expiry }
            let used = snapshot.used.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "未知"
            let remaining = snapshot.remaining.map { $0.formatted(.number.precision(.fractionLength(0...2))) } ?? "未知"
            appendLog("用量查询完成：已用 \(used)，剩余 \(remaining)", level: .success)
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
        UserDefaults.standard.removeObject(forKey: logsStorageKey)
    }

    func refreshConnectionHealth(logResult: Bool = true) async {
        guard !isCheckingConnectionHealth, !isBusy else { return }
        isCheckingConnectionHealth = true
        defer { isCheckingConnectionHealth = false }

        for profile in accountProfiles {
            accountProfileHealth[profile.id] = .checking
            do {
                accountProfileHealth[profile.id] = try await accountProfileRepository
                    .credentialHealth(for: profile.id)
            } catch {
                accountProfileHealth[profile.id] = .unavailable("本地凭据无法读取")
            }
        }

        for profile in profiles {
            if Self.isExpired(profile.expiresAt) {
                apiProfileHealth[profile.id] = .expired("激活密钥已过期")
                continue
            }
            apiProfileHealth[profile.id] = .checking
            do {
                let credentials = try await profileRepository.credentials(for: profile.id)
                try await service.validateService(baseURL: profile.apiBaseURL, token: credentials.token)
                apiProfileHealth[profile.id] = .available("服务验证通过")
            } catch {
                apiProfileHealth[profile.id] = .unavailable(Self.connectionFailureMessage(error))
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
                try await profileRepository.updateCustomConnection(
                    activeProfile.id,
                    apiBaseURL: apiBaseURL,
                    model: model,
                    models: models
                )
                modelCatalogURL = try await manager.writeModelCatalog(models: catalogModels)
            } else {
                modelCatalogURL = nil
            }
            environment = try await manager.updateConnection(
                apiBaseURL: apiBaseURL,
                model: model,
                helperExecutable: executable,
                modelCatalogURL: modelCatalogURL
            )
            if let activationKey = try store.string(for: .activationKey),
               let token = try store.string(for: .apiToken) {
                _ = try await profileRepository.save(
                    activationKey: activationKey,
                    token: token,
                    apiBaseURL: apiBaseURL,
                    model: model,
                    expiresAt: expiresAt
                )
                try await refreshProfiles()
            }
            apiBaseURLInput = apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            try await refreshProfiles()
            markCodexReloadRequired()
        }
    }

    private func activateProfile(_ identifier: UUID) async throws {
        let credentials = try await profileRepository.credentials(for: identifier)
        var activeToken = credentials.token
        let modelCatalogURL: URL?
        if credentials.profile.kind == .customResponses {
            try await service.validateService(baseURL: credentials.profile.apiBaseURL, token: activeToken)
            let models: [String]
            if !credentials.profile.models.isEmpty {
                models = credentials.profile.models
            } else {
                models = (try? await service.fetchModels(baseURL: credentials.profile.apiBaseURL, token: activeToken))
                    ?? [credentials.profile.model]
                try await profileRepository.updateModels(models, for: credentials.profile.id)
            }
            modelCatalogURL = try await manager.writeModelCatalog(models: models)
        } else {
            modelCatalogURL = nil
            do {
                try await service.validateService(baseURL: credentials.profile.apiBaseURL, token: activeToken)
            } catch let error as HarborError {
                guard case .serverRejected = error else { throw error }
                appendLog("当前服务令牌已失效，正在使用激活密钥刷新")
                let deviceHash = try DeviceIdentity.hash(using: store)
                let receipt = try await service.redeem(
                    activationKey: credentials.activationKey,
                    deviceHash: deviceHash
                )
                activeToken = receipt.token
                try await service.validateService(baseURL: credentials.profile.apiBaseURL, token: activeToken)
                _ = try await profileRepository.save(
                    activationKey: credentials.activationKey,
                    token: activeToken,
                    apiBaseURL: credentials.profile.apiBaseURL,
                    model: credentials.profile.model,
                    expiresAt: receipt.expiresAt ?? credentials.profile.expiresAt,
                    select: false
                )
                appendLog("服务令牌刷新并验证通过", level: .success)
            }
        }
        let previousToken = try store.data(for: .apiToken)
        let previousActivationKey = try store.data(for: .activationKey)
        let previousAPIBaseURL = environment.apiBaseURL
        let previousModel = environment.model
        let previousMode = environment.activeMode
        let previousModelCatalog = try? await manager.modelCatalogSnapshot()
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
            if environment.deploymentExists {
                environment = try await manager.updateConnection(
                    apiBaseURL: credentials.profile.apiBaseURL,
                    model: credentials.profile.model,
                    helperExecutable: executable,
                    modelCatalogURL: modelCatalogURL
                )
            } else {
                environment = try await manager.deploy(.init(
                    token: activeToken,
                    apiBaseURL: credentials.profile.apiBaseURL,
                    model: credentials.profile.model,
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
            try await profileRepository.select(identifier)
            try await refreshProfiles()
            try? await manager.invalidateModelCatalogCache()
            usage = nil
            expiresAt = credentials.profile.kind == .harbor ? credentials.profile.expiresAt : nil
            apiBaseURLInput = credentials.profile.apiBaseURL.absoluteString
            apiBaseURLWasEdited = false
            appendLog("当前密钥档案：\(credentials.profile.name)", level: .success)
            markCodexReloadRequired()
        } catch {
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

    private func refreshProfiles() async throws {
        profiles = try await profileRepository.profiles()
        apiProfileHealth = apiProfileHealth.filter { key, _ in
            profiles.contains(where: { $0.id == key })
        }
        for profile in profiles where apiProfileHealth[profile.id] == nil {
            apiProfileHealth[profile.id] = Self.isExpired(profile.expiresAt)
                ? .expired("激活密钥已过期")
                : .unchecked
        }
        selectedProfileID = try await profileRepository.selectedProfileID()
        if environment.activeMode == .harbor,
           let token = try store.data(for: .apiToken) {
            activeProfileID = try await profileRepository.profileID(matchingToken: token)
            if let activeProfileID { selectedProfileID = activeProfileID }
        } else {
            activeProfileID = nil
        }
    }

    private var activeCustomProfile: HarborProfile? {
        guard let activeProfileID,
              let profile = profiles.first(where: { $0.id == activeProfileID }),
              profile.kind == .customResponses else { return nil }
        return profile
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
        let credentials = try await profileRepository.credentials(for: profile.id)
        let models = try await service.fetchModels(baseURL: profile.apiBaseURL, token: credentials.token)
        try await profileRepository.updateModels(models, for: profile.id)
        let catalogModels = models.contains(profile.model) ? models : [profile.model] + models
        return try await manager.writeModelCatalog(models: catalogModels)
    }

    private func refreshAccountProfiles() async throws {
        let profiles = try await accountProfileRepository.profiles()
        accountProfiles = profiles.filter { $0.method == .chatGPT || $0.method == .apiKey }
        accountProfileHealth = accountProfileHealth.filter { key, _ in
            accountProfiles.contains(where: { $0.id == key })
        }
        for profile in accountProfiles where accountProfileHealth[profile.id] == nil {
            accountProfileHealth[profile.id] = .unchecked
        }
        let selected = try await accountProfileRepository.selectedProfileID()
        selectedAccountProfileID = accountProfiles.contains(where: { $0.id == selected }) ? selected : nil
    }

    private func refreshEnvironment(recoverInterruptedDeployment: Bool) async throws {
        if recoverInterruptedDeployment {
            try await manager.recoverInterruptedDeploymentIfNeeded()
        }
        environment = try await manager.inspect()
        try await profileRepository.migrateLegacyProfileIfNeeded(environment: environment)
        try await accountProfileRepository.synchronizeCurrentLoginIfPresent()
        try await refreshProfiles()
        try await refreshAccountProfiles()
        if let apiURL = environment.apiBaseURL {
            apiBaseURLInput = apiURL.absoluteString
        }
    }

    private nonisolated static func codexExecutableURL() throws -> URL {
        let fileManager = FileManager.default
        let fixedCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = fixedCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        if let path = searchPaths
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("codex").path })
            .first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw HarborError.invalidConfiguration("未找到 Codex 官方命令行工具")
    }

    private nonisolated static func isExpired(_ value: String?) -> Bool {
        guard let value, !value.isEmpty else { return false }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = iso.date(from: value) { return date <= Date() }
        iso.formatOptions = [.withInternetDateTime]
        if let date = iso.date(from: value) { return date <= Date() }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        for format in ["yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: value.replacingOccurrences(of: "T", with: " ")) {
                return date <= Date()
            }
        }
        return false
    }

    private nonisolated static func connectionFailureMessage(_ error: Error) -> String {
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
            process.environment = codexProcessEnvironment()
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

    private func launchCodexLogin(executable: URL, codexHome: URL) throws {
        if codexLoginProcess?.isRunning == true { return }
        let process = Process()
        process.executableURL = executable
        process.arguments = ["login", "-c", "cli_auth_credentials_store=\"file\""]
        var environment = Self.codexProcessEnvironment()
        environment["CODEX_HOME"] = codexHome.path
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        codexLoginProcess = process
    }

    private func stopAccountLoginProcess() async {
        guard let process = codexLoginProcess else { return }
        if process.isRunning {
            process.terminate()
            for _ in 0..<8 where process.isRunning {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if process.isRunning {
                _ = Darwin.kill(process.processIdentifier, SIGKILL)
            }
        }
        codexLoginProcess = nil
    }

    private func cleanupAccountLoginHome() {
        guard let loginHome = accountLoginHomeURL else { return }
        try? FileManager.default.removeItem(at: loginHome)
        accountLoginHomeURL = nil
    }

    private nonisolated static func codexProcessEnvironment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
        let currentPaths = (environment["PATH"] ?? "").split(separator: ":").map(String.init)
        environment["PATH"] = (requiredPaths + currentPaths)
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) { result.append(path) }
            }
            .joined(separator: ":")
        return environment
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

    private func appendLog(_ message: String, level: HarborLogEntry.Level = .info) {
        logs.append(HarborLogEntry(
            timeText: Date().formatted(date: .omitted, time: .standard),
            level: level,
            message: redacted(message)
        ))
        if logs.count > 200 {
            logs.removeFirst(logs.count - 200)
        }
        if let data = try? JSONEncoder().encode(logs) {
            UserDefaults.standard.set(data, forKey: logsStorageKey)
        }
    }

    private func redacted(_ message: String) -> String {
        let key = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return message }
        return message.replacingOccurrences(of: key, with: "••••••")
    }
}
