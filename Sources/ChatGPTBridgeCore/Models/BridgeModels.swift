import Foundation

public enum BridgeError: Error, LocalizedError, Sendable {
    case invalidPath(String)
    case pathNotAllowed(String)
    case workspaceNotFound(UUID)
    case fileTooLarge(String)
    case invalidReadRange
    case searchFailed(String)
    case editTargetNotUnique(Int)
    case fileAlreadyExists(String)
    case writeFailed(String)
    case patchFailed(String)
    case gitFailed(String)
    case permissionDenied(String)
    case approvalRequired(String)
    case commandBlocked(String)
    case commandTimedOut(Int)
    case commandSessionNotFound(UUID)
    case workflowSessionNotFound(UUID)
    case codingTaskNotFound(UUID)

    public var errorDescription: String? {
        switch self {
        case .invalidPath(let path):
            return "无效路径：\(path)"
        case .pathNotAllowed(let path):
            return "路径不在允许范围内：\(path)"
        case .workspaceNotFound(let id):
            return "Workspace 不存在：\(id.uuidString)"
        case .fileTooLarge(let path):
            return "文件过大，拒绝直接读取：\(path)"
        case .invalidReadRange:
            return "读取范围无效"
        case .searchFailed(let message):
            return "搜索失败：\(message)"
        case .editTargetNotUnique(let count):
            return "精确修改要求 oldText 唯一匹配，当前匹配 \(count) 次"
        case .fileAlreadyExists(let path):
            return "目标文件已存在：\(path)"
        case .writeFailed(let message):
            return "写入失败：\(message)"
        case .patchFailed(let message):
            return "Patch 失败：\(message)"
        case .gitFailed(let message):
            return "Git 操作失败：\(message)"
        case .permissionDenied(let operation):
            return "权限策略拒绝操作：\(operation)"
        case .approvalRequired(let operation):
            return "操作需要用户确认：\(operation)"
        case .commandBlocked(let reason):
            return "命令已被安全策略阻止：\(reason)"
        case .commandTimedOut(let seconds):
            return "命令执行超过 \(seconds) 秒，已终止"
        case .commandSessionNotFound(let id):
            return "命令任务不存在或已过期：\(id.uuidString)"
        case .workflowSessionNotFound(let id):
            return "工作流任务不存在或已过期：\(id.uuidString)"
        case .codingTaskNotFound(let id):
            return "Coding Task 不存在或已过期：\(id.uuidString)"
        }
    }
}

public struct BridgePaths: Sendable {
    public let root: URL
    public let configurationURL: URL
    public let permissionsURL: URL
    public let workspacesURL: URL
    public let workspaceSessionsURL: URL
    public let runtimeURL: URL
    public let credentialsURL: URL
    public let chatGPTIntegrationURL: URL
    public let logsDirectory: URL

    public init(root: URL) {
        let normalizedRoot = root.standardizedFileURL
        self.root = normalizedRoot
        self.configurationURL = normalizedRoot.appendingPathComponent("config.json")
        self.permissionsURL = normalizedRoot.appendingPathComponent("permissions.json")
        self.workspacesURL = normalizedRoot.appendingPathComponent("workspaces.json")
        self.workspaceSessionsURL = normalizedRoot.appendingPathComponent("workspace-sessions.json")
        self.runtimeURL = normalizedRoot.appendingPathComponent("runtime.json")
        self.credentialsURL = normalizedRoot.appendingPathComponent("credentials.json")
        self.chatGPTIntegrationURL = normalizedRoot.appendingPathComponent("chatgpt-integration.json")
        self.logsDirectory = normalizedRoot.appendingPathComponent("logs", isDirectory: true)
    }

    public static func live(fileManager: FileManager = .default) throws -> BridgePaths {
        guard let applicationSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            throw BridgeError.invalidPath("Application Support")
        }
        return BridgePaths(
            root: applicationSupport
                .appendingPathComponent("CodexHarbor", isDirectory: true)
                .appendingPathComponent("ChatGPTBridge", isDirectory: true)
        )
    }

    public func ensureDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: logsDirectory, withIntermediateDirectories: true)
    }
}

public struct ChatGPTIntegrationMarker: Codable, Equatable, Sendable {
    public var transportMode: BridgeTransportMode
    public var hostname: String?
    public var configuredAt: Date
    public var lastActivityAt: Date
    public var discoveredToolCatalogVersion: String?
    public var discoveredToolCount: Int?
    public var catalogDiscoveredAt: Date?

