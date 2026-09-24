import Foundation

public enum CodingTaskState: String, Codable, Equatable, Sendable {
    case planned
    case running
    case needsRepair
    case completed
    case failed
    case cancelled
    case timedOut
    case unsupported
}

public enum CodingTaskPhase: String, Codable, Equatable, Sendable {
    case analyzing
    case modifying
    case diffing
    case testing
    case building
    case packaging
    case repairing
    case complete
}

public struct CodingTaskChange: Codable, Equatable, Sendable {
    public let path: String
    public let mode: String
    public let oldText: String?
    public let newText: String?
    public let startLine: Int?
    public let endLine: Int?
    public let content: String?
    public let patch: String?

    public init(
        path: String,
        mode: String = "old_new",
        oldText: String? = nil,
        newText: String? = nil,
        startLine: Int? = nil,
        endLine: Int? = nil,
        content: String? = nil,
        patch: String? = nil
    ) {
        self.path = path
        self.mode = mode
        self.oldText = oldText
        self.newText = newText
        self.startLine = startLine
        self.endLine = endLine
        self.content = content
        self.patch = patch
    }
}

public struct CodingTaskStepStatus: Codable, Equatable, Sendable {
    public let index: Int
    public let name: String
    public let executable: String
    public let arguments: [String]
    public let state: WorkflowStepState
    public let commandID: UUID?
    public let exitCode: Int32?
    public let errors: [BuildError]
}

public struct CodingTaskResponse: Codable, Equatable, Sendable {
    public let taskID: UUID
    public let workspaceID: UUID
    public let requirement: String
    public let state: CodingTaskState
    public let phase: CodingTaskPhase
    public let message: String
    public let startedAt: Date
    public let finishedAt: Date?
    public let durationMilliseconds: Int
    public let repairAttempt: Int
    public let maximumRepairAttempts: Int
    public let appliedChanges: [String]
    public let changedFiles: [GitFileChange]
    public let errors: [BuildError]
    public let currentCommandID: UUID?
    public let steps: [CodingTaskStepStatus]
    public let stdout: String
    public let stderr: String
    public let stdoutOffset: Int
    public let stderrOffset: Int
    public let nextStdoutOffset: Int
    public let nextStderrOffset: Int
    public let stdoutHasMore: Bool
    public let stderrHasMore: Bool
}

