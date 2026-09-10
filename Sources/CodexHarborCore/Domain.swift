import Foundation

public enum CodexMode: String, Codable, CaseIterable, Sendable {
    case harbor
    case chatGPT

    public var title: String {
        switch self {
        case .harbor: "托管连接"
        case .chatGPT: "账户登录"
        }
    }
}

/// Defaults used when Harbor creates or explicitly switches the first-party
/// account and hosted-key connections. Custom API profiles keep their own
/// provider model instead of being rewritten to this value.
public enum CodexDefaults {
    public static let model = "gpt-5.6-sol"
    public static let reasoningEffort = "medium"
    public static let serviceTier = "default"
}

/// User-facing connection categories. Harbor and custom API connections both
/// use Codex's managed provider internally, but their credentials and service
/// capabilities are different and must remain distinguishable.
public enum CodexConnectionKind: String, Codable, CaseIterable, Sendable {
    case account
    case harborKey
    case apiKey

    public var title: String {
        switch self {
        case .account: "账户登录"
        case .harborKey: "托管密钥"
        case .apiKey: "自定义 API 密钥"
        }
    }

    public var icon: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .harborKey: "key.fill"
        case .apiKey: "network"
        }
    }

    public var executionMode: CodexMode {
        switch self {
        case .account: .chatGPT
        case .harborKey, .apiKey: .harbor
        }
    }
}

public enum ConnectionHealth: Equatable, Sendable {
    case unchecked
    case checking
    case available(String? = nil)
    case expired(String? = nil)
    case unavailable(String? = nil)
}

public enum HarborProfileKind: String, Codable, Sendable {
    case harbor
    case customResponses

    public var title: String {
        switch self {
        case .harbor: CodexConnectionKind.harborKey.title
        case .customResponses: CodexConnectionKind.apiKey.title
        }
    }

    public var connectionKind: CodexConnectionKind {
        switch self {
        case .harbor: .harborKey
        case .customResponses: .apiKey
        }
    }
}

/// Protocol spoken by the upstream service behind Harbor Relay. Codex always
/// talks Responses to the local relay; the relay either forwards that request
/// unchanged or translates it to Chat Completions.
public enum HarborRelayProtocol: String, Codable, CaseIterable, Sendable {
    case automatic
    case responses
    case chatCompletions

    public var title: String {
        switch self {
        case .automatic: "自动识别"
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        }
    }
}

/// Provider templates for user-managed API connections. All templates use the
/// OpenAI Responses-compatible wire format that Codex can execute today.
public enum CustomAPIProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case openAICompatible
    case otherCompatibleGateway

    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openAICompatible: "OpenAI 兼容"
        case .otherCompatibleGateway: "其他兼容网关"
        }
    }

    public var subtitle: String {
        switch self {
        case .openAI: "官方 API"
        case .openAICompatible: "支持 Responses API 的第三方服务"
        case .otherCompatibleGateway: "Claude / Gemini 等协议的兼容网关"
        }
    }

    public var icon: String {
        switch self {
        case .openAI: "sparkles"
        case .openAICompatible: "arrow.triangle.2.circlepath"
        case .otherCompatibleGateway: "point.3.connected.trianglepath.dotted"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openAICompatible, .otherCompatibleGateway: "https://api.example.com/v1"
        }
    }

    public var defaultModel: String {
        "gpt-5.3-codex"
    }

    public var capabilityNote: String {
        switch self {
        case .openAI: "使用 OpenAI 官方 Responses API。"
        case .openAICompatible: "服务商必须提供 OpenAI Responses API 兼容接口。"
        case .otherCompatibleGateway: "仅适用于已转换为 OpenAI Responses API 的 Claude / Gemini 网关；不代表原生协议支持。"
        }
    }
}

public struct ActivationReceipt: Equatable, Sendable {
    public let token: String
    public let expiresAt: String?
    public let message: String?

    public init(token: String, expiresAt: String? = nil, message: String? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.message = message
    }
}

public struct HarborRemoteConfiguration: Equatable, Sendable {
    public var apiBaseURL: URL
    public var model: String
    public var notice: String?

    public init(apiBaseURL: URL, model: String, notice: String? = nil) {
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.notice = notice
    }

    public static let fallback = HarborRemoteConfiguration(
        apiBaseURL: URL(string: "https://codex.ai02.cn/v1")!,
        model: CodexDefaults.model
    )
}

public struct UsageSnapshot: Equatable, Sendable {
    public var used: Double?
    public var remaining: Double?
    public var expiresAt: String?
    public var message: String?