    public init(
        transportMode: BridgeTransportMode,
        hostname: String? = nil,
        configuredAt: Date = Date(),
        lastActivityAt: Date = Date(),
        discoveredToolCatalogVersion: String? = nil,
        discoveredToolCount: Int? = nil,
        catalogDiscoveredAt: Date? = nil
    ) {
        self.transportMode = transportMode
        self.hostname = hostname
        self.configuredAt = configuredAt
        self.lastActivityAt = lastActivityAt
        self.discoveredToolCatalogVersion = discoveredToolCatalogVersion
        self.discoveredToolCount = discoveredToolCount
        self.catalogDiscoveredAt = catalogDiscoveredAt
    }
}

public struct ChatGPTIntegrationMarkerStore: Sendable {
    private let paths: BridgePaths

    public init(paths: BridgePaths) {
        self.paths = paths
    }

    public func load() -> ChatGPTIntegrationMarker? {
        guard let data = try? Data(contentsOf: paths.chatGPTIntegrationURL) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(ChatGPTIntegrationMarker.self, from: data)
    }

    public func save(_ marker: ChatGPTIntegrationMarker) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(marker).write(to: paths.chatGPTIntegrationURL, options: .atomic)
    }

    public func matchesPublicHTTPS(hostname: String?) -> Bool {
        guard let marker = load(),
              marker.transportMode == .httpsCompatibility,
              let markerHost = marker.hostname?.lowercased(),
              let hostname = hostname?.lowercased() else { return false }
        return markerHost == hostname
    }
}

public enum ModificationPermission: String, Codable, Sendable {
    case allow
    case ask
    case deny
}

public enum ShellPermission: String, Codable, Sendable {
    case allow
    case safeOnly
    case ask
    case deny
}

public enum GitPermission: String, Codable, Sendable {
    case allow
    case ask
    case deny
}

public enum BridgeTransportMode: String, Codable, Sendable {
    case secureTunnel
    case httpsCompatibility

    public var displayName: String {
        switch self {
        case .secureTunnel: "OpenAI 本地管道"
        case .httpsCompatibility: "公网 HTTPS"
        }
    }

    public var shortDisplayName: String {
        switch self {
        case .secureTunnel: "本地管道"
        case .httpsCompatibility: "HTTPS"
        }
    }
}

public struct HTTPSCompatibilityConfiguration: Codable, Equatable, Sendable {
    public var tunnelName: String
    public var tunnelID: String
    public var hostname: String
    public var credentialsFilePath: String
    public var cloudflaredPath: String
    public var localPort: UInt16

    public init(
        tunnelName: String,
        tunnelID: String,
        hostname: String,
        credentialsFilePath: String,
        cloudflaredPath: String,
        localPort: UInt16 = 19_473
    ) {
        self.tunnelName = tunnelName
        self.tunnelID = tunnelID
        self.hostname = hostname
        self.credentialsFilePath = credentialsFilePath
        self.cloudflaredPath = cloudflaredPath
        self.localPort = localPort
    }

    public var publicBaseURL: URL? {
        URL(string: "https://\(hostname)")
    }
}

public enum TunnelProxyStrategy: String, Codable, CaseIterable, Sendable {
    case automatic
    case system
    case direct

    public var displayName: String {
        switch self {
        case .automatic: "自动"
        case .system: "系统代理"
        case .direct: "直连"
        }
    }
}

public enum TunnelProxyRoute: String, Codable, Sendable {
    case systemProxy
    case direct

    public var displayName: String {
        switch self {
        case .systemProxy: "系统代理"
        case .direct: "直连"
        }
    }
}

public struct TunnelProxyStatus: Codable, Equatable, Sendable {
    public var strategy: TunnelProxyStrategy
    public var selectedRoute: TunnelProxyRoute
    public var systemProxyDetected: Bool
    public var systemProxyDescription: String?
    public var proxyReachable: Bool?
    public var directReachable: Bool?
    public var checkedAt: Date
    public var message: String

    public init(
        strategy: TunnelProxyStrategy,
        selectedRoute: TunnelProxyRoute,
        systemProxyDetected: Bool,
        systemProxyDescription: String? = nil,
        proxyReachable: Bool? = nil,
        directReachable: Bool? = nil,
        checkedAt: Date = Date(),
        message: String
    ) {
        self.strategy = strategy
        self.selectedRoute = selectedRoute
        self.systemProxyDetected = systemProxyDetected
        self.systemProxyDescription = systemProxyDescription
        self.proxyReachable = proxyReachable
        self.directReachable = directReachable
        self.checkedAt = checkedAt
        self.message = message
    }
}

