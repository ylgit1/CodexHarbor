import Foundation

public enum CommandRisk: String, Codable, Equatable, Sendable {
    case safe
    case review
    case blocked
}

public struct CommandRequest: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let workingDirectory: String
    public let timeoutSeconds: Int

    public init(
        executable: String,
        arguments: [String] = [],
        workingDirectory: String = ".",
        timeoutSeconds: Int = 30
    ) {
        self.executable = executable
        self.arguments = arguments
        self.workingDirectory = workingDirectory
        self.timeoutSeconds = timeoutSeconds
    }
}

public struct CommandAssessment: Equatable, Sendable {
    public let risk: CommandRisk
    public let reason: String

    public init(risk: CommandRisk, reason: String) {
        self.risk = risk
        self.reason = reason
    }
}

public struct CommandPolicy: Sendable {
    public init() {}

    public func assess(_ request: CommandRequest) -> CommandAssessment {
        let executable = URL(fileURLWithPath: request.executable).lastPathComponent.lowercased()
        let arguments = request.arguments.map { $0.lowercased() }

        if ["bash", "zsh", "sh", "fish", "osascript", "sudo", "su"].contains(executable) {
            return CommandAssessment(risk: .blocked, reason: "禁止直接启动 shell、提权或脚本解释器")
        }
        if executable == "rm" {
            return CommandAssessment(risk: .blocked, reason: "第一版禁止删除命令")
        }
        if executable == "git" {
            let joined = arguments.joined(separator: " ")
            if joined.contains("push --force") || joined.contains("push -f") || joined.hasPrefix("reset --hard") || joined.hasPrefix("clean -fd") {
                return CommandAssessment(risk: .blocked, reason: "禁止破坏性 Git 操作")
            }
            if arguments.first == "push" || arguments.first == "add" || arguments.first == "commit" {
                return CommandAssessment(risk: .review, reason: "Git 写操作需要确认")
            }
            if ["status", "diff", "log", "show", "branch", "rev-parse"].contains(arguments.first ?? "") {
                return CommandAssessment(risk: .safe, reason: "只读 Git 操作")
            }
            return CommandAssessment(risk: .review, reason: "未明确列入安全列表的 Git 操作")
        }
        if executable == "swift" {
            if ["build", "test", "package", "--version"].contains(arguments.first ?? "") {
                return CommandAssessment(risk: .safe, reason: "允许 Swift 构建与测试")
            }
            return CommandAssessment(risk: .review, reason: "未明确列入安全列表的 Swift 操作")
        }
        if executable == "npm" {
            let prefix = arguments.prefix(2).joined(separator: " ")
            if arguments.first == "test" || prefix == "run build" || prefix == "run test" {
                return CommandAssessment(risk: .safe, reason: "允许 npm 构建与测试")
            }
            return CommandAssessment(risk: .review, reason: "npm 操作需要确认")
        }
        if ["pwd", "ls", "find", "rg", "echo", "cat", "head", "tail", "wc", "which", "node", "python", "python3"].contains(executable) {
            return CommandAssessment(risk: .safe, reason: "允许的本地开发只读命令")
        }
        if ["mkdir", "cp", "mv", "chmod", "chown"].contains(executable) {
            return CommandAssessment(risk: .review, reason: "文件系统修改需要确认")
        }
        return CommandAssessment(risk: .review, reason: "未知命令需要确认")
    }
}

public struct PermissionEngine: Sendable {
    private let configuration: BridgeConfiguration

    public init(configuration: BridgeConfiguration) {
        self.configuration = configuration
    }

    public func authorizeModification(operation: String, approvalGranted: Bool = false) throws {
        switch configuration.modificationPermission {
        case .allow:
            return
        case .ask:
            guard approvalGranted else { throw BridgeError.approvalRequired(operation) }
        case .deny:
            throw BridgeError.permissionDenied(operation)
        }
    }

    public func authorizeCommand(
        _ assessment: CommandAssessment,
        request: CommandRequest,
        approvalGranted: Bool = false
    ) throws {
        if assessment.risk == .blocked {
            throw BridgeError.commandBlocked(assessment.reason)
        }

        let executable = URL(fileURLWithPath: request.executable).lastPathComponent.lowercased()
        let firstArgument = request.arguments.first?.lowercased()
        if executable == "git", firstArgument == "push" {
            switch configuration.gitPushPermission {
            case .allow:
                break
            case .ask:
                guard approvalGranted else { throw BridgeError.approvalRequired(Self.commandSummary(request)) }
            case .deny:
                throw BridgeError.permissionDenied(Self.commandSummary(request))
            }
        }

        switch configuration.shellPermission {
        case .deny:
            throw BridgeError.permissionDenied(Self.commandSummary(request))
        case .ask:
            guard approvalGranted else { throw BridgeError.approvalRequired(Self.commandSummary(request)) }
        case .safeOnly:
            if assessment.risk == .safe { return }
            guard approvalGranted else { throw BridgeError.approvalRequired(Self.commandSummary(request)) }
        }
    }

    private static func commandSummary(_ request: CommandRequest) -> String {
        ([request.executable] + request.arguments).joined(separator: " ")
    }
}

public enum AuditStatus: String, Codable, Equatable, Sendable {
    case success
    case failure
}

public struct AuditEntry: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let tool: String
    public let workspaceID: UUID?
    public let target: String?
    public let status: AuditStatus
    public let durationMilliseconds: Int
    public let summary: String

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        tool: String,
        workspaceID: UUID?,
        target: String?,
        status: AuditStatus,
        durationMilliseconds: Int,
        summary: String
    ) {
        self.id = id
        self.timestamp = timestamp
        self.tool = tool
        self.workspaceID = workspaceID
        self.target = target
        self.status = status
        self.durationMilliseconds = durationMilliseconds
        self.summary = summary
    }
}

public struct SecretRedactor: Sendable {
    public init() {}

    public func redact(_ text: String) -> String {
        var result = text
        let patterns = [
            #"(?i)(authorization\s*:\s*bearer\s+)([^\s]+)"#,
            #"(?i)((?:api[_-]?key|openai_api_key|password|token)\s*[=:]\s*)([^\s]+)"#,
            #"\bsk-[A-Za-z0-9_-]{8,}\b"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let template = pattern.hasPrefix("\\bsk-") ? "[REDACTED]" : "$1[REDACTED]"
            result = regex.stringByReplacingMatches(in: result, range: range, withTemplate: template)
        }
        return result
    }
}

public actor AuditLogger {
    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let redactor: SecretRedactor

    public init(paths: BridgePaths, redactor: SecretRedactor = SecretRedactor()) {
        self.fileURL = paths.logsDirectory.appendingPathComponent("audit.log")
        self.encoder = JSONEncoder()
        self.decoder = JSONDecoder()
        self.redactor = redactor
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
        try? paths.ensureDirectories()
    }

    public func record(_ entry: AuditEntry) throws {
        let sanitized = AuditEntry(
            id: entry.id,
            timestamp: entry.timestamp,
            tool: entry.tool,
            workspaceID: entry.workspaceID,
            target: entry.target,
            status: entry.status,
            durationMilliseconds: entry.durationMilliseconds,
            summary: redactor.redact(entry.summary)
        )
        var data = try encoder.encode(sanitized)
        data.append(0x0A)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
            return
        }
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    public func entries() throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try decoder.decode(AuditEntry.self, from: Data(line.utf8))
        }
    }
}
