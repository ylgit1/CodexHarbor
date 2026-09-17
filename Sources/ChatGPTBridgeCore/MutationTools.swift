import Foundation

public struct EditFileResult: Codable, Equatable, Sendable {
    public let path: String
    public let replacedOccurrences: Int
    public let bytesWritten: Int
}

public struct WriteFileResult: Codable, Equatable, Sendable {
    public let path: String
    public let bytesWritten: Int
    public let created: Bool
}

public struct ShellResult: Codable, Equatable, Sendable {
    public let executable: String
    public let arguments: [String]
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let durationMilliseconds: Int
    public let truncated: Bool
}

public struct EditFileTool: Sendable {
    private let workspaceManager: WorkspaceManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let validator: PathValidator

    public init(
        workspaceManager: WorkspaceManager,
        permissionEngine: PermissionEngine,
        auditLogger: AuditLogger,
        validator: PathValidator = PathValidator()
    ) {
        self.workspaceManager = workspaceManager
        self.permissionEngine = permissionEngine
        self.auditLogger = auditLogger
        self.validator = validator
    }

    public func execute(
        workspaceID: UUID,
        path: String,
        oldText: String,
        newText: String,
        approvalGranted: Bool = false
    ) async throws -> EditFileResult {
        let startedAt = Date()
        do {
            try permissionEngine.authorizeModification(operation: "edit \(path)", approvalGranted: approvalGranted)
            guard !oldText.isEmpty else { throw BridgeError.editTargetNotUnique(0) }
            let workspace = try await workspaceManager.workspace(id: workspaceID)
            let fileURL = try validator.resolve(workspace: workspace, relativePath: path)
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey])
            guard values.isRegularFile == true else { throw BridgeError.invalidPath(fileURL.path) }
            let original = try String(contentsOf: fileURL, encoding: .utf8)
            let count = original.components(separatedBy: oldText).count - 1
            guard count == 1 else { throw BridgeError.editTargetNotUnique(count) }
            guard let range = original.range(of: oldText) else { throw BridgeError.editTargetNotUnique(0) }
            var updated = original
            updated.replaceSubrange(range, with: newText)
            try Self.atomicReplace(Data(updated.utf8), at: fileURL)
            let result = EditFileResult(path: path, replacedOccurrences: 1, bytesWritten: updated.utf8.count)
            try await record(status: .success, workspaceID: workspaceID, target: path, startedAt: startedAt, summary: "精确替换 1 处")
            return result
        } catch {
            try? await record(status: .failure, workspaceID: workspaceID, target: path, startedAt: startedAt, summary: error.localizedDescription)
            throw error
        }
    }

    private func record(status: AuditStatus, workspaceID: UUID, target: String, startedAt: Date, summary: String) async throws {
        try await auditLogger.record(AuditEntry(
            tool: "edit",
            workspaceID: workspaceID,
            target: target,
            status: status,
            durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
            summary: summary
        ))
    }

    static func atomicReplace(_ data: Data, at targetURL: URL) throws {
        let directory = targetURL.deletingLastPathComponent()
        let temporaryURL = directory.appendingPathComponent(".harbor-write-\(UUID().uuidString)")
        do {
            try data.write(to: temporaryURL, options: .atomic)
            _ = try FileManager.default.replaceItemAt(targetURL, withItemAt: temporaryURL)
        } catch {
            try? FileManager.default.removeItem(at: temporaryURL)
            throw BridgeError.writeFailed(error.localizedDescription)
        }
    }
}

public struct WriteFileTool: Sendable {
    private let workspaceManager: WorkspaceManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let validator: PathValidator

    public init(
        workspaceManager: WorkspaceManager,
        permissionEngine: PermissionEngine,
        auditLogger: AuditLogger,
        validator: PathValidator = PathValidator()
    ) {
        self.workspaceManager = workspaceManager
        self.permissionEngine = permissionEngine
        self.auditLogger = auditLogger
        self.validator = validator
    }

    public func execute(
        workspaceID: UUID,
        path: String,
        content: String,
        overwrite: Bool = false,
        approvalGranted: Bool = false
    ) async throws -> WriteFileResult {
        let startedAt = Date()
        do {
            try permissionEngine.authorizeModification(operation: "write \(path)", approvalGranted: approvalGranted)
            let workspace = try await workspaceManager.workspace(id: workspaceID)
            let fileURL = try validator.resolve(workspace: workspace, relativePath: path, mustExist: false)
            let existed = FileManager.default.fileExists(atPath: fileURL.path)
            if existed && !overwrite { throw BridgeError.fileAlreadyExists(path) }
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            let data = Data(content.utf8)
            if existed {
                try EditFileTool.atomicReplace(data, at: fileURL)
            } else {
                do { try data.write(to: fileURL, options: .atomic) }
                catch { throw BridgeError.writeFailed(error.localizedDescription) }
            }
            let result = WriteFileResult(path: path, bytesWritten: data.count, created: !existed)
            try await auditLogger.record(AuditEntry(
                tool: "write",
                workspaceID: workspaceID,
                target: path,
                status: .success,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                summary: existed ? "覆盖文件" : "创建文件"
            ))
            return result
        } catch {
            try? await auditLogger.record(AuditEntry(
                tool: "write",
                workspaceID: workspaceID,
                target: path,
                status: .failure,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                summary: error.localizedDescription
            ))
            throw error
        }
    }
}