public struct SecureTunnelConfiguration: Codable, Equatable, Sendable {
    public var tunnelID: String
    public var executablePath: String?
    public var controlPlaneBaseURL: String
    public var proxyStrategy: TunnelProxyStrategy

    public init(
        tunnelID: String,
        executablePath: String? = nil,
        controlPlaneBaseURL: String = "https://api.openai.com",
        proxyStrategy: TunnelProxyStrategy = .automatic
    ) {
        self.tunnelID = tunnelID
        self.executablePath = executablePath
        self.controlPlaneBaseURL = controlPlaneBaseURL
        self.proxyStrategy = proxyStrategy
    }

    private enum CodingKeys: String, CodingKey {
        case tunnelID
        case executablePath
        case controlPlaneBaseURL
        case proxyStrategy
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        tunnelID = try container.decode(String.self, forKey: .tunnelID)
        executablePath = try container.decodeIfPresent(String.self, forKey: .executablePath)
        controlPlaneBaseURL = try container.decodeIfPresent(String.self, forKey: .controlPlaneBaseURL)
            ?? "https://api.openai.com"
        proxyStrategy = try container.decodeIfPresent(TunnelProxyStrategy.self, forKey: .proxyStrategy)
            ?? .automatic
    }
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    /// Configuration schema version for future migrations.
    public var schemaVersion: Int = 1
    public static let defaultLocalMCPPort: UInt16 = 19_473

    public var enabled: Bool
    public var launchAtLogin: Bool
    public var allowedRoots: [String]
    public var modificationPermission: ModificationPermission
    public var shellPermission: ShellPermission
    public var gitPushPermission: GitPermission
    public var transportMode: BridgeTransportMode
    public var secureTunnel: SecureTunnelConfiguration?
    public var httpsCompatibility: HTTPSCompatibilityConfiguration?

    public init(
        schemaVersion: Int = 1,
        enabled: Bool = false,
        launchAtLogin: Bool = false,
        allowedRoots: [String] = [],
        modificationPermission: ModificationPermission = .ask,
        shellPermission: ShellPermission = .safeOnly,
        gitPushPermission: GitPermission = .ask,
        transportMode: BridgeTransportMode = .secureTunnel,
        secureTunnel: SecureTunnelConfiguration? = nil,
        httpsCompatibility: HTTPSCompatibilityConfiguration? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.enabled = enabled
        self.launchAtLogin = launchAtLogin
        self.allowedRoots = allowedRoots
        self.modificationPermission = modificationPermission
        self.shellPermission = shellPermission
        self.gitPushPermission = gitPushPermission
        self.transportMode = transportMode
        self.secureTunnel = secureTunnel
        self.httpsCompatibility = httpsCompatibility
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case enabled
        case launchAtLogin
        case allowedRoots
        case modificationPermission
        case shellPermission
        case gitPushPermission
        case transportMode
        case secureTunnel
        case httpsCompatibility
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schemaVersion = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        allowedRoots = try container.decodeIfPresent([String].self, forKey: .allowedRoots) ?? []
        modificationPermission = try container.decodeIfPresent(ModificationPermission.self, forKey: .modificationPermission) ?? .ask
        shellPermission = try container.decodeIfPresent(ShellPermission.self, forKey: .shellPermission) ?? .safeOnly
        gitPushPermission = try container.decodeIfPresent(GitPermission.self, forKey: .gitPushPermission) ?? .ask
        transportMode = try container.decodeIfPresent(BridgeTransportMode.self, forKey: .transportMode) ?? .secureTunnel
        secureTunnel = try container.decodeIfPresent(SecureTunnelConfiguration.self, forKey: .secureTunnel)
        httpsCompatibility = try container.decodeIfPresent(HTTPSCompatibilityConfiguration.self, forKey: .httpsCompatibility)
    }

    public var localMCPPort: UInt16 {
        httpsCompatibility?.localPort ?? Self.defaultLocalMCPPort
    }
}

public enum BridgeOverallState: String, Codable, Sendable {
    case disabled
    case starting
    case ready
    case degraded
    case failed
}

public enum AgentRuntimeState: String, Codable, Sendable {
    case stopped
    case starting
    case running
    case failed
}

public enum MCPRuntimeState: String, Codable, Sendable {
    case stopped
    case starting
    case ready
    case failed
}

public enum TunnelRuntimeState: String, Codable, Sendable {
    case disabled
    case connecting
    case connected
    case failed
}