public actor CodingTaskManager {
    public static let maximumSessionCount = 20
    public static let completedRetention: TimeInterval = 60 * 60

    private final class CommandStep {
        let command: ProjectWorkflowCommand
        let phase: CodingTaskPhase
        var state: WorkflowStepState = .pending
        var commandID: UUID?
        var exitCode: Int32?
        var errors: [BuildError] = []

        init(command: ProjectWorkflowCommand, phase: CodingTaskPhase) {
            self.command = command
            self.phase = phase
        }
    }

    private final class Session {
        let id: UUID
        let workspaceID: UUID
        let requirement: String
        let plan: ProjectWorkflowPlan
        let packageCommand: ProjectWorkflowCommand?
        let timeoutSeconds: Int
        let approvalGranted: Bool
        let maximumRepairAttempts: Int
        let startedAt: Date

        var state: CodingTaskState = .planned
        var phase: CodingTaskPhase = .analyzing
        var message = "Coding Task planned"
        var finishedAt: Date?
        var repairAttempt = 0
        var appliedChanges: [String] = []
        var changedFiles: [GitFileChange] = []
        var errors: [BuildError] = []
        var steps: [CommandStep] = []
        var currentStepIndex: Int?
        var currentCommandID: UUID?
        var auditRecorded = false

        init(
            id: UUID,
            workspaceID: UUID,
            requirement: String,
            plan: ProjectWorkflowPlan,
            packageCommand: ProjectWorkflowCommand?,
            timeoutSeconds: Int,
            approvalGranted: Bool,
            maximumRepairAttempts: Int,
            startedAt: Date
        ) {
            self.id = id
            self.workspaceID = workspaceID
            self.requirement = requirement
            self.plan = plan
            self.packageCommand = packageCommand
            self.timeoutSeconds = timeoutSeconds
            self.approvalGranted = approvalGranted
            self.maximumRepairAttempts = maximumRepairAttempts
            self.startedAt = startedAt
        }
    }

    private let workspaceManager: WorkspaceManager
    private let patchTool: PatchFileTool
    private let gitService: GitService
    private let commandSessionManager: CommandSessionManager
    private let auditLogger: AuditLogger
    private var sessions: [UUID: Session] = [:]

    public init(
        workspaceManager: WorkspaceManager,
        patchTool: PatchFileTool,
        gitService: GitService,
        commandSessionManager: CommandSessionManager,
        auditLogger: AuditLogger
    ) {
        self.workspaceManager = workspaceManager
        self.patchTool = patchTool
        self.gitService = gitService
        self.commandSessionManager = commandSessionManager
        self.auditLogger = auditLogger
    }

    public static func packageCommand(for workspace: BridgeWorkspace) -> ProjectWorkflowCommand? {
        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        let candidates: [(String, [String])] = [
            ("Scripts/build-app.sh", ["fast", "--no-install"]),
            ("Scripts/package.sh", []),
            ("package.sh", [])
        ]
        for (path, arguments) in candidates {
            let url = root.appendingPathComponent(path)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            return ProjectWorkflowCommand(
                name: "Package",
                executable: "/bin/zsh",
                arguments: [path] + arguments
            )
        }
        return nil
    }

    public func start(
        workspaceID: UUID,
        requirement: String,
        changes: [CodingTaskChange],
        plan: ProjectWorkflowPlan,
        packageCommand: ProjectWorkflowCommand?,
        timeoutSeconds: Int = ShellTool.maximumTimeoutSeconds,
        maximumRepairAttempts: Int = 2,
        approvalGranted: Bool = false
    ) async throws -> CodingTaskResponse {
        pruneExpiredSessions()

        let trimmedRequirement = requirement.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedRequirement.isEmpty else {
            throw ToolRouterError.invalidArguments("requirement 不能为空")
        }

        let id = UUID()
        let session = Session(
            id: id,
            workspaceID: workspaceID,
            requirement: trimmedRequirement,
            plan: plan,
            packageCommand: packageCommand,
            timeoutSeconds: max(1, min(timeoutSeconds, ShellTool.maximumTimeoutSeconds)),
            approvalGranted: approvalGranted,
            maximumRepairAttempts: max(0, min(maximumRepairAttempts, 5)),
            startedAt: Date()
        )
        sessions[id] = session
        enforceSessionLimit()

        let commands = commands(for: session)
        guard !commands.isEmpty else {
            finish(
                session,
                state: .unsupported,
                message: plan.kind == .unknown
                    ? "No supported verification or package workflow was detected"
                    : "Coding Task has no verification or package steps"
            )
            await recordAuditIfNeeded(session)
            return response(for: session)
        }

        do {
            try await apply(changes: changes, to: session, repair: false)
            try await refreshDiff(session)
        } catch let error as BridgeError {
            if case .approvalRequired = error {
                sessions[id] = nil
                throw error
            }
            finish(session, state: .failed, message: error.localizedDescription)
            await recordAuditIfNeeded(session)
            return response(for: session)
        } catch {
            finish(session, state: .failed, message: error.localizedDescription)
            await recordAuditIfNeeded(session)
            return response(for: session)
        }

        resetSteps(session)
        Task { [weak self] in
            await self?.run(taskID: id)
        }
        return response(for: session)
    }

    public func repair(
        taskID: UUID,
        changes: [CodingTaskChange],
        approvalGranted: Bool = false
    ) async throws -> CodingTaskResponse {
        guard let session = sessions[taskID] else {
            throw BridgeError.codingTaskNotFound(taskID)
        }
        guard session.state == .needsRepair else {
            throw ToolRouterError.invalidArguments("Coding Task 当前不是 needsRepair 状态")
        }
        guard session.repairAttempt < session.maximumRepairAttempts else {
            finish(session, state: .failed, message: "Maximum repair attempts reached")
            await recordAuditIfNeeded(session)
            return response(for: session)
        }
        guard !changes.isEmpty else {
            throw ToolRouterError.invalidArguments("repair 需要至少一个 change")
        }

        session.repairAttempt += 1
        session.phase = .repairing
        session.message = "Applying repair attempt \(session.repairAttempt)"
        session.errors = []

        do {
            try await apply(
                changes: changes,
                to: session,
                repair: true,
                approvalGranted: approvalGranted
            )
            try await refreshDiff(session)
        } catch let error as BridgeError {
            if case .approvalRequired = error { throw error }
            session.state = .needsRepair
            session.message = error.localizedDescription
            return response(for: session)
        } catch {
            session.state = .needsRepair
            session.message = error.localizedDescription
            return response(for: session)
        }

        resetSteps(session)
        session.state = .planned
        Task { [weak self] in
            await self?.run(taskID: taskID)
        }
        return response(for: session)
    }

    public func status(taskID: UUID) async throws -> CodingTaskResponse {
        guard let session = sessions[taskID] else {
            throw BridgeError.codingTaskNotFound(taskID)
        }
        await refreshCurrentCommand(session)
        return response(for: session)
    }

    public func output(
        taskID: UUID,
        stdoutOffset: Int = 0,
        stderrOffset: Int = 0,
        limitBytes: Int = CommandSessionManager.maximumOutputChunkBytes
    ) async throws -> CodingTaskResponse {
        guard let session = sessions[taskID] else {
            throw BridgeError.codingTaskNotFound(taskID)
        }
        await refreshCurrentCommand(session)

        guard let commandID = session.currentCommandID else {
            return response(
                for: session,
                stdoutOffset: stdoutOffset,
                stderrOffset: stderrOffset
            )
        }
        let output = try await commandSessionManager.output(
            commandID: commandID,
            stdoutOffset: stdoutOffset,
            stderrOffset: stderrOffset,
            limitBytes: limitBytes
        )
        return response(
            for: session,
            output: output
        )
    }

    public func cancel(taskID: UUID) async throws -> CodingTaskResponse {
        guard let session = sessions[taskID] else {
            throw BridgeError.codingTaskNotFound(taskID)
        }
        guard [.planned, .running, .needsRepair].contains(session.state) else {
            return response(for: session)
        }

        session.state = .cancelled
        session.phase = .complete
        session.message = "Coding Task cancelled"
        if let index = session.currentStepIndex,
           session.steps.indices.contains(index),
           let commandID = session.steps[index].commandID {
            _ = try? await commandSessionManager.cancel(commandID: commandID)
            session.steps[index].state = .cancelled
        }
        session.finishedAt = Date()
        await recordAuditIfNeeded(session)
        return response(for: session)
    }

    public func commands(taskID: UUID) throws -> [ProjectWorkflowCommand] {
        guard let session = sessions[taskID] else {
            throw BridgeError.codingTaskNotFound(taskID)
        }
        return commands(for: session)
    }

    private func apply(
        changes: [CodingTaskChange],
        to session: Session,
        repair: Bool,
        approvalGranted: Bool? = nil
    ) async throws {
        guard !changes.isEmpty else { return }
        session.phase = repair ? .repairing : .modifying
        session.message = repair ? "Applying repair changes" : "Applying requested changes"

        for change in changes {
            _ = try await patchTool.execute(
                workspaceID: session.workspaceID,
                path: change.path,
                mode: change.mode,
                oldText: change.oldText,
                newText: change.newText,
                startLine: change.startLine,
                endLine: change.endLine,
                content: change.content,
                patch: change.patch,
                approvalGranted: approvalGranted ?? session.approvalGranted
            )
            if !session.appliedChanges.contains(change.path) {
                session.appliedChanges.append(change.path)
            }
        }
    }

    private func refreshDiff(_ session: Session) async throws {
        session.phase = .diffing
        session.message = "Collecting Git diff"
        let workspace = try await workspaceManager.workspace(id: session.workspaceID)
        session.changedFiles = try gitService.getChangedFiles(workspace: workspace).files
    }

    private func commands(for session: Session) -> [ProjectWorkflowCommand] {
        session.plan.commands + (session.packageCommand.map { [$0] } ?? [])
    }

    private func resetSteps(_ session: Session) {
        let verification = session.plan.commands.map { command in
            CommandStep(command: command, phase: phase(for: command))
        }
        let package = session.packageCommand.map {
            [CommandStep(command: $0, phase: .packaging)]
        } ?? []
        session.steps = verification + package
        session.currentStepIndex = nil
        session.currentCommandID = nil
        session.errors = []
        session.finishedAt = nil
        session.auditRecorded = false
    }

    private func phase(for command: ProjectWorkflowCommand) -> CodingTaskPhase {
        command.name.lowercased().contains("test") ? .testing : .building
    }

    private func run(taskID: UUID) async {
        guard let session = sessions[taskID],
              session.state == .planned else { return }

        session.state = .running
        session.message = "Coding Task running"

        for index in session.steps.indices {
            guard session.state == .running else { return }
            let step = session.steps[index]
            session.currentStepIndex = index
            session.phase = step.phase
            session.message = step.command.name
            step.state = .running

            do {
                let started = try await commandSessionManager.start(
                    workspaceID: session.workspaceID,
                    executable: step.command.executable,
                    arguments: step.command.arguments,
                    workingDirectory: step.command.workingDirectory,
                    timeoutSeconds: session.timeoutSeconds,
                    approvalGranted: session.approvalGranted,
                    auditTool: "coding_task"
                )
                step.commandID = started.commandID
                session.currentCommandID = started.commandID

                let terminal = try await waitForCommand(
                    commandID: started.commandID,
                    session: session
                )
                step.exitCode = terminal.exitCode
                step.errors = terminal.errors
                session.errors = terminal.errors

                guard session.state == .running else { return }

                switch terminal.state {
                case .completed:
                    step.state = .completed
                case .failed:
                    step.state = .failed
                    await verificationFailed(session, step: step)
                    return
                case .timedOut:
                    step.state = .timedOut
                    finish(session, state: .timedOut, message: "\(step.command.name) timed out")
                    await recordAuditIfNeeded(session)
                    return
                case .cancelled:
                    step.state = .cancelled
                    finish(session, state: .cancelled, message: "Coding Task cancelled")
                    await recordAuditIfNeeded(session)
                    return
                case .running:
                    continue
                }
            } catch {
                guard session.state == .running else { return }
                step.state = .failed
                let message = error.localizedDescription
                if session.repairAttempt < session.maximumRepairAttempts {
                    session.state = .needsRepair
                    session.message = message
                } else {
                    finish(session, state: .failed, message: message)
                    await recordAuditIfNeeded(session)
                }
                return
            }
        }

        guard session.state == .running else { return }
        do {
            try await refreshDiff(session)
        } catch {
            finish(session, state: .failed, message: error.localizedDescription)
            await recordAuditIfNeeded(session)
            return
        }
        finish(session, state: .completed, message: "Coding Task completed")
        await recordAuditIfNeeded(session)
    }

    private func verificationFailed(_ session: Session, step: CommandStep) async {
        if session.repairAttempt < session.maximumRepairAttempts {
            session.state = .needsRepair
            session.message = "\(step.command.name) failed; repair patch required"
            return
        }
        finish(
            session,
            state: .failed,
            message: "\(step.command.name) failed after \(session.repairAttempt) repair attempts"
        )
        await recordAuditIfNeeded(session)
    }

    private func waitForCommand(
        commandID: UUID,
        session: Session
    ) async throws -> CommandSessionStatus {
        while session.state == .running {
            let status = try await commandSessionManager.status(commandID: commandID)
            if status.state != .running { return status }
            try? await Task.sleep(for: .milliseconds(150))
        }
        return try await commandSessionManager.status(commandID: commandID)
    }

    private func refreshCurrentCommand(_ session: Session) async {
        guard let index = session.currentStepIndex,
              session.steps.indices.contains(index),
              let commandID = session.steps[index].commandID,
              let status = try? await commandSessionManager.status(commandID: commandID) else {
            return
        }
        session.steps[index].exitCode = status.exitCode
        session.steps[index].errors = status.errors
        if !status.errors.isEmpty {
            session.errors = status.errors
        }
    }

    private func finish(
        _ session: Session,
        state: CodingTaskState,
        message: String
    ) {
        session.state = state
        session.phase = .complete
        session.message = message
        session.finishedAt = Date()
    }

    private func response(
        for session: Session,
        output: CommandSessionOutput? = nil,
        stdoutOffset: Int = 0,
        stderrOffset: Int = 0
    ) -> CodingTaskResponse {
        let end = session.finishedAt ?? Date()
        return CodingTaskResponse(
            taskID: session.id,
            workspaceID: session.workspaceID,
            requirement: session.requirement,
            state: session.state,
            phase: session.phase,
            message: session.message,
            startedAt: session.startedAt,
            finishedAt: session.finishedAt,
            durationMilliseconds: max(0, Int(end.timeIntervalSince(session.startedAt) * 1_000)),
            repairAttempt: session.repairAttempt,
            maximumRepairAttempts: session.maximumRepairAttempts,
            appliedChanges: session.appliedChanges,
            changedFiles: session.changedFiles,
            errors: session.errors,
            currentCommandID: session.currentCommandID,
            steps: session.steps.enumerated().map { index, step in
                CodingTaskStepStatus(
                    index: index,
                    name: step.command.name,
                    executable: step.command.executable,
                    arguments: step.command.arguments,
                    state: step.state,
                    commandID: step.commandID,
                    exitCode: step.exitCode,
                    errors: step.errors
                )
            },
            stdout: output?.stdout ?? "",
            stderr: output?.stderr ?? "",
            stdoutOffset: output?.stdoutOffset ?? max(0, stdoutOffset),
            stderrOffset: output?.stderrOffset ?? max(0, stderrOffset),
            nextStdoutOffset: output?.nextStdoutOffset ?? max(0, stdoutOffset),
            nextStderrOffset: output?.nextStderrOffset ?? max(0, stderrOffset),
            stdoutHasMore: output?.stdoutHasMore ?? false,
            stderrHasMore: output?.stderrHasMore ?? false
        )
    }

    private func recordAuditIfNeeded(_ session: Session) async {
        guard !session.auditRecorded else { return }
        session.auditRecorded = true
        let success = session.state == .completed || session.state == .unsupported
        try? await auditLogger.record(AuditEntry(
            tool: "coding_task",
            workspaceID: session.workspaceID,
            target: ".",
            status: success ? .success : .failure,
            durationMilliseconds: max(
                0,
                Int((session.finishedAt ?? Date()).timeIntervalSince(session.startedAt) * 1_000)
            ),
            summary: "\(session.state.rawValue): \(session.requirement)"
        ))
    }

    private func pruneExpiredSessions() {
        let cutoff = Date().addingTimeInterval(-Self.completedRetention)
        for session in sessions.values {
            guard let finishedAt = session.finishedAt, finishedAt < cutoff else { continue }
            sessions[session.id] = nil
        }
    }

    private func enforceSessionLimit() {
        guard sessions.count > Self.maximumSessionCount else { return }
        let removable = sessions.values
            .filter { ![.planned, .running, .needsRepair].contains($0.state) }
            .sorted { ($0.finishedAt ?? $0.startedAt) < ($1.finishedAt ?? $1.startedAt) }
        for session in removable.prefix(max(0, sessions.count - Self.maximumSessionCount)) {
            sessions[session.id] = nil
        }
    }
}
