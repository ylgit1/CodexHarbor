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

public struct PatchPermission: Equatable, Sendable {
    public let operation: String
    public let approvalGranted: Bool

    public init(operation: String, approvalGranted: Bool = false) {
        self.operation = operation
        self.approvalGranted = approvalGranted
    }
}

public struct CommandPermission: Equatable, Sendable {
    public let assessment: CommandAssessment
    public let request: CommandRequest
    public let approvalGranted: Bool

    public init(
        assessment: CommandAssessment,
        request: CommandRequest,
        approvalGranted: Bool = false
    ) {
        self.assessment = assessment
        self.request = request
        self.approvalGranted = approvalGranted
    }
}

public struct CommandPolicy: Sendable {
    public init() {}

    public func assess(_ request: CommandRequest) -> CommandAssessment {
        let executable = URL(fileURLWithPath: request.executable).lastPathComponent.lowercased()
        let arguments = request.arguments.map { $0.lowercased() }
        let joined = arguments.joined(separator: " ")

        if ["sudo", "su"].contains(executable) {
            return CommandAssessment(risk: .blocked, reason: "不允许通过 ChatGPT 提权执行系统命令")
        }

        if executable == "rm" {
            let flags = arguments.filter { $0.hasPrefix("-") }.joined()
            if flags.contains("r") && flags.contains("f") {
                return CommandAssessment(risk: .blocked, reason: "禁止递归强制删除")
            }
        }

        if ["rm", "rmdir", "mv", "cp", "chmod", "chown", "kill", "pkill", "killall", "dd", "mkfs", "diskutil"].contains(executable) {
            return CommandAssessment(risk: .review, reason: "命令可能删除、覆盖、修改权限或影响系统进程")
        }

        if ["sh", "bash", "zsh", "fish"].contains(executable) {
            let script = joined
            let blockedMarkers = ["rm -rf", "rm -fr", "sudo "]
            let downloadsIntoShell = (script.contains("curl ") || script.contains("wget "))
                && (script.contains("| sh") || script.contains("| bash") || script.contains("| zsh"))
            if blockedMarkers.contains(where: script.contains) || downloadsIntoShell {
                return CommandAssessment(risk: .blocked, reason: "Shell 命令包含禁止的提权、破坏性删除或下载执行操作")
            }
            let riskyMarkers = [
                "rm ", "rm -", "sudo ", "curl ", "wget ", "| sh", "| bash", "| zsh",
                "git reset", "git clean", "chmod ", "chown ", "kill ", "pkill ", "mv ", "cp ",
                ">", ">>", "&&", "||", ";"
            ]
            if riskyMarkers.contains(where: script.contains) {
                return CommandAssessment(risk: .review, reason: "Shell 脚本包含潜在写入、下载执行或复合命令")
            }
            if arguments.first == "-c",
               arguments.count == 2 {
                let command = arguments[1].trimmingCharacters(in: .whitespacesAndNewlines)
                let safePrefixes = ["echo ", "printf ", "pwd", "date", "ls ", "ls", "cat ", "head ", "tail ", "wc ", "stat ", "file ", "which "]
                if safePrefixes.contains(where: command.hasPrefix) {
                    return CommandAssessment(risk: .safe, reason: "Shell 中的简单只读命令")
                }
            }
            return CommandAssessment(risk: .review, reason: "Shell 解释器或脚本文件可执行任意逻辑，需要用户确认")
        }

        if executable == "git" {
            guard let subcommand = arguments.first else {
                return CommandAssessment(risk: .safe, reason: "只读 Git 信息查询")
            }
            let safeGit = ["status", "branch", "log", "diff", "show", "rev-parse", "remote", "tag"]
            if safeGit.contains(subcommand) {
                return CommandAssessment(risk: .safe, reason: "只读 Git 操作")
            }
            let blockedGit = ["reset", "clean"]
            if blockedGit.contains(subcommand) {
                return CommandAssessment(risk: .review, reason: "Git 操作可能丢弃本地修改或未跟踪文件")
            }
            if subcommand == "push" {
                return CommandAssessment(risk: .review, reason: "Git push 会修改远端仓库")
            }
            return CommandAssessment(risk: .review, reason: "Git 命令可能修改仓库状态")
        }

        if ["curl", "wget", "scp", "sftp", "ssh"].contains(executable) {
            return CommandAssessment(risk: .review, reason: "网络命令可能发送数据、下载内容或执行远端操作")
        }

        let safeExecutables: Set<String> = [
            "pwd", "ls", "find", "grep", "rg", "cat", "head", "tail", "wc", "stat",
            "file", "which", "whereis", "date", "echo", "printf", "env", "printenv"
        ]
        if safeExecutables.contains(executable) {
            return CommandAssessment(risk: .safe, reason: "只读系统命令")
        }

        if executable == "swift",
           let subcommand = arguments.first,
           ["build", "test"].contains(subcommand) {
            return CommandAssessment(risk: .safe, reason: "Swift 构建或测试命令")
        }

        let codeExecutionTools: Set<String> = [
            "swift", "swiftc", "xcodebuild", "python", "python3", "node", "npm", "npx",
            "java", "javac", "mvn", "mvnw", "gradle", "gradlew", "go", "cargo", "make",
            "ruby", "perl", "php"
        ]
        if codeExecutionTools.contains(executable) {
            return CommandAssessment(risk: .review, reason: "该工具可能执行项目代码、脚本或构建钩子，需要用户确认")
        }

        return CommandAssessment(risk: .review, reason: "未识别的可执行程序需要用户确认")
    }
}

public struct PermissionEngine: Sendable {
    private let configuration: BridgeConfiguration

    public init(configuration: BridgeConfiguration) {
        self.configuration = configuration
    }

    public func authorizeModification(operation: String, approvalGranted: Bool = false) throws {
        try authorizePatch(PatchPermission(operation: operation, approvalGranted: approvalGranted))
    }

    public func authorizePatch(_ permission: PatchPermission) throws {
        switch configuration.modificationPermission {
        case .allow:
            return
        case .ask:
            guard permission.approvalGranted else { throw BridgeError.approvalRequired(permission.operation) }
        case .deny:
            throw BridgeError.permissionDenied(permission.operation)
        }
    }

    public func authorizeCommand(
        _ assessment: CommandAssessment,
        request: CommandRequest,
        approvalGranted: Bool = false
    ) throws {
        try authorizeCommand(CommandPermission(
            assessment: assessment,
            request: request,
            approvalGranted: approvalGranted
        ))
    }

    public func authorizeCommand(_ permission: CommandPermission) throws {
        let assessment = permission.assessment
        let request = permission.request
        let approvalGranted = permission.approvalGranted
        let executable = URL(fileURLWithPath: request.executable).lastPathComponent.lowercased()
        let firstArgument = request.arguments.first?.lowercased()

        if assessment.risk == .blocked {
            throw BridgeError.commandBlocked(assessment.reason)
        }

        if configuration.shellPermission == .allow {
            if executable == "git", firstArgument == "push", configuration.gitPushPermission != .allow {
                switch configuration.gitPushPermission {
                case .allow:
                    return
                case .ask:
                    guard approvalGranted else { throw BridgeError.approvalRequired(Self.commandSummary(request)) }
                    return
                case .deny:
                    throw BridgeError.permissionDenied(Self.commandSummary(request))
                }
            }
            return
        }

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
        case .allow:
            return
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
        BridgeLogRotator.rotateIfNeeded(fileURL)
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
        BridgeLogRotator.rotateIfNeeded(fileURL)
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