public enum ChatGPTIntegrationState: String, Codable, Sendable {
    case notConfigured
    case configured
    case recentlyActive
    case unknown
}

public struct BridgeRuntimeState: Codable, Equatable, Sendable {
    public var overall: BridgeOverallState
    public var agent: AgentRuntimeState
    public var mcp: MCPRuntimeState
    public var tunnel: TunnelRuntimeState
    public var chatGPT: ChatGPTIntegrationState
    public var transportMode: BridgeTransportMode
    public var publicMCPHost: String?
    public var transportProcessRunning: Bool
    public var transportProcessIdentifier: Int32?
    public var remoteEndpointReady: Bool
    public var transportMessage: String?
    public var proxyStatus: TunnelProxyStatus?
    public var processIdentifier: Int32?
    public var mcpPort: UInt16?
    public var mcpURL: String?
    public var toolCatalogVersion: String?
    public var toolCatalogCount: Int?
    public var startedAt: Date?
    public var lastToolCallAt: Date?
    public var transportHealthCheckedAt: Date?
    public var controlPlaneLastSuccessAt: Date?
    public var controlPlanePollCycles: Int
    public var controlPlanePollErrors: Int
    public var lastToolCallName: String?
    public var lastToolCallSucceeded: Bool?
    public var lastToolCallMessage: String?
    public var health: BridgeHealthSnapshot
    public var pipelineDiagnostics: BridgePipelineDiagnostics

    public init(
        overall: BridgeOverallState = .disabled,
        agent: AgentRuntimeState = .stopped,
        mcp: MCPRuntimeState = .stopped,
        tunnel: TunnelRuntimeState = .disabled,
        chatGPT: ChatGPTIntegrationState = .notConfigured,
        transportMode: BridgeTransportMode = .secureTunnel,
        publicMCPHost: String? = nil,
        transportProcessRunning: Bool = false,
        transportProcessIdentifier: Int32? = nil,
        remoteEndpointReady: Bool = false,
        transportMessage: String? = nil,
        proxyStatus: TunnelProxyStatus? = nil,
        processIdentifier: Int32? = nil,
        mcpPort: UInt16? = nil,
        mcpURL: String? = nil,
        toolCatalogVersion: String? = nil,
        toolCatalogCount: Int? = nil,
        startedAt: Date? = nil,
        lastToolCallAt: Date? = nil,
        transportHealthCheckedAt: Date? = nil,
        controlPlaneLastSuccessAt: Date? = nil,
        controlPlanePollCycles: Int = 0,
        controlPlanePollErrors: Int = 0,
        lastToolCallName: String? = nil,
        lastToolCallSucceeded: Bool? = nil,
        lastToolCallMessage: String? = nil,
        health: BridgeHealthSnapshot = BridgeHealthSnapshot(),
        pipelineDiagnostics: BridgePipelineDiagnostics = BridgePipelineDiagnostics()
    ) {
        self.overall = overall
        self.agent = agent
        self.mcp = mcp
        self.tunnel = tunnel
        self.chatGPT = chatGPT
        self.transportMode = transportMode
        self.publicMCPHost = publicMCPHost
        self.transportProcessRunning = transportProcessRunning
        self.transportProcessIdentifier = transportProcessIdentifier
        self.remoteEndpointReady = remoteEndpointReady
        self.transportMessage = transportMessage
        self.proxyStatus = proxyStatus
        self.processIdentifier = processIdentifier
        self.mcpPort = mcpPort
        self.mcpURL = mcpURL
        self.toolCatalogVersion = toolCatalogVersion
        self.toolCatalogCount = toolCatalogCount
        self.startedAt = startedAt
        self.lastToolCallAt = lastToolCallAt
        self.transportHealthCheckedAt = transportHealthCheckedAt
        self.controlPlaneLastSuccessAt = controlPlaneLastSuccessAt
        self.controlPlanePollCycles = controlPlanePollCycles
        self.controlPlanePollErrors = controlPlanePollErrors
        self.lastToolCallName = lastToolCallName
        self.lastToolCallSucceeded = lastToolCallSucceeded
        self.lastToolCallMessage = lastToolCallMessage
        self.health = health
        self.pipelineDiagnostics = pipelineDiagnostics
    }