public struct ShellTool: Sendable {
    public static let maximumTimeoutSeconds = 300
    public static let maximumStdoutBytes = 2 * 1_024 * 1_024
    public static let maximumStderrBytes = 1 * 1_024 * 1_024

    private let workspaceManager: WorkspaceManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let validator: PathValidator
    private let policy: CommandPolicy
    private let redactor: SecretRedactor

    public init(
        workspaceManager: WorkspaceManager,
        permissionEngine: PermissionEngine,
        auditLogger: AuditLogger,
        validator: PathValidator = PathValidator(),
        policy: CommandPolicy = CommandPolicy(),
        redactor: SecretRedactor = SecretRedactor()
    ) {
        self.workspaceManager = workspaceManager
        self.permissionEngine = permissionEngine
        self.auditLogger = auditLogger
        self.validator = validator
        self.policy = policy
        self.redactor = redactor
    }

    public func execute(
        workspaceID: UUID,
        request: CommandRequest,
        approvalGranted: Bool = false
    ) async throws -> ShellResult {
        let startedAt = Date()
        do {
            let assessment = policy.assess(request)
            try permissionEngine.authorizeCommand(assessment, request: request, approvalGranted: approvalGranted)
            let workspace = try await workspaceManager.workspace(id: workspaceID)
            let cwd = try validator.resolve(workspace: workspace, relativePath: request.workingDirectory)
            guard try cwd.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
                throw BridgeError.invalidPath(cwd.path)
            }
            let timeout = max(1, min(request.timeoutSeconds, Self.maximumTimeoutSeconds))
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [request.executable] + request.arguments
            process.currentDirectoryURL = cwd

            let temp = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-shell-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: temp) }
            let stdoutURL = temp.appendingPathComponent("stdout")
            let stderrURL = temp.appendingPathComponent("stderr")
            FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
            FileManager.default.createFile(atPath: stderrURL.path, contents: nil)
            let out = try FileHandle(forWritingTo: stdoutURL)
            let err = try FileHandle(forWritingTo: stderrURL)
            process.standardOutput = out
            process.standardError = err

            try process.run()
            let deadline = Date().addingTimeInterval(TimeInterval(timeout))
            while process.isRunning && Date() < deadline {
                try await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning {
                process.terminate()
                try await Task.sleep(for: .milliseconds(200))
                if process.isRunning { process.interrupt() }
                try? out.close(); try? err.close()
                throw BridgeError.commandTimedOut(timeout)
            }
            try out.close(); try err.close()
            let stdoutData = try Data(contentsOf: stdoutURL)
            let stderrData = try Data(contentsOf: stderrURL)
            let stdout = Self.text(stdoutData, max: Self.maximumStdoutBytes)
            let stderr = Self.text(stderrData, max: Self.maximumStderrBytes)
            let duration = Int(Date().timeIntervalSince(startedAt) * 1_000)
            let result = ShellResult(
                executable: request.executable,
                arguments: request.arguments,
                exitCode: process.terminationStatus,
                stdout: redactor.redact(stdout),
                stderr: redactor.redact(stderr),
                durationMilliseconds: duration,
                truncated: stdoutData.count > Self.maximumStdoutBytes || stderrData.count > Self.maximumStderrBytes
            )
            try await auditLogger.record(AuditEntry(
                tool: "bash",
                workspaceID: workspaceID,
                target: request.workingDirectory,
                status: process.terminationStatus == 0 ? .success : .failure,
                durationMilliseconds: duration,
                summary: redactor.redact(([request.executable] + request.arguments).joined(separator: " "))
            ))
            return result
        } catch {
            try? await auditLogger.record(AuditEntry(
                tool: "bash",
                workspaceID: workspaceID,
                target: request.workingDirectory,
                status: .failure,
                durationMilliseconds: Int(Date().timeIntervalSince(startedAt) * 1_000),
                summary: redactor.redact(error.localizedDescription)
            ))
            throw error
        }
    }

    private static func text(_ data: Data, max: Int) -> String {
        var value = String(decoding: data.prefix(max), as: UTF8.self)
        if data.count > max { value += "\n[output truncated]" }
        return value
    }
}