    public init(used: Double? = nil, remaining: Double? = nil, expiresAt: String? = nil, message: String? = nil) {
        self.used = used
        self.remaining = remaining
        self.expiresAt = expiresAt
        self.message = message
    }
}

public enum ConnectionActivityKind: String, Codable, Sendable {
    case codexRequest
    case healthCheck
    case usageQuery
    case connectionSwitch
    case profileCreate
    case modelRefresh
    case codexReload

    public var title: String {
        switch self {
        case .codexRequest: "Codex 请求"
        case .healthCheck: "状态检查"
        case .usageQuery: "用量查询"
        case .connectionSwitch: "连接切换"
        case .profileCreate: "新增档案"
        case .modelRefresh: "模型更新"
        case .codexReload: "重载 Codex"
        }
    }
}

public struct ConnectionActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let connectionKind: CodexConnectionKind
    public let profileID: UUID?
    public let kind: ConnectionActivityKind
    public let succeeded: Bool
    public let durationMilliseconds: Int?
    public let sourceID: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        connectionKind: CodexConnectionKind,
        profileID: UUID?,
        kind: ConnectionActivityKind,
        succeeded: Bool,
        durationMilliseconds: Int? = nil,
        sourceID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.connectionKind = connectionKind
        self.profileID = profileID
        self.kind = kind
        self.succeeded = succeeded
        self.durationMilliseconds = durationMilliseconds
        self.sourceID = sourceID
    }
}

public struct ConnectionActivityDay: Equatable, Sendable {
    public let date: Date
    public let count: Int

    public init(date: Date, count: Int) {
        self.date = date
        self.count = count
    }
}

public struct CodexTokenUsageSummary: Equatable, Sendable {
    public let requestCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int

    public init(
        requestCount: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct ConnectionActivitySummary: Equatable, Sendable {
    public let eventsLast24Hours: Int
    public let eventsLast7Days: Int
    public let successfulEventsLast7Days: Int
    public let failedEventsLast7Days: Int
    public let averageDurationMilliseconds: Int?
    public let p95DurationMilliseconds: Int?
    public let lastObservedAt: Date?
    public let dailyCounts: [ConnectionActivityDay]

    public var successRate: Double? {
        guard eventsLast7Days > 0 else { return nil }
        return Double(successfulEventsLast7Days) / Double(eventsLast7Days)
    }

    public init(
        eventsLast24Hours: Int,
        eventsLast7Days: Int,
        successfulEventsLast7Days: Int,
        failedEventsLast7Days: Int,
        averageDurationMilliseconds: Int?,
        p95DurationMilliseconds: Int?,
        lastObservedAt: Date?,
        dailyCounts: [ConnectionActivityDay]
    ) {
        self.eventsLast24Hours = eventsLast24Hours
        self.eventsLast7Days = eventsLast7Days
        self.successfulEventsLast7Days = successfulEventsLast7Days
        self.failedEventsLast7Days = failedEventsLast7Days
        self.averageDurationMilliseconds = averageDurationMilliseconds
        self.p95DurationMilliseconds = p95DurationMilliseconds
        self.lastObservedAt = lastObservedAt
        self.dailyCounts = dailyCounts
    }

    public static func empty(now: Date = Date(), calendar: Calendar = .current) -> ConnectionActivitySummary {
        ConnectionActivitySummary(
            eventsLast24Hours: 0,
            eventsLast7Days: 0,
            successfulEventsLast7Days: 0,
            failedEventsLast7Days: 0,
            averageDurationMilliseconds: nil,
            p95DurationMilliseconds: nil,
            lastObservedAt: nil,
            dailyCounts: Self.emptyDays(now: now, calendar: calendar)
        )
    }

    public static func make(
        from events: [ConnectionActivityEvent],
        connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        calendar: Calendar = .current,
        eventKinds: Set<ConnectionActivityKind>? = nil
    ) -> ConnectionActivitySummary {
        let dayStarts = emptyDays(now: now, calendar: calendar).map(\.date)
        guard let oldestDay = dayStarts.first else { return .empty(now: now, calendar: calendar) }
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)
        let relevantEvents = events.filter {
            $0.connectionKind == connectionKind
                && (profileID == nil || $0.profileID == profileID)
                && (eventKinds == nil || eventKinds?.contains($0.kind) == true)
                && $0.timestamp >= oldestDay
                && $0.timestamp <= now
        }
        let durations = relevantEvents.compactMap(\.durationMilliseconds).sorted()
        let averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
        let p95Duration: Int?
        if durations.isEmpty {
            p95Duration = nil
        } else {
            let index = min(durations.count - 1, max(0, Int(ceil(Double(durations.count) * 0.95)) - 1))
            p95Duration = durations[index]
        }
        let countsByDay = Dictionary(grouping: relevantEvents) { event in
            calendar.startOfDay(for: event.timestamp)
        }.mapValues(\.count)
        let dailyCounts = dayStarts.map { dayStart in
            ConnectionActivityDay(date: dayStart, count: countsByDay[dayStart] ?? 0)
        }

        return ConnectionActivitySummary(
            eventsLast24Hours: relevantEvents.filter { $0.timestamp >= twentyFourHoursAgo }.count,
            eventsLast7Days: relevantEvents.count,
            successfulEventsLast7Days: relevantEvents.filter(\.succeeded).count,
            failedEventsLast7Days: relevantEvents.filter { !$0.succeeded }.count,
            averageDurationMilliseconds: averageDuration,
            p95DurationMilliseconds: p95Duration,
            lastObservedAt: relevantEvents.map(\.timestamp).max(),
            dailyCounts: dailyCounts
        )
    }

    private static func emptyDays(now: Date, calendar: Calendar) -> [ConnectionActivityDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return ConnectionActivityDay(date: date, count: 0)
        }
    }
}

