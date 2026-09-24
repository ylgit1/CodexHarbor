import Foundation

public struct DeploymentRequest: Sendable {
    public let token: String
    public let apiBaseURL: URL
    public let model: String
    public let helperExecutable: URL
    public let modelCatalogURL: URL?

    public init(token: String, apiBaseURL: URL, model: String, helperExecutable: URL, modelCatalogURL: URL? = nil) {
        self.token = token
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.helperExecutable = helperExecutable
        self.modelCatalogURL = modelCatalogURL
    }
}

public struct CodexEnvironment: Equatable, Sendable {
    public var configExists: Bool
    public var chatGPTSessionExists: Bool
    public var deploymentExists: Bool
    public var activeMode: CodexMode?
    public var apiBaseURL: URL?
    public var model: String?
    public var effectiveProvider: String?
    public var accountMethod: CodexAccountMethod?
    public var modelCatalogURL: URL?
    public var configurationDrift: Bool

    public init(
        configExists: Bool,
        chatGPTSessionExists: Bool,
        deploymentExists: Bool,
        activeMode: CodexMode?,
        apiBaseURL: URL? = nil,
        model: String? = nil,
        effectiveProvider: String? = nil,
        accountMethod: CodexAccountMethod? = nil,
        modelCatalogURL: URL? = nil,
        configurationDrift: Bool = false
    ) {
        self.configExists = configExists
        self.chatGPTSessionExists = chatGPTSessionExists
        self.deploymentExists = deploymentExists
        self.activeMode = activeMode
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.effectiveProvider = effectiveProvider
        self.accountMethod = accountMethod
        self.modelCatalogURL = modelCatalogURL
        self.configurationDrift = configurationDrift
    }
}

public enum HarborError: LocalizedError, Equatable {
    case invalidActivationKey
    case invalidServerResponse
    case serverRejected(String)
    case invalidBaseURL
    case invalidModel
    case existingManagedNamespace
    case deploymentAlreadyExists
    case deploymentNotFound
    case configurationChangedSinceDeployment
    case missingBackup
    case missingToken
    case missingAccountCredentials
    case invalidAccountCredentials
    case invalidConfiguration(String)
    case keychainFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidActivationKey: "请输入有效的激活密钥。"
        case .invalidServerResponse: "服务返回的数据格式不正确。"
        case let .serverRejected(message): message
        case .invalidBaseURL: "服务地址无效，只允许使用 HTTPS。"
        case .invalidModel: "模型名称无效。"
        case .existingManagedNamespace: "Codex 配置中已存在同名配置，请先处理冲突。"
        case .deploymentAlreadyExists: "Codex Harbor 配置已经部署。"
        case .deploymentNotFound: "没有找到可卸载的 Codex Harbor 配置。"
        case .configurationChangedSinceDeployment: "配置在部署后被其他程序修改，为避免丢失数据已停止卸载。"
        case .missingBackup: "找不到部署前备份，无法安全恢复。"
        case .missingToken: "Harbor 本地凭据库中没有可用的服务令牌。"
        case .missingAccountCredentials: "没有检测到可保存或切换的 Codex 登录。"
        case .invalidAccountCredentials: "Codex 登录缓存格式无效，已停止操作。"
        case let .invalidConfiguration(reason): "Codex 配置验证失败：\(reason)"
        case let .keychainFailure(status): "Keychain 操作失败（\(status)）。"
        }
    }
}

public struct CodexPaths: Sendable {
    public let codexHome: URL
    public let appSupport: URL

    public init(codexHome: URL, appSupport: URL) {
        self.codexHome = codexHome
        self.appSupport = appSupport
    }

    public static func live(fileManager: FileManager = .default) -> CodexPaths {
        let home = fileManager.homeDirectoryForCurrentUser
        return CodexPaths(
            codexHome: home.appendingPathComponent(".codex", isDirectory: true),
            appSupport: home
                .appendingPathComponent("Library/Application Support", isDirectory: true)
                .appendingPathComponent("Codex Harbor", isDirectory: true)
        )
    }

    public var configURL: URL { codexHome.appendingPathComponent("config.toml") }
    public var modelsCacheURL: URL { codexHome.appendingPathComponent("models_cache.json") }
    public var customModelsURL: URL { codexHome.appendingPathComponent("codex-harbor-models.json") }
    public var authURL: URL { codexHome.appendingPathComponent("auth.json") }
    public var sessionsURL: URL { codexHome.appendingPathComponent("sessions", isDirectory: true) }
    public var threadHistoryDatabaseURL: URL { codexHome.appendingPathComponent("thread_history_1.sqlite") }
    public var requestMonitorStateURL: URL { appSupport.appendingPathComponent("request-monitor-state.json") }
    public var tokenMonitorStateURL: URL { appSupport.appendingPathComponent("token-monitor-state.json") }
    public var activeManifestURL: URL { appSupport.appendingPathComponent("active-deployment.json") }
    public var transactionsURL: URL { appSupport.appendingPathComponent("transactions", isDirectory: true) }
    public var taskMigrationsURL: URL { appSupport.appendingPathComponent("task-migrations", isDirectory: true) }
    public var profilesURL: URL { appSupport.appendingPathComponent("profiles.json") }
    public var accountProfilesURL: URL { appSupport.appendingPathComponent("account-profiles.json") }
    public var credentialsURL: URL { appSupport.appendingPathComponent("credentials.json") }
    public var activityEventsURL: URL { appSupport.appendingPathComponent("activity-events.json") }
    public var relayConfigurationURL: URL { appSupport.appendingPathComponent("relay-configuration.json") }
    public var relayEventsURL: URL { appSupport.appendingPathComponent("relay-events.json") }
    public var relayPIDURL: URL { appSupport.appendingPathComponent("relay.pid") }
}
