import Foundation

public enum WorkflowSessionState: String, Codable, Equatable, Sendable {
    case planned
    case running
    case completed
    case failed
    case cancelled
    case timedOut
    case unsupported
}

public enum WorkflowStepState: String, Codable, Equatable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
    case timedOut
}

public struct WorkflowSessionStarted: Codable, Equatable, Sendable {
    public let workflowID: UUID
    public let kind: ProjectWorkflowKind
    public let state: WorkflowSessionState
    public let message: String
    public let startedAt: Date
}

public struct WorkflowStepStatus: Codable, Equatable, Sendable {
    public let index: Int
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let state: WorkflowStepState
    public let commandID: UUID?
    public let exitCode: Int32?
    public let errors: [BuildError]
}

public struct WorkflowSessionStatus: Codable, Equatable, Sendable {
    public let workflowID: UUID
    public let kind: ProjectWorkflowKind
    public let state: WorkflowSessionState
    public let message: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let durationMilliseconds: Int
    public let currentStepIndex: Int?
    public let steps: [WorkflowStepStatus]
}

public struct WorkflowSessionOutput: Codable, Equatable, Sendable {
    public let workflowID: UUID
    public let state: WorkflowSessionState
    public let currentStepIndex: Int?
    public let currentStepName: String?
    public let commandID: UUID?
    public let stdout: String
    public let stderr: String
    public let stdoutOffset: Int
    public let stderrOffset: Int
    public let nextStdoutOffset: Int
    public let nextStderrOffset: Int
    public let stdoutHasMore: Bool
    public let stderrHasMore: Bool
}

