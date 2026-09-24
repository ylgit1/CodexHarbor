import Foundation

public enum CommandSessionState: String, Codable, Equatable, Sendable {
    case running
    case completed
    case failed
    case cancelled
    case timedOut
}

public struct CommandSessionStarted: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let state: CommandSessionState
    public let processIdentifier: Int32
    public let startedAt: Date
}

public struct CommandSessionStatus: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let state: CommandSessionState
    public let processIdentifier: Int32?
    public let exitCode: Int32?
    public let startedAt: Date
    public let finishedAt: Date?
    public let durationMilliseconds: Int
    public let errors: [BuildError]
}

public struct CommandSessionOutput: Codable, Equatable, Sendable {
    public let commandID: UUID
    public let state: CommandSessionState
    public let stdout: String
    public let stderr: String
    public let stdoutOffset: Int
    public let stderrOffset: Int
    public let nextStdoutOffset: Int
    public let nextStderrOffset: Int
    public let stdoutHasMore: Bool
    public let stderrHasMore: Bool
}

public actor CommandSessionManager {
    public static let maximumOutputChunkBytes = 256 * 1_024
    public static let maximumSessionCount = 20
    public static let completedRetention: TimeInterval = 30 * 60

    private final class Session {
        let id: UUID
        let workspaceID: UUID
        let request: CommandRequest
        let auditTool: String
        let process: Process
        let stdoutURL: URL
        let stderrURL: URL
        let stdoutHandle: FileHandle
        let stderrHandle: FileHandle
        let temporaryDirectory: URL
        let startedAt: Date
        var state: CommandSessionState = .running
        var exitCode: Int32?
        var finishedAt: Date?
        var errors: [BuildError] = []
        var auditRecorded = false

        init(
            id: UUID,
            workspaceID: UUID,
            request: CommandRequest,
            auditTool: String,
            process: Process,
            stdoutURL: URL,
            stderrURL: URL,
            stdoutHandle: FileHandle,
            stderrHandle: FileHandle,
            temporaryDirectory: URL,
            startedAt: Date
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.request = request
            self.auditTool = auditTool
            self.process = process
            self.stdoutURL = stdoutURL
            self.stderrURL = stderrURL
            self.stdoutHandle = stdoutHandle
            self.stderrHandle = stderrHandle
            self.temporaryDirectory = temporaryDirectory
            self.startedAt = startedAt
        }
    }

    private let workspaceManager: WorkspaceManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let validator: PathValidator
    private let policy: CommandPolicy
    private let redactor: SecretRedactor
    private let fileManager: FileManager
    private var sessions: [UUID: Session] = [:]

    public init(
        workspaceManager: WorkspaceManager,
        permissionEngine: PermissionEngine,
        auditLogger: AuditLogger,
        validator: PathValidator = PathValidator(),
        policy: CommandPolicy = CommandPolicy(),
        redactor: SecretRedactor = SecretRedactor(),
        fileManager: FileManager = .default
    ) {
        self.workspaceManager = workspaceManager
        self.permissionEngine = permissionEngine
        self.auditLogger = auditLogger
        self.validator = validator
        self.policy = policy
        self.redactor = redactor
        self.fileManager = fileManager
    }

    public func start(
        workspaceID: UUID,
        executable: String,
        arguments: [String] = [],
        workingDirectory: String = ".",
        timeoutSeconds: Int = ShellTool.maximumTimeoutSeconds,
        approvalGranted: Bool = false,
        auditTool: String = "start_command"
    ) async throws -> CommandSessionStarted {
        pruneExpiredSessions()

        let request = CommandRequest(
            executable: executable,
            arguments: arguments,
            workingDirectory: workingDirectory,
            timeoutSeconds: timeoutSeconds
        )
        let assessment = policy.assess(request)
        try permissionEngine.authorizeCommand(
            assessment,
            request: request,
            approvalGranted: approvalGranted
        )

        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let cwd = try validator.resolve(
            workspace: workspace,
            relativePath: workingDirectory.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "."
                : workingDirectory
        )
        guard try cwd.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else {
            throw BridgeError.invalidPath(cwd.path)
        }

        let timeout = max(1, min(timeoutSeconds, ShellTool.maximumTimeoutSeconds))
        let id = UUID()
        let temporaryDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("harbor-command-session-\(id.uuidString)", isDirectory: true)
        try fileManager.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        let stdoutURL = temporaryDirectory.appendingPathComponent("stdout")
        let stderrURL = temporaryDirectory.appendingPathComponent("stderr")
        fileManager.createFile(atPath: stdoutURL.path, contents: nil)
        fileManager.createFile(atPath: stderrURL.path, contents: nil)

        do {
            let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
            let stderrHandle = try FileHandle(forWritingTo: stderrURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = [executable] + arguments
            process.currentDirectoryURL = cwd
            process.standardOutput = stdoutHandle
            process.standardError = stderrHandle

            let startedAt = Date()
            try process.run()

            let session = Session(
                id: id,
                workspaceID: workspaceID,
                request: CommandRequest(
                    executable: executable,
                    arguments: arguments,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: timeout
                ),
                auditTool: auditTool,
                process: process,
                stdoutURL: stdoutURL,
                stderrURL: stderrURL,
                stdoutHandle: stdoutHandle,
                stderrHandle: stderrHandle,
                temporaryDirectory: temporaryDirectory,
                startedAt: startedAt
            )
            sessions[id] = session
            enforceSessionLimit()

            Task { [weak self] in
                await self?.watch(commandID: id, timeoutSeconds: timeout)
            }

            return CommandSessionStarted(
                commandID: id,
                state: .running,
                processIdentifier: process.processIdentifier,
                startedAt: startedAt
            )
        } catch {
            try? fileManager.removeItem(at: temporaryDirectory)
            throw error
        }
    }

    public func status(commandID: UUID) async throws -> CommandSessionStatus {
        guard let session = sessions[commandID] else {
            throw BridgeError.commandSessionNotFound(commandID)
        }
        if session.state == .running, !session.process.isRunning {
            await finalizeNaturally(session)
        }
        return statusValue(for: session)
    }

    public func output(
        commandID: UUID,
        stdoutOffset: Int = 0,
        stderrOffset: Int = 0,
        limitBytes: Int = maximumOutputChunkBytes
    ) async throws -> CommandSessionOutput {
        guard let session = sessions[commandID] else {
            throw BridgeError.commandSessionNotFound(commandID)
        }
        if session.state == .running, !session.process.isRunning {
            await finalizeNaturally(session)
        }

        let limit = max(1, min(limitBytes, Self.maximumOutputChunkBytes))
        let stdoutChunk = try readChunk(
            at: session.stdoutURL,
            offset: max(0, stdoutOffset),
            limit: limit
        )
        let stderrChunk = try readChunk(
            at: session.stderrURL,
            offset: max(0, stderrOffset),
            limit: limit
        )

        return CommandSessionOutput(
            commandID: commandID,
            state: session.state,
            stdout: redactor.redact(String(decoding: stdoutChunk.data, as: UTF8.self)),
            stderr: redactor.redact(String(decoding: stderrChunk.data, as: UTF8.self)),
            stdoutOffset: max(0, stdoutOffset),
            stderrOffset: max(0, stderrOffset),
            nextStdoutOffset: stdoutChunk.nextOffset,
            nextStderrOffset: stderrChunk.nextOffset,
            stdoutHasMore: stdoutChunk.hasMore,
            stderrHasMore: stderrChunk.hasMore
        )
    }

    public func cancel(commandID: UUID) async throws -> CommandSessionStatus {
        guard let session = sessions[commandID] else {
            throw BridgeError.commandSessionNotFound(commandID)
        }
        guard session.state == .running else {
            return statusValue(for: session)
        }

        session.state = .cancelled
        if session.process.isRunning {
            session.process.terminate()
            try? await Task.sleep(for: .milliseconds(250))
            if session.process.isRunning {
                session.process.interrupt()
            }
        }
        await waitForExit(session, maximumWaitMilliseconds: 1_000)
        await finalize(session, state: .cancelled)
        return statusValue(for: session)
    }

    private func watch(commandID: UUID, timeoutSeconds: Int) async {
        guard let session = sessions[commandID] else { return }
        let deadline = session.startedAt.addingTimeInterval(TimeInterval(timeoutSeconds))

        while session.state == .running && session.process.isRunning {
            if Date() >= deadline {
                session.state = .timedOut
                session.process.terminate()
                try? await Task.sleep(for: .milliseconds(250))
                if session.process.isRunning {
                    session.process.interrupt()
                }
                await waitForExit(session, maximumWaitMilliseconds: 1_000)
                await finalize(session, state: .timedOut)
                return
            }
            try? await Task.sleep(for: .milliseconds(150))
        }

        guard session.state == .running else { return }
        await finalizeNaturally(session)
    }

    private func finalizeNaturally(_ session: Session) async {
        let state: CommandSessionState = session.process.terminationStatus == 0 ? .completed : .failed
        await finalize(session, state: state)
    }

    private func finalize(_ session: Session, state: CommandSessionState) async {
        guard session.finishedAt == nil else { return }
        try? session.stdoutHandle.close()
        try? session.stderrHandle.close()
        session.state = state
        session.finishedAt = Date()
        if !session.process.isRunning {
            session.exitCode = session.process.terminationStatus
        }

        let combined = (
            (try? String(contentsOf: session.stdoutURL, encoding: .utf8)) ?? ""
        ) + "\n" + (
            (try? String(contentsOf: session.stderrURL, encoding: .utf8)) ?? ""
        )
        let capped = String(combined.prefix(
            ShellTool.maximumStdoutBytes + ShellTool.maximumStderrBytes
        ))
        session.errors = BuildErrorParser().parse(redactor.redact(capped))

        guard !session.auditRecorded else { return }
        session.auditRecorded = true
        let duration = max(0, Int((session.finishedAt ?? Date()).timeIntervalSince(session.startedAt) * 1_000))
        let summary = redactor.redact(
            ([session.request.executable] + session.request.arguments).joined(separator: " ")
        )
        try? await auditLogger.record(AuditEntry(
            tool: session.auditTool,
            workspaceID: session.workspaceID,
            target: session.request.workingDirectory,
            status: state == .completed ? .success : .failure,
            durationMilliseconds: duration,
            summary: summary
        ))
    }

    private func waitForExit(_ session: Session, maximumWaitMilliseconds: Int) async {
        var remaining = maximumWaitMilliseconds
        while session.process.isRunning && remaining > 0 {
            try? await Task.sleep(for: .milliseconds(50))
            remaining -= 50
        }
    }

    private func statusValue(for session: Session) -> CommandSessionStatus {
        let finishedAt = session.finishedAt
        let end = finishedAt ?? Date()
        return CommandSessionStatus(
            commandID: session.id,
            state: session.state,
            processIdentifier: session.process.isRunning ? session.process.processIdentifier : nil,
            exitCode: session.exitCode,
            startedAt: session.startedAt,
            finishedAt: finishedAt,
            durationMilliseconds: max(0, Int(end.timeIntervalSince(session.startedAt) * 1_000)),
            errors: session.errors
        )
    }

    private func readChunk(
        at url: URL,
        offset: Int,
        limit: Int
    ) throws -> (data: Data, nextOffset: Int, hasMore: Bool) {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
        let safeOffset = min(max(0, offset), size)
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        try handle.seek(toOffset: UInt64(safeOffset))
        let data = try handle.read(upToCount: limit) ?? Data()
        let next = safeOffset + data.count
        return (data, next, next < size)
    }

    private func pruneExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-Self.completedRetention)
        let expired = sessions.values.filter { session in
            guard let finishedAt = session.finishedAt else { return false }
            return finishedAt < cutoff
        }
        for session in expired {
            sessions[session.id] = nil
            try? fileManager.removeItem(at: session.temporaryDirectory)
        }
    }

    private func enforceSessionLimit() {
        guard sessions.count > Self.maximumSessionCount else { return }
        let removable = sessions.values
            .filter { $0.state != .running }
            .sorted { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
        for session in removable.prefix(max(0, sessions.count - Self.maximumSessionCount)) {
            sessions[session.id] = nil
            try? fileManager.removeItem(at: session.temporaryDirectory)
        }
    }
}
