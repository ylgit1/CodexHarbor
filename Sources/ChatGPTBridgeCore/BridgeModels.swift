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
    case permissionDenied(String)
    case approvalRequired(String)
    case commandBlocked(String)
    case commandTimedOut(Int)

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
        case .permissionDenied(let operation):
            return "权限策略拒绝操作：\(operation)"
        case .approvalRequired(let operation):
            return "操作需要用户确认：\(operation)"
        case .commandBlocked(let reason):
            return "命令已被安全策略阻止：\(reason)"
        case .commandTimedOut(let seconds):
            return "命令执行超过 \(seconds) 秒，已终止"
        }
    }
}

public struct BridgePaths: Sendable {
    public let root: URL
    public let configurationURL: URL
    public let permissionsURL: URL
    public let workspacesURL: URL
    public let runtimeURL: URL
    public let logsDirectory: URL

    public init(root: URL) {
        let normalizedRoot = root.standardizedFileURL
        self.root = normalizedRoot
        self.configurationURL = normalizedRoot.appendingPathComponent("config.json")
        self.permissionsURL = normalizedRoot.appendingPathComponent("permissions.json")
        self.workspacesURL = normalizedRoot.appendingPathComponent("workspaces.json")
        self.runtimeURL = normalizedRoot.appendingPathComponent("runtime.json")
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

public enum ModificationPermission: String, Codable, Sendable {
    case allow
    case ask
    case deny
}

public enum ShellPermission: String, Codable, Sendable {
    case safeOnly
    case ask
    case deny
}

public enum GitPermission: String, Codable, Sendable {
    case allow
    case ask
    case deny
}

public struct SecureTunnelConfiguration: Codable, Equatable, Sendable {
    public var tunnelID: String
    public var executablePath: String?
    public var controlPlaneBaseURL: String

    public init(
        tunnelID: String,
        executablePath: String? = nil,
        controlPlaneBaseURL: String = "https://api.openai.com"
    ) {
        self.tunnelID = tunnelID
        self.executablePath = executablePath
        self.controlPlaneBaseURL = controlPlaneBaseURL
    }
}

public struct BridgeConfiguration: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var launchAtLogin: Bool
    public var allowedRoots: [String]
    public var modificationPermission: ModificationPermission
    public var shellPermission: ShellPermission
    public var gitPushPermission: GitPermission
    public var secureTunnel: SecureTunnelConfiguration?

    public init(
        enabled: Bool = false,
        launchAtLogin: Bool = false,
        allowedRoots: [String] = [],
        modificationPermission: ModificationPermission = .ask,
        shellPermission: ShellPermission = .safeOnly,
        gitPushPermission: GitPermission = .ask,
        secureTunnel: SecureTunnelConfiguration? = nil
    ) {
        self.enabled = enabled
        self.launchAtLogin = launchAtLogin
        self.allowedRoots = allowedRoots
        self.modificationPermission = modificationPermission
        self.shellPermission = shellPermission
        self.gitPushPermission = gitPushPermission
        self.secureTunnel = secureTunnel
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case launchAtLogin
        case allowedRoots
        case modificationPermission
        case shellPermission
        case gitPushPermission
        case secureTunnel
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        launchAtLogin = try container.decodeIfPresent(Bool.self, forKey: .launchAtLogin) ?? false
        allowedRoots = try container.decodeIfPresent([String].self, forKey: .allowedRoots) ?? []
        modificationPermission = try container.decodeIfPresent(ModificationPermission.self, forKey: .modificationPermission) ?? .ask
        shellPermission = try container.decodeIfPresent(ShellPermission.self, forKey: .shellPermission) ?? .safeOnly
        gitPushPermission = try container.decodeIfPresent(GitPermission.self, forKey: .gitPushPermission) ?? .ask
        secureTunnel = try container.decodeIfPresent(SecureTunnelConfiguration.self, forKey: .secureTunnel)
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
    public var processIdentifier: Int32?
    public var mcpPort: UInt16?
    public var mcpURL: String?
    public var startedAt: Date?
    public var lastToolCallAt: Date?

    public init(
        overall: BridgeOverallState = .disabled,
        agent: AgentRuntimeState = .stopped,
        mcp: MCPRuntimeState = .stopped,
        tunnel: TunnelRuntimeState = .disabled,
        chatGPT: ChatGPTIntegrationState = .notConfigured,
        processIdentifier: Int32? = nil,
        mcpPort: UInt16? = nil,
        mcpURL: String? = nil,
        startedAt: Date? = nil,
        lastToolCallAt: Date? = nil
    ) {
        self.overall = overall
        self.agent = agent
        self.mcp = mcp
        self.tunnel = tunnel
        self.chatGPT = chatGPT
        self.processIdentifier = processIdentifier
        self.mcpPort = mcpPort
        self.mcpURL = mcpURL
        self.startedAt = startedAt
        self.lastToolCallAt = lastToolCallAt
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