    private enum CodingKeys: String, CodingKey {
        case overall
        case agent
        case mcp
        case tunnel
        case chatGPT
        case transportMode
        case publicMCPHost
        case transportProcessRunning
        case transportProcessIdentifier
        case remoteEndpointReady
        case transportMessage
        case proxyStatus
        case processIdentifier
        case mcpPort
        case mcpURL
        case toolCatalogVersion
        case toolCatalogCount
        case startedAt
        case lastToolCallAt
        case transportHealthCheckedAt
        case controlPlaneLastSuccessAt
        case controlPlanePollCycles
        case controlPlanePollErrors
        case lastToolCallName
        case lastToolCallSucceeded
        case lastToolCallMessage
        case health
        case pipelineDiagnostics
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        overall = try container.decodeIfPresent(BridgeOverallState.self, forKey: .overall) ?? .disabled
        agent = try container.decodeIfPresent(AgentRuntimeState.self, forKey: .agent) ?? .stopped
        mcp = try container.decodeIfPresent(MCPRuntimeState.self, forKey: .mcp) ?? .stopped
        tunnel = try container.decodeIfPresent(TunnelRuntimeState.self, forKey: .tunnel) ?? .disabled
        chatGPT = try container.decodeIfPresent(ChatGPTIntegrationState.self, forKey: .chatGPT) ?? .notConfigured
        transportMode = try container.decodeIfPresent(BridgeTransportMode.self, forKey: .transportMode) ?? .secureTunnel
        publicMCPHost = try container.decodeIfPresent(String.self, forKey: .publicMCPHost)
        transportProcessRunning = try container.decodeIfPresent(Bool.self, forKey: .transportProcessRunning)
            ?? (tunnel == .connected || tunnel == .connecting)
        transportProcessIdentifier = try container.decodeIfPresent(Int32.self, forKey: .transportProcessIdentifier)
        remoteEndpointReady = try container.decodeIfPresent(Bool.self, forKey: .remoteEndpointReady)
            ?? (tunnel == .connected)
        transportMessage = try container.decodeIfPresent(String.self, forKey: .transportMessage)
        proxyStatus = try container.decodeIfPresent(TunnelProxyStatus.self, forKey: .proxyStatus)
        processIdentifier = try container.decodeIfPresent(Int32.self, forKey: .processIdentifier)
        mcpPort = try container.decodeIfPresent(UInt16.self, forKey: .mcpPort)
        mcpURL = try container.decodeIfPresent(String.self, forKey: .mcpURL)
        toolCatalogVersion = try container.decodeIfPresent(String.self, forKey: .toolCatalogVersion)
        toolCatalogCount = try container.decodeIfPresent(Int.self, forKey: .toolCatalogCount)
        startedAt = try container.decodeIfPresent(Date.self, forKey: .startedAt)
        lastToolCallAt = try container.decodeIfPresent(Date.self, forKey: .lastToolCallAt)
        transportHealthCheckedAt = try container.decodeIfPresent(Date.self, forKey: .transportHealthCheckedAt)
        controlPlaneLastSuccessAt = try container.decodeIfPresent(Date.self, forKey: .controlPlaneLastSuccessAt)
        controlPlanePollCycles = try container.decodeIfPresent(Int.self, forKey: .controlPlanePollCycles) ?? 0
        controlPlanePollErrors = try container.decodeIfPresent(Int.self, forKey: .controlPlanePollErrors) ?? 0
        lastToolCallName = try container.decodeIfPresent(String.self, forKey: .lastToolCallName)
        lastToolCallSucceeded = try container.decodeIfPresent(Bool.self, forKey: .lastToolCallSucceeded)
        lastToolCallMessage = try container.decodeIfPresent(String.self, forKey: .lastToolCallMessage)
        health = try container.decodeIfPresent(BridgeHealthSnapshot.self, forKey: .health) ?? BridgeHealthSnapshot()
        pipelineDiagnostics = try container.decodeIfPresent(
            BridgePipelineDiagnostics.self,
            forKey: .pipelineDiagnostics
        ) ?? BridgePipelineDiagnostics()
    }
}

public struct BridgeWorkspace: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let rootPath: String
    public let displayName: String
    public let createdAt: Date
    public var lastOpenedAt: Date
    public var gitBranch: String?
    public var isGitDirty: Bool

    public init(
        id: UUID = UUID(),
        rootPath: String,
        displayName: String,
        createdAt: Date = Date(),
        lastOpenedAt: Date = Date(),
        gitBranch: String? = nil,
        isGitDirty: Bool = false
    ) {
        self.id = id
        self.rootPath = rootPath
        self.displayName = displayName
        self.createdAt = createdAt
        self.lastOpenedAt = lastOpenedAt
        self.gitBranch = gitBranch
        self.isGitDirty = isGitDirty
    }
}