public actor WorkflowSessionManager {
    public static let maximumSessionCount = 20
    public static let completedRetention: TimeInterval = 30 * 60

    private final class Session {
        let id: UUID
        let workspaceID: UUID
        let plan: ProjectWorkflowPlan
        let timeoutSeconds: Int
        let approvalGranted: Bool
        let startedAt: Date
        var state: WorkflowSessionState
        var message: String
        var finishedAt: Date?
        var currentStepIndex: Int?
        var commandIDs: [UUID?]
        var stepStates: [WorkflowStepState]
        var exitCodes: [Int32?]
        var errors: [[BuildError]]
        var auditRecorded = false

        init(
            id: UUID,
            workspaceID: UUID,
            plan: ProjectWorkflowPlan,
            timeoutSeconds: Int,
            approvalGranted: Bool,
            startedAt: Date,
            state: WorkflowSessionState,
            message: String
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.plan = plan
            self.timeoutSeconds = timeoutSeconds
            self.approvalGranted = approvalGranted
            self.startedAt = startedAt
            self.state = state
            self.message = message
            self.commandIDs = Array(repeating: nil, count: plan.commands.count)
            self.stepStates = Array(repeating: .pending, count: plan.commands.count)
            self.exitCodes = Array(repeating: nil, count: plan.commands.count)
            self.errors = Array(repeating: [], count: plan.commands.count)
        }
    }

    private let workflowAgent: ProjectWorkflowAgent
    private let commandSessionManager: CommandSessionManager
    private let auditLogger: AuditLogger
    private var sessions: [UUID: Session] = [:]

    public init(
        workflowAgent: ProjectWorkflowAgent,
        commandSessionManager: CommandSessionManager,
        auditLogger: AuditLogger
    ) {
        self.workflowAgent = workflowAgent
        self.commandSessionManager = commandSessionManager
        self.auditLogger = auditLogger
    }

    public func start(
        workspaceID: UUID,
        includeTests: Bool = true,
        includeBuild: Bool = true,
        timeoutSeconds: Int = ShellTool.maximumTimeoutSeconds,
        approvalGranted: Bool = false
    ) async throws -> WorkflowSessionStarted {
        let plan = try await workflowAgent.plan(
            workspaceID: workspaceID,
            includeTests: includeTests,
            includeBuild: includeBuild
        )
        return try await start(
            workspaceID: workspaceID,
            plan: plan,
            timeoutSeconds: timeoutSeconds,
            approvalGranted: approvalGranted
        )
    }

    public func start(
        workspaceID: UUID,
        plan: ProjectWorkflowPlan,
        timeoutSeconds: Int = ShellTool.maximumTimeoutSeconds,
        approvalGranted: Bool = false
    ) async throws -> WorkflowSessionStarted {
        pruneExpiredSessions()

        let id = UUID()
        let startedAt = Date()
        let timeout = max(1, min(timeoutSeconds, ShellTool.maximumTimeoutSeconds))
        let unsupported = plan.kind == .unknown || plan.commands.isEmpty
        let initialState: WorkflowSessionState = unsupported ? .unsupported : .planned
        let session = Session(
            id: id,
            workspaceID: workspaceID,
            plan: plan,
            timeoutSeconds: timeout,
            approvalGranted: approvalGranted,
            startedAt: startedAt,
            state: initialState,
            message: plan.message
        )
        if unsupported {
            session.finishedAt = startedAt
        }
        sessions[id] = session
        enforceSessionLimit()

        if unsupported {
            await recordAuditIfNeeded(session)
        } else {
            Task { [weak self] in
                await self?.run(workflowID: id)
            }
        }

        return WorkflowSessionStarted(
            workflowID: id,
            kind: plan.kind,
            state: session.state,
            message: session.message,
            startedAt: startedAt
        )
    }

    public func status(workflowID: UUID) async throws -> WorkflowSessionStatus {
        guard let session = sessions[workflowID] else {
            throw BridgeError.workflowSessionNotFound(workflowID)
        }
        await refreshCurrentStepIfNeeded(session)
        return statusValue(for: session)
    }

    public func output(
        workflowID: UUID,
        stdoutOffset: Int = 0,
        stderrOffset: Int = 0,
        limitBytes: Int = CommandSessionManager.maximumOutputChunkBytes
    ) async throws -> WorkflowSessionOutput {
        guard let session = sessions[workflowID] else {
            throw BridgeError.workflowSessionNotFound(workflowID)
        }
        await refreshCurrentStepIfNeeded(session)

        guard let index = session.currentStepIndex,
              session.commandIDs.indices.contains(index),
              let commandID = session.commandIDs[index] else {
            return WorkflowSessionOutput(
                workflowID: workflowID,
                state: session.state,
                currentStepIndex: session.currentStepIndex,
                currentStepName: session.currentStepIndex.flatMap {
                    session.plan.commands.indices.contains($0) ? session.plan.commands[$0].name : nil
                },
                commandID: nil,
                stdout: "",
                stderr: "",
                stdoutOffset: max(0, stdoutOffset),
                stderrOffset: max(0, stderrOffset),
                nextStdoutOffset: max(0, stdoutOffset),
                nextStderrOffset: max(0, stderrOffset),
                stdoutHasMore: false,
                stderrHasMore: false
            )
        }

        let commandOutput = try await commandSessionManager.output(
            commandID: commandID,
            stdoutOffset: stdoutOffset,
            stderrOffset: stderrOffset,
            limitBytes: limitBytes
        )
        return WorkflowSessionOutput(
            workflowID: workflowID,
            state: session.state,
            currentStepIndex: index,
            currentStepName: session.plan.commands[index].name,
            commandID: commandID,
            stdout: commandOutput.stdout,
            stderr: commandOutput.stderr,
            stdoutOffset: commandOutput.stdoutOffset,
            stderrOffset: commandOutput.stderrOffset,
            nextStdoutOffset: commandOutput.nextStdoutOffset,
            nextStderrOffset: commandOutput.nextStderrOffset,
            stdoutHasMore: commandOutput.stdoutHasMore,
            stderrHasMore: commandOutput.stderrHasMore
        )
    }

    public func cancel(workflowID: UUID) async throws -> WorkflowSessionStatus {
        guard let session = sessions[workflowID] else {
            throw BridgeError.workflowSessionNotFound(workflowID)
        }
        guard session.state == .planned || session.state == .running else {
            return statusValue(for: session)
        }

        session.state = .cancelled
        session.message = "Workflow cancelled"
        if let index = session.currentStepIndex,
           session.commandIDs.indices.contains(index),
           let commandID = session.commandIDs[index] {
            _ = try? await commandSessionManager.cancel(commandID: commandID)
            session.stepStates[index] = .cancelled
            if let commandStatus = try? await commandSessionManager.status(commandID: commandID) {
                session.exitCodes[index] = commandStatus.exitCode
                session.errors[index] = commandStatus.errors
            }
        }
        session.finishedAt = Date()
        await recordAuditIfNeeded(session)
        return statusValue(for: session)
    }

    private func run(workflowID: UUID) async {
        guard let session = sessions[workflowID],
              session.state == .planned else {
            return
        }
        session.state = .running
        session.message = "Workflow running"

        for index in session.plan.commands.indices {
            guard session.state == .running else { return }

            let command = session.plan.commands[index]
            session.currentStepIndex = index
            session.stepStates[index] = .running

            do {
                let started = try await commandSessionManager.start(
                    workspaceID: session.workspaceID,
                    executable: command.executable,
                    arguments: command.arguments,
                    workingDirectory: command.workingDirectory,
                    timeoutSeconds: session.timeoutSeconds,
                    approvalGranted: session.approvalGranted,
                    auditTool: "start_workflow"
                )
                session.commandIDs[index] = started.commandID

                let terminal = try await waitForCommand(
                    commandID: started.commandID,
                    session: session
                )
                session.exitCodes[index] = terminal.exitCode
                session.errors[index] = terminal.errors

                guard session.state == .running else { return }

                switch terminal.state {
                case .completed:
                    session.stepStates[index] = .completed
                case .failed:
                    session.stepStates[index] = .failed
                    finish(session, state: .failed, message: "\(command.name) failed")
                    await recordAuditIfNeeded(session)
                    return
                case .timedOut:
                    session.stepStates[index] = .timedOut
                    finish(session, state: .timedOut, message: "\(command.name) timed out")
                    await recordAuditIfNeeded(session)
                    return
                case .cancelled:
                    session.stepStates[index] = .cancelled
                    finish(session, state: .cancelled, message: "Workflow cancelled")
                    await recordAuditIfNeeded(session)
                    return
                case .running:
                    continue
                }
            } catch {
                guard session.state == .running else { return }
                session.stepStates[index] = .failed
                finish(session, state: .failed, message: error.localizedDescription)
                await recordAuditIfNeeded(session)
                return
            }
        }

        guard session.state == .running else { return }
        finish(session, state: .completed, message: "Project workflow completed")
        await recordAuditIfNeeded(session)
    }

    private func waitForCommand(
        commandID: UUID,
        session: Session
    ) async throws -> CommandSessionStatus {
        while session.state == .running {
            let status = try await commandSessionManager.status(commandID: commandID)
            if status.state != .running {
                return status
            }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return try await commandSessionManager.status(commandID: commandID)
    }

    private func refreshCurrentStepIfNeeded(_ session: Session) async {
        guard session.state == .running,
              let index = session.currentStepIndex,
              session.commandIDs.indices.contains(index),
              let commandID = session.commandIDs[index],
              let status = try? await commandSessionManager.status(commandID: commandID) else {
            return
        }
        session.exitCodes[index] = status.exitCode
        session.errors[index] = status.errors
    }

    private func finish(
        _ session: Session,
        state: WorkflowSessionState,
        message: String
    ) {
        guard session.finishedAt == nil else { return }
        session.state = state
        session.message = message
        session.finishedAt = Date()
    }

    private func statusValue(for session: Session) -> WorkflowSessionStatus {
        let end = session.finishedAt ?? Date()
        let steps = session.plan.commands.indices.map { index in
            let command = session.plan.commands[index]
            return WorkflowStepStatus(
                index: index,
                name: command.name,
                executable: command.executable,
                arguments: command.arguments,
                state: session.stepStates[index],
                commandID: session.commandIDs[index],
                exitCode: session.exitCodes[index],
                errors: session.errors[index]
            )
        }
        return WorkflowSessionStatus(
            workflowID: session.id,
            kind: session.plan.kind,
            state: session.state,
            message: session.message,
            startedAt: session.startedAt,
            finishedAt: session.finishedAt,
            durationMilliseconds: max(0, Int(end.timeIntervalSince(session.startedAt) * 1_000)),
            currentStepIndex: session.currentStepIndex,
            steps: steps
        )
    }

    private func recordAuditIfNeeded(_ session: Session) async {
        guard !session.auditRecorded else { return }
        session.auditRecorded = true
        let status: AuditStatus = session.state == .completed || session.state == .unsupported
            ? .success
            : .failure
        try? await auditLogger.record(AuditEntry(
            tool: "workflow",
            workspaceID: session.workspaceID,
            target: ".",
            status: status,
            durationMilliseconds: max(0, Int((session.finishedAt ?? Date()).timeIntervalSince(session.startedAt) * 1_000)),
            summary: "\(session.plan.kind.rawValue): \(session.state.rawValue)"
        ))
    }

    private func pruneExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-Self.completedRetention)
        let expired = sessions.values.filter { session in
            guard let finishedAt = session.finishedAt else { return false }
            return finishedAt < cutoff
        }
        for session in expired {
            sessions[session.id] = nil
        }
    }

    private func enforceSessionLimit() {
        guard sessions.count > Self.maximumSessionCount else { return }
        let removable = sessions.values
            .filter { $0.state != .running && $0.state != .planned }
            .sorted { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
        for session in removable.prefix(max(0, sessions.count - Self.maximumSessionCount)) {
            sessions[session.id] = nil
        }
    }
}
