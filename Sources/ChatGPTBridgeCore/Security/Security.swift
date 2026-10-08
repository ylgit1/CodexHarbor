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
            // Even a seemingly read-only shell script can use expansion,
            // substitution or redirection to access files outside Allowed Roots.
            // Shell interpreters must always require an explicit approval.
            return CommandAssessment(risk: .review, reason: "Shell 解释器或脚本文件可执行任意逻辑，需要用户确认")
        }

        if executable == "git" {
            guard let subcommand = arguments.first else {
                return CommandAssessment(risk: .safe, reason: "只读 Git 信息查询")
            }
            // Git options such as -C/--git-dir and external diff drivers
            // can escape the selected workspace or invoke other programs.
            // Allow only the no-argument status query without review.
            if subcommand == "status", arguments.count == 1 {
                return CommandAssessment(risk: .safe, reason: "当前工作区 Git 状态查询")
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

        // The process cwd is not a sandbox: cat/find/grep and even env can
        // disclose files and credentials outside the user's approved roots.
        // File inspection should go through PathValidator-backed MCP tools.
        let safeExecutables: Set<String> = [
            "pwd", "date", "echo", "printf", "which", "whereis"
        ]
        if safeExecutables.contains(executable) {
            return CommandAssessment(risk: .safe, reason: "只读系统命令")
        }

        // Builds and tests execute arbitrary project code and build plugins.
        // They are never safe merely because their names say "test".

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

/// Trusted development is a deliberate opt-in for selected Allowed Roots.
/// It removes repeat prompts for standard project workflows, not for arbitrary
/// shell commands. Running trusted project code is not an OS sandbox.
public struct TrustedDevelopmentPolicy: Sendable {
    private let configuration: BridgeConfiguration
    private let validator = PathValidator()

    public init(configuration: BridgeConfiguration) {
        self.configuration = configuration
    }

    public func trusts(_ workspace: BridgeWorkspace) -> Bool {
        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        return configuration.trustedDevelopmentRoots.contains { trusted in
            let trustedURL = URL(fileURLWithPath: trusted, isDirectory: true)
            return configuration.allowedRoots.contains {
                AllowedRootsManager.canonicalURL(URL(fileURLWithPath: $0, isDirectory: true)) ==
                    AllowedRootsManager.canonicalURL(trustedURL)
            } && AllowedRootsManager.isSameOrDescendant(root, of: trustedURL)
        }
    }

    public func autoApprovesModification(in workspace: BridgeWorkspace) -> Bool {
        trusts(workspace) && configuration.modificationPermission != .deny
    }

    public func autoApprovesCommand(_ request: CommandRequest, in workspace: BridgeWorkspace) -> Bool {
        guard trusts(workspace), configuration.shellPermission != .deny else { return false }
        guard CommandPolicy().assess(request).risk != .blocked else { return false }

        // No auto approval of absolute executable paths outside the default
        // toolchain, shell -c, flags that redirect to another directory, or
        // arbitrary networking and destructive operations.
        guard !request.executable.hasPrefix("/") || request.executable == "/bin/zsh" else { return false }
        let executable = URL(fileURLWithPath: request.executable).lastPathComponent.lowercased()
        let args = request.arguments
        guard args.allSatisfy({ argument in
            !argument.hasPrefix("/") &&
            !argument.contains("../") &&
            argument != ".." &&
            !argument.contains("\n") &&
            !argument.contains("\r")
        }) else { return false }

        switch executable {
        case "swift":
            return args.first.map { ["build", "test"].contains($0) } == true &&
                !args.contains("--package-path") && !args.contains("--scratch-path")
        case "xcodebuild":
            return args.contains("build") || args.contains("test")
        case "npm":
            return args.first == "test" ||
                (args.first == "run" && args.count >= 2 && ["build", "test", "package"].contains(args[1]))
        case "mvn", "mvnw":
            return args.contains(where: { ["test", "compile", "package", "verify"].contains($0) })
        case "gradle", "gradlew":
            return args.contains(where: { ["test", "build", "assemble"].contains($0) })
        case "cargo":
            return args.first.map { ["build", "test", "check"].contains($0) } == true
        case "go":
            return args.first.map { ["build", "test"].contains($0) } == true
        case "git":
            guard let operation = args.first else { return false }
            if operation == "push" {
                return configuration.gitPushPermission == .allow
            }
            return ["status", "diff", "log", "show", "add", "commit"].contains(operation)
        case "python", "python3":
            if args.count >= 2 && args[0] == "-m" {
                return ["pytest", "compileall", "unittest"].contains(args[1])
            }
            return isTrustedScript(args.first, suffix: "py", workspace: workspace)
        case "sh", "bash", "zsh":
            // Only a checked-in relative script file, never -c or stdin.
            return isTrustedScript(args.first, suffix: "sh", workspace: workspace)
        default:
            // Recognize directly invoked project-local packaging scripts as
            // well as shells that receive a relative script path.
            if request.executable.hasPrefix("./") {
                return isTrustedScript(request.executable, suffix: "sh", workspace: workspace)
            }
            return false
        }
    }

    private func isTrustedScript(_ path: String?, suffix ext: String, workspace: BridgeWorkspace) -> Bool {
        guard let path, !path.hasPrefix("-"), !path.hasPrefix("/"),
              !path.contains(".."), !path.contains("\\") else { return false }
        guard let file = try? validator.resolve(workspace: workspace, relativePath: path),
              file.pathExtension.lowercased() == ext,
              (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
            return false
        }
        return true
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
            #"(?i)((?:https?://[^\s/]+)?/mcp/)([a-f0-9]{32,}|[A-Za-z0-9_-]{40,})"#,
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
    private struct FileFingerprint: Equatable {
        let size: UInt64
        let modifiedAt: Date?
        let fileNumber: UInt64?
    }

    private let fileURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let redactor: SecretRedactor
    private var cachedLatestFingerprint: FileFingerprint?
    private var cachedLatestEntry: AuditEntry?

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
        BridgeLogRotator.rotateIfNeeded(fileURL)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: fileURL, options: .atomic)
        } else {
            let handle = try FileHandle(forWritingTo: fileURL)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
        }
        // The Agent and tool router may use different AuditLogger actors.
        // Invalidate our own snapshot after a successful append.
        cachedLatestFingerprint = nil
    }

    public func entries() throws -> [AuditEntry] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let text = try String(contentsOf: fileURL, encoding: .utf8)
        return try text.split(separator: "\n").map { line in
            try decoder.decode(AuditEntry.self, from: Data(line.utf8))
        }
    }

    /// Dashboard and Agent polling must not decode the entire rotated audit
    /// log on every refresh. Read only a bounded suffix and ignore any partial
    /// first line when seeking into the middle of a record.
    public func recentEntries(limit: Int = 12) throws -> [AuditEntry] {
        guard limit > 0, FileManager.default.fileExists(atPath: fileURL.path) else { return [] }
        let handle = try FileHandle(forReadingFrom: fileURL)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        let maximumBytes = 512 * 1_024
        let offset = size > UInt64(maximumBytes) ? size - UInt64(maximumBytes) : 0
        try handle.seek(toOffset: offset)
        let data = try handle.read(upToCount: maximumBytes) ?? Data()
        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: true)
        if offset > 0 && !lines.isEmpty { lines.removeFirst() }
        // A writer can still be appending the last JSON line. Skip incomplete
        // records and return the requested number of *valid* recent entries.
        var entries: [AuditEntry] = []
        for line in lines.reversed() {
            if let entry = try? decoder.decode(AuditEntry.self, from: Data(line.utf8)) {
                entries.append(entry)
                if entries.count == min(limit, 1_000) { break }
            }
        }
        return Array(entries.reversed())
    }

    private func currentFingerprint() -> FileFingerprint? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: fileURL.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value else { return nil }
        return FileFingerprint(
            size: size,
            modifiedAt: attributes[.modificationDate] as? Date,
            fileNumber: (attributes[.systemFileNumber] as? NSNumber)?.uint64Value
        )
    }

    public func latestEntry() throws -> AuditEntry? {
        // A cheap stat avoids rereading and decoding an unchanged audit log.
        // Size + modification time + inode also detects most rotations and replacements.
        let fingerprint = currentFingerprint()
        if let fingerprint, fingerprint == cachedLatestFingerprint {
            return cachedLatestEntry
        }
        let latest = try recentEntries(limit: 1).last
        cachedLatestEntry = latest
        cachedLatestFingerprint = fingerprint
        return latest
    }
}