public struct ServiceProbe: Equatable, Sendable {
    public let latencyMilliseconds: Int
    public let modelCount: Int?

    public init(latencyMilliseconds: Int, modelCount: Int?) {
        self.latencyMilliseconds = latencyMilliseconds
        self.modelCount = modelCount
    }
}

public struct HarborProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var keyFingerprint: String
    public var apiBaseURL: URL
    public var model: String
    public var kind: HarborProfileKind
    public var provider: CustomAPIProvider
    public var relayProtocol: HarborRelayProtocol
    public var models: [String]
    public var modelsUpdatedAt: Date?
    public var modelsVerified: Bool
    public var expiresAt: String?
    public var createdAt: Date

    public var modelsNeedRefresh: Bool {
        guard kind == .customResponses else { return false }
        guard let modelsUpdatedAt else { return models.isEmpty }
        return models.isEmpty || Date().timeIntervalSince(modelsUpdatedAt) > 24 * 60 * 60
    }

    public init(
        id: UUID = UUID(),
        name: String,
        keyFingerprint: String,
        apiBaseURL: URL,
        model: String,
        kind: HarborProfileKind = .harbor,
        provider: CustomAPIProvider = .openAI,
        relayProtocol: HarborRelayProtocol = .automatic,
        models: [String] = [],
        modelsUpdatedAt: Date? = nil,
        modelsVerified: Bool = false,
        expiresAt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyFingerprint = keyFingerprint
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.kind = kind
        self.provider = provider
        self.relayProtocol = relayProtocol
        self.models = models
        self.modelsUpdatedAt = modelsUpdatedAt
        self.modelsVerified = modelsVerified
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, keyFingerprint, apiBaseURL, model, kind, provider, relayProtocol, models, modelsUpdatedAt, modelsVerified, expiresAt, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        keyFingerprint = try values.decode(String.self, forKey: .keyFingerprint)
        apiBaseURL = try values.decode(URL.self, forKey: .apiBaseURL)
        model = try values.decode(String.self, forKey: .model)
        kind = try values.decodeIfPresent(HarborProfileKind.self, forKey: .kind) ?? .harbor
        provider = try values.decodeIfPresent(CustomAPIProvider.self, forKey: .provider)
            ?? (kind == .customResponses ? .openAICompatible : .openAI)
        relayProtocol = try values.decodeIfPresent(HarborRelayProtocol.self, forKey: .relayProtocol)
            ?? (provider == .openAI ? .responses : .automatic)
        models = try values.decodeIfPresent([String].self, forKey: .models) ?? []
        modelsUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .modelsUpdatedAt)
        modelsVerified = try values.decodeIfPresent(Bool.self, forKey: .modelsVerified) ?? false
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

public enum CodexAccountMethod: String, Codable, Sendable {
    case chatGPT
    case apiKey
    case unknown

    public var title: String {
        switch self {
        case .chatGPT: "ChatGPT 账户"
        case .apiKey: "OpenAI API 密钥"
        case .unknown: "Codex 登录"
        }
    }
}

public struct CodexAccountProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var method: CodexAccountMethod
    public var credentialFingerprint: String
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        method: CodexAccountMethod,
        credentialFingerprint: String,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.credentialFingerprint = credentialFingerprint
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var connectionKind: CodexConnectionKind { .account }
}

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
