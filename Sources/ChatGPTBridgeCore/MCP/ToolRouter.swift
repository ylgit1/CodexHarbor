import Foundation

public actor ToolRouter {
    private let workspaceManager: WorkspaceManager
    private let openWorkspaceTool: OpenWorkspaceTool
    private let readTool: ReadFileTool
    private let searchTool: SearchTool
    private let editTool: EditFileTool
    private let patchTool: PatchFileTool
    private let gitService: GitService
    private let workspaceInspectionTool: WorkspaceInspectionTool
    private let writeTool: WriteFileTool
    private let commandService: CommandService
    private let commandSessionManager: CommandSessionManager
    private let repairAgent: RepairAgent
    private let workflowAgent: ProjectWorkflowAgent
    private let workflowSessionManager: WorkflowSessionManager
    private let codingTaskManager: CodingTaskManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let approvalStore: BridgeApprovalStore?
    private let workspaceSessionStore: WorkspaceSessionStore

    public init(
        workspaceManager: WorkspaceManager,
        configuration: BridgeConfiguration,
        auditLogger: AuditLogger,
        approvalStore: BridgeApprovalStore? = nil,
        workspaceSessionStore: WorkspaceSessionStore = WorkspaceSessionStore()
    ) {
        self.workspaceManager = workspaceManager
        self.auditLogger = auditLogger
        self.approvalStore = approvalStore
        self.workspaceSessionStore = workspaceSessionStore
        let permissions = PermissionEngine(configuration: configuration)
        self.permissionEngine = permissions
        self.openWorkspaceTool = OpenWorkspaceTool(workspaceManager: workspaceManager)
        self.readTool = ReadFileTool(workspaceManager: workspaceManager)
        self.searchTool = SearchTool(workspaceManager: workspaceManager)
        self.editTool = EditFileTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        let patchTool = PatchFileTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        self.patchTool = patchTool
        let gitService = GitService()
        self.gitService = gitService
        self.workspaceInspectionTool = WorkspaceInspectionTool(workspaceManager: workspaceManager)
        self.writeTool = WriteFileTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        let shellTool = ShellTool(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        let commandService = CommandService(shellTool: shellTool)
        self.commandService = commandService
        self.commandSessionManager = CommandSessionManager(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger
        )
        self.repairAgent = RepairAgent(
            workspaceManager: workspaceManager,
            gitService: gitService,
            commandService: commandService,
            patchTool: patchTool
        )
        let workflowAgent = ProjectWorkflowAgent(
            workspaceManager: workspaceManager,
            commandService: commandService
        )
        self.workflowAgent = workflowAgent
        self.workflowSessionManager = WorkflowSessionManager(
            workflowAgent: workflowAgent,
            commandSessionManager: commandSessionManager,
            auditLogger: auditLogger
        )
        self.codingTaskManager = CodingTaskManager(
            workspaceManager: workspaceManager,
            patchTool: patchTool,
            gitService: gitService,
            commandSessionManager: commandSessionManager,
            auditLogger: auditLogger
        )
    }

    public func definitions() -> [MCPToolDefinition] {
        MCPToolCatalog.definitions
    }

    public func execute(
        name: String,
        arguments: [String: JSONValue],
        context: ToolExecutionContext = ToolExecutionContext()
    ) async throws -> JSONValue {
        let startedAt = Date()
        do {
            switch name {
            case "open_workspace":
                let path = try requiredString("path", in: arguments)
                let result = try await openWorkspaceTool.execute(path: path)
                let workspace = try await workspaceManager.workspace(id: result.workspaceID)
                await workspaceSessionStore.bind(sessionID: context.sessionID, workspace: workspace)
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: result.workspaceID,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "workspace opened"
                )
                return try JSONValue.encoded(result)

            case "read":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let result = try await readTool.execute(
                    workspaceID: workspaceID,
                    path: path,
                    offset: try optionalInt("offset", in: arguments) ?? 1,
                    limit: try optionalInt("limit", in: arguments) ?? ReadFileTool.defaultLineLimit
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: workspaceID,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "read lines \(result.startLine)-\(result.endLine)"
                )
                return try JSONValue.encoded(result)

            case "search":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let query = try requiredString("query", in: arguments)
                let path = optionalString("path", in: arguments) ?? "."
                let result = try await searchTool.execute(
                    workspaceID: workspaceID,
                    query: query,
                    path: path
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: workspaceID,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "\(result.matchLineCount) matches"
                )
                return try JSONValue.encoded(result)

            case "list_directory":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = optionalString("path", in: arguments) ?? "."
                let result = try await workspaceInspectionTool.listDirectory(
                    workspaceID: targetWorkspace,
                    path: path,
                    includeHidden: optionalBool("includeHidden", in: arguments) ?? false,
                    limit: try optionalInt("limit", in: arguments) ?? WorkspaceInspectionTool.maximumDirectoryEntries
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "\(result.entries.count) entries"
                )
                return try JSONValue.encoded(result)

            case "workspace_tree":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = optionalString("path", in: arguments) ?? "."
                let result = try await workspaceInspectionTool.workspaceTree(
                    workspaceID: targetWorkspace,
                    path: path,
                    depth: try optionalInt("depth", in: arguments) ?? 3,
                    includeHidden: optionalBool("includeHidden", in: arguments) ?? false,
                    limit: try optionalInt("limit", in: arguments) ?? WorkspaceInspectionTool.maximumTreeEntries
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "\(result.entries.count) tree entries"
                )
                return try JSONValue.encoded(result)

            case "edit":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: path,
                    details: [try requiredString("oldText", in: arguments), try requiredString("newText", in: arguments)],
                    fallback: context.approvalGranted
                )
                let result = try await editTool.execute(
                    workspaceID: targetWorkspace,
                    path: path,
                    oldText: try requiredString("oldText", in: arguments),
                    newText: try requiredString("newText", in: arguments),
                    approvalGranted: approvalGranted
                )
                return try JSONValue.encoded(result)

            case "patch_file":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let mode = optionalString("mode", in: arguments) ?? "old_new"
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: path,
                    details: patchApprovalDetails(arguments),
                    fallback: context.approvalGranted
                )
                let result = try await patchTool.execute(
                    workspaceID: targetWorkspace,
                    path: path,
                    mode: mode,
                    oldText: optionalString("oldText", in: arguments),
                    newText: optionalString("newText", in: arguments),
                    startLine: try optionalInt("startLine", in: arguments),
                    endLine: try optionalInt("endLine", in: arguments),
                    content: optionalString("content", in: arguments),
                    patch: optionalString("patch", in: arguments),
                    approvalGranted: approvalGranted
                )
                return try JSONValue.encoded(result)

            case "git_diff":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let workspace = try await workspaceManager.workspace(id: targetWorkspace)
                let path = optionalString("path", in: arguments)
                let result = try gitService.getDiff(workspace: workspace, path: path)
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: path,
                    status: .success,
                    startedAt: startedAt,
                    summary: "\(result.files.count) changed files"
                )
                return try JSONValue.encoded(result)

            case "git_status":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let workspace = try await workspaceManager.workspace(id: targetWorkspace)
                let result = try gitService.getStatus(workspace: workspace)
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: ".",
                    status: .success,
                    startedAt: startedAt,
                    summary: result.isClean ? "working tree clean" : "\(result.entries.count) status entries"
                )
                return try JSONValue.encoded(result)

            case "write":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let overwrite = optionalBool("overwrite", in: arguments) ?? false
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: path,
                    details: [overwrite ? "overwrite" : "create", try requiredString("content", in: arguments)],
                    fallback: context.approvalGranted
                )
                let result = try await writeTool.execute(
                    workspaceID: targetWorkspace,
                    path: path,
                    content: try requiredString("content", in: arguments),
                    overwrite: overwrite,
                    approvalGranted: approvalGranted
                )
                return try JSONValue.encoded(result)

            case "bash", "run_command":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let executable = try requiredString("executable", in: arguments)
                let rawArguments = arguments["arguments"]?.arrayValue ?? []
                let commandArguments = try rawArguments.map { value -> String in
                    guard let string = value.stringValue else {
                        throw ToolRouterError.invalidArguments("arguments 必须是字符串数组")
                    }
                    return string
                }
                let workingDirectory = optionalString("workingDirectory", in: arguments) ?? "."
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: workingDirectory,
                    details: [executable] + commandArguments,
                    fallback: context.approvalGranted
                )
                let result = try await commandService.run(
                    workspaceID: targetWorkspace,
                    executable: executable,
                    arguments: commandArguments,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? 30,
                    approvalGranted: approvalGranted,
                    auditTool: name
                )
                return try JSONValue.encoded(result)

            case "start_command":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let executable = try requiredString("executable", in: arguments)
                let rawArguments = arguments["arguments"]?.arrayValue ?? []
                let commandArguments = try rawArguments.map { value -> String in
                    guard let string = value.stringValue else {
                        throw ToolRouterError.invalidArguments("arguments 必须是字符串数组")
                    }
                    return string
                }
                let workingDirectory = optionalString("workingDirectory", in: arguments) ?? "."
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: workingDirectory,
                    details: [executable] + commandArguments,
                    fallback: context.approvalGranted
                )
                let result = try await commandSessionManager.start(
                    workspaceID: targetWorkspace,
                    executable: executable,
                    arguments: commandArguments,
                    workingDirectory: workingDirectory,
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? ShellTool.maximumTimeoutSeconds,
                    approvalGranted: approvalGranted,
                    auditTool: name
                )
                return try JSONValue.encoded(result)

            case "command_status":
                let commandID = try requiredUUID("commandId", in: arguments)
                return try JSONValue.encoded(
                    try await commandSessionManager.status(commandID: commandID)
                )

            case "command_output":
                let commandID = try requiredUUID("commandId", in: arguments)
                return try JSONValue.encoded(
                    try await commandSessionManager.output(
                        commandID: commandID,
                        stdoutOffset: try optionalInt("stdoutOffset", in: arguments) ?? 0,
                        stderrOffset: try optionalInt("stderrOffset", in: arguments) ?? 0,
                        limitBytes: try optionalInt("limitBytes", in: arguments) ?? CommandSessionManager.maximumOutputChunkBytes
                    )
                )

            case "cancel_command":
                let commandID = try requiredUUID("commandId", in: arguments)
                return try JSONValue.encoded(
                    try await commandSessionManager.cancel(commandID: commandID)
                )

            case "start_workflow":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let includeTests = optionalBool("includeTests", in: arguments) ?? true
                let includeBuild = optionalBool("includeBuild", in: arguments) ?? true
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: ".",
                    details: [
                        includeTests ? "tests" : "no-tests",
                        includeBuild ? "build" : "no-build"
                    ],
                    fallback: context.approvalGranted
                )
                let result = try await workflowSessionManager.start(
                    workspaceID: targetWorkspace,
                    includeTests: includeTests,
                    includeBuild: includeBuild,
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? ShellTool.maximumTimeoutSeconds,
                    approvalGranted: approvalGranted
                )
                return try JSONValue.encoded(result)

            case "workflow_status":
                let workflowID = try requiredUUID("workflowId", in: arguments)
                return try JSONValue.encoded(
                    try await workflowSessionManager.status(workflowID: workflowID)
                )

            case "workflow_output":
                let workflowID = try requiredUUID("workflowId", in: arguments)
                return try JSONValue.encoded(
                    try await workflowSessionManager.output(
                        workflowID: workflowID,
                        stdoutOffset: try optionalInt("stdoutOffset", in: arguments) ?? 0,
                        stderrOffset: try optionalInt("stderrOffset", in: arguments) ?? 0,
                        limitBytes: try optionalInt("limitBytes", in: arguments) ?? CommandSessionManager.maximumOutputChunkBytes
                    )
                )

            case "cancel_workflow":
                let workflowID = try requiredUUID("workflowId", in: arguments)
                return try JSONValue.encoded(
                    try await workflowSessionManager.cancel(workflowID: workflowID)
                )

            case "run_workflow":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let includeTests = optionalBool("includeTests", in: arguments) ?? true
                let includeBuild = optionalBool("includeBuild", in: arguments) ?? true
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: ".",
                    details: [
                        includeTests ? "tests" : "no-tests",
                        includeBuild ? "build" : "no-build"
                    ],
                    fallback: context.approvalGranted
                )
                let result = try await workflowAgent.run(
                    workspaceID: targetWorkspace,
                    includeTests: includeTests,
                    includeBuild: includeBuild,
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? 300,
                    approvalGranted: approvalGranted
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: ".",
                    status: result.state == .failed ? .failure : .success,
                    startedAt: startedAt,
                    summary: "\(result.kind.rawValue): \(result.state.rawValue)"
                )
                return try JSONValue.encoded(result)

            case "repair_project":
                let targetWorkspace = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let patchPath = optionalString("path", in: arguments)
                let unifiedDiff = optionalString("patch", in: arguments)
                let approvalGranted = try approvalState(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: patchPath ?? ".",
                    details: [patchPath ?? "", unifiedDiff ?? ""],
                    fallback: context.approvalGranted
                )
                let result = try await repairAgent.repair(
                    workspaceID: targetWorkspace,
                    patchPath: patchPath,
                    unifiedDiff: unifiedDiff,
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? 300,
                    approvalGranted: approvalGranted
                )
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: targetWorkspace,
                    target: patchPath ?? ".",
                    status: result.state == .failed ? .failure : .success,
                    startedAt: startedAt,
                    summary: result.state.rawValue
                )
                return try JSONValue.encoded(result)

            case "coding_task":
                let action = optionalString("action", in: arguments) ?? "start"
                switch action {
                case "start":
                    let targetWorkspace = try await resolveWorkspaceID(
                        in: arguments,
                        sessionID: context.sessionID
                    )
                    let requirement = try requiredString("requirement", in: arguments)
                    let changes = try codingTaskChanges(in: arguments)
                    let includeTests = optionalBool("includeTests", in: arguments) ?? true
                    let includeBuild = optionalBool("includeBuild", in: arguments) ?? true
                    let includePackage = optionalBool("includePackage", in: arguments) ?? true
                    let timeoutSeconds = try optionalInt("timeoutSeconds", in: arguments)
                        ?? ShellTool.maximumTimeoutSeconds
                    let maximumRepairAttempts = try optionalInt("maxRepairAttempts", in: arguments) ?? 2

                    let plan = try await workflowAgent.plan(
                        workspaceID: targetWorkspace,
                        includeTests: includeTests,
                        includeBuild: includeBuild
                    )
                    let workspace = try await workspaceManager.workspace(id: targetWorkspace)
                    let packageCommand = includePackage
                        ? CodingTaskManager.packageCommand(for: workspace)
                        : nil
                    let commands = plan.commands + (packageCommand.map { [$0] } ?? [])
                    let approvalGranted = try approvalState(
                        tool: name,
                        workspaceID: targetWorkspace,
                        target: ".",
                        details: [requirement] + changes.map(\.path),
                        fallback: context.approvalGranted
                    )
                    try authorizeCodingTask(
                        changes: changes,
                        commands: commands,
                        timeoutSeconds: timeoutSeconds,
                        approvalGranted: approvalGranted
                    )

                    return try JSONValue.encoded(
                        try await codingTaskManager.start(
                            workspaceID: targetWorkspace,
                            requirement: requirement,
                            changes: changes,
                            plan: plan,
                            packageCommand: packageCommand,
                            timeoutSeconds: timeoutSeconds,
                            maximumRepairAttempts: maximumRepairAttempts,
                            approvalGranted: approvalGranted
                        )
                    )

                case "status":
                    return try JSONValue.encoded(
                        try await codingTaskManager.status(
                            taskID: try requiredUUID("taskId", in: arguments)
                        )
                    )

                case "output":
                    return try JSONValue.encoded(
                        try await codingTaskManager.output(
                            taskID: try requiredUUID("taskId", in: arguments),
                            stdoutOffset: try optionalInt("stdoutOffset", in: arguments) ?? 0,
                            stderrOffset: try optionalInt("stderrOffset", in: arguments) ?? 0,
                            limitBytes: try optionalInt("limitBytes", in: arguments)
                                ?? CommandSessionManager.maximumOutputChunkBytes
                        )
                    )

                case "repair":
                    let taskID = try requiredUUID("taskId", in: arguments)
                    let changes = try codingTaskChanges(in: arguments)
                    let taskStatus = try await codingTaskManager.status(taskID: taskID)
                    let timeoutSeconds = try optionalInt("timeoutSeconds", in: arguments)
                        ?? ShellTool.maximumTimeoutSeconds
                    let approvalGranted = try approvalState(
                        tool: name,
                        workspaceID: taskStatus.workspaceID,
                        target: ".",
                        details: ["repair", taskID.uuidString] + changes.map(\.path),
                        fallback: context.approvalGranted
                    )
                    try authorizeCodingTask(
                        changes: changes,
                        commands: try await codingTaskManager.commands(taskID: taskID),
                        timeoutSeconds: timeoutSeconds,
                        approvalGranted: approvalGranted
                    )
                    return try JSONValue.encoded(
                        try await codingTaskManager.repair(
                            taskID: taskID,
                            changes: changes,
                            approvalGranted: approvalGranted
                        )
                    )

                case "cancel":
                    return try JSONValue.encoded(
                        try await codingTaskManager.cancel(
                            taskID: try requiredUUID("taskId", in: arguments)
                        )
                    )

                default:
                    throw ToolRouterError.invalidArguments(
                        "coding_task action 仅支持 start/status/output/repair/cancel"
                    )
                }

            default:
                throw ToolRouterError.unknownTool(name)
            }
        } catch let error as BridgeError {
            if case .approvalRequired(let operation) = error,
               let approvalStore {
                let workspace = await effectiveWorkspaceID(
                    in: arguments,
                    sessionID: context.sessionID
                )
                let target = arguments["path"]?.stringValue ?? arguments["workingDirectory"]?.stringValue
                let details = approvalDetails(name: name, arguments: arguments)
                let requestID = BridgeApprovalStore.requestID(
                    tool: name,
                    workspaceID: workspace,
                    target: target,
                    details: details
                )
                approvalStore.request(
                    id: requestID,
                    tool: name,
                    summary: operation,
                    target: target
                )
                switch await approvalStore.waitForDecision(id: requestID) {
                case .granted:
                    return try await execute(
                        name: name,
                        arguments: arguments,
                        context: ToolExecutionContext(
                            approvalGranted: true,
                            sessionID: context.sessionID
                        )
                    )
                case .denied:
                    throw BridgeError.permissionDenied("用户已拒绝 \(name) 操作")
                case .pending, .none:
                    throw BridgeError.approvalRequired("等待用户确认超时：\(operation)")
                }
            }
            if ["open_workspace", "read", "search", "list_directory", "workspace_tree", "git_diff", "git_status", "run_workflow", "repair_project"].contains(name) {
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: await effectiveWorkspaceID(
                        in: arguments,
                        sessionID: context.sessionID
                    ),
                    target: arguments["path"]?.stringValue,
                    status: .failure,
                    startedAt: startedAt,
                    summary: error.localizedDescription
                )
            }
            throw error
        } catch {
            if ["open_workspace", "read", "search", "list_directory", "workspace_tree", "git_diff", "git_status", "run_workflow", "repair_project"].contains(name) {
                await recordReadOnlyAudit(
                    tool: name,
                    workspaceID: await effectiveWorkspaceID(
                        in: arguments,
                        sessionID: context.sessionID
                    ),
                    target: arguments["path"]?.stringValue,
                    status: .failure,
                    startedAt: startedAt,
                    summary: error.localizedDescription
                )
            }
            throw error
        }
    }

    private func recordReadOnlyAudit(
        tool: String,
        workspaceID: UUID?,
        target: String?,
        status: AuditStatus,
        startedAt: Date,
        summary: String
    ) async {
        try? await auditLogger.record(AuditEntry(
            tool: tool,
            workspaceID: workspaceID,
            target: target,
            status: status,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(startedAt) * 1_000)),
            summary: summary
        ))
    }

    private func resolveWorkspaceID(
        in arguments: [String: JSONValue],
        sessionID: String?
    ) async throws -> UUID {
        if let raw = arguments["workspaceId"]?.stringValue {
            if let id = UUID(uuidString: raw) {
                do {
                    let workspace = try await workspaceManager.workspace(id: id)
                    await workspaceSessionStore.bind(sessionID: sessionID, workspace: workspace)
                    return id
                } catch {
                    await workspaceSessionStore.invalidate(workspaceID: id)
                }
            }

            if let recoveredID = await recoverWorkspaceID(sessionID: sessionID) {
                return recoveredID
            }

            throw ToolRouterError.invalidArguments("workspaceId 已失效，且没有可恢复的工作区，请先调用 open_workspace")
        }

        if let recoveredID = await recoverWorkspaceID(sessionID: sessionID) {
            return recoveredID
        }

        throw ToolRouterError.invalidArguments("尚未打开工作区，请先调用 open_workspace")
    }

    private func recoverWorkspaceID(sessionID: String?) async -> UUID? {
        if let storedID = await workspaceSessionStore.resolve(sessionID: sessionID) {
            do {
                let workspace = try await workspaceManager.workspace(id: storedID)
                await workspaceSessionStore.bind(sessionID: sessionID, workspace: workspace)
                return storedID
            } catch {
                await workspaceSessionStore.invalidate(workspaceID: storedID)
            }
        }

        for candidate in await workspaceManager.list() {
            do {
                let workspace = try await workspaceManager.workspace(id: candidate.id)
                await workspaceSessionStore.bind(sessionID: sessionID, workspace: workspace)
                return workspace.id
            } catch {
                await workspaceSessionStore.invalidate(workspaceID: candidate.id)
            }
        }

        return nil
    }

    private func providedWorkspaceID(in arguments: [String: JSONValue]) -> UUID? {
        guard let raw = arguments["workspaceId"]?.stringValue else { return nil }
        return UUID(uuidString: raw)
    }

    private func effectiveWorkspaceID(
        in arguments: [String: JSONValue],
        sessionID: String?
    ) async -> UUID? {
        if let provided = providedWorkspaceID(in: arguments) {
            return provided
        }
        return await workspaceSessionStore.resolve(sessionID: sessionID)
    }

    private func requiredString(_ key: String, in arguments: [String: JSONValue]) throws -> String {
        guard let value = arguments[key]?.stringValue else {
            throw ToolRouterError.invalidArguments("缺少字符串参数 \(key)")
        }
        return value
    }

    private func optionalString(_ key: String, in arguments: [String: JSONValue]) -> String? {
        arguments[key]?.stringValue
    }

    private func requiredUUID(_ key: String, in arguments: [String: JSONValue]) throws -> UUID {
        guard let raw = arguments[key]?.stringValue,
              let value = UUID(uuidString: raw) else {
            throw ToolRouterError.invalidArguments("参数 \(key) 必须是有效 UUID")
        }
        return value
    }

    private func optionalBool(_ key: String, in arguments: [String: JSONValue]) -> Bool? {
        arguments[key]?.boolValue
    }

    private func optionalInt(_ key: String, in arguments: [String: JSONValue]) throws -> Int? {
        guard let value = arguments[key] else { return nil }
        guard let integer = value.intValue else {
            throw ToolRouterError.invalidArguments("参数 \(key) 必须是整数")
        }
        return integer
    }

    private func codingTaskChanges(in arguments: [String: JSONValue]) throws -> [CodingTaskChange] {
        try (arguments["changes"]?.arrayValue ?? []).map { raw in
            guard let object = raw.objectValue,
                  let path = object["path"]?.stringValue,
                  !path.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ToolRouterError.invalidArguments("changes 中每项都必须包含 path")
            }
            return CodingTaskChange(
                path: path,
                mode: object["mode"]?.stringValue ?? "old_new",
                oldText: object["oldText"]?.stringValue,
                newText: object["newText"]?.stringValue,
                startLine: object["startLine"]?.intValue,
                endLine: object["endLine"]?.intValue,
                content: object["content"]?.stringValue,
                patch: object["patch"]?.stringValue
            )
        }
    }

    private func authorizeCodingTask(
        changes: [CodingTaskChange],
        commands: [ProjectWorkflowCommand],
        timeoutSeconds: Int,
        approvalGranted: Bool
    ) throws {
        if !changes.isEmpty {
            try permissionEngine.authorizePatch(PatchPermission(
                operation: "Coding Task 修改 \(changes.count) 个文件",
                approvalGranted: approvalGranted
            ))
        }

        let policy = CommandPolicy()
        for command in commands {
            let request = CommandRequest(
                executable: command.executable,
                arguments: command.arguments,
                workingDirectory: command.workingDirectory,
                timeoutSeconds: timeoutSeconds
            )
            try permissionEngine.authorizeCommand(
                policy.assess(request),
                request: request,
                approvalGranted: approvalGranted
            )
        }
    }

    private func approvalState(
        tool: String,
        workspaceID: UUID?,
        target: String?,
        details: [String],
        fallback: Bool
    ) throws -> Bool {
        guard let approvalStore else { return fallback }
        let id = BridgeApprovalStore.requestID(
            tool: tool,
            workspaceID: workspaceID,
            target: target,
            details: details
        )
        switch approvalStore.consumeDecision(id: id) {
        case .granted:
            return true
        case .denied:
            throw BridgeError.permissionDenied("用户已拒绝 \(tool) 操作")
        case .pending:
            return false
        case .none:
            return fallback
        }
    }

    private func approvalDetails(name: String, arguments: [String: JSONValue]) -> [String] {
        switch name {
        case "edit":
            return [
                arguments["oldText"]?.stringValue ?? "",
                arguments["newText"]?.stringValue ?? ""
            ]
        case "write":
            return [
                (arguments["overwrite"]?.boolValue ?? false) ? "overwrite" : "create",
                arguments["content"]?.stringValue ?? ""
            ]
        case "bash", "run_command", "start_command":
            let executable = arguments["executable"]?.stringValue ?? ""
            let args = (arguments["arguments"]?.arrayValue ?? []).compactMap(\.stringValue)
            return [executable] + args
        case "patch_file":
            return patchApprovalDetails(arguments)
        case "start_workflow", "run_workflow":
            return [
                arguments["includeTests"]?.boolValue == false ? "no-tests" : "tests",
                arguments["includeBuild"]?.boolValue == false ? "no-build" : "build"
            ]
        case "repair_project":
            return [arguments["path"]?.stringValue ?? "", arguments["patch"]?.stringValue ?? ""]
        case "coding_task":
            let action = arguments["action"]?.stringValue ?? "start"
            let requirement = arguments["requirement"]?.stringValue ?? ""
            let paths = (arguments["changes"]?.arrayValue ?? []).compactMap {
                $0.objectValue?["path"]?.stringValue
            }
            return [action, requirement] + paths
        default:
            return []
        }
    }

    private func patchApprovalDetails(_ arguments: [String: JSONValue]) -> [String] {
        [
            arguments["mode"]?.stringValue ?? "old_new",
            arguments["oldText"]?.stringValue ?? "",
            arguments["newText"]?.stringValue ?? "",
            arguments["content"]?.stringValue ?? "",
            arguments["patch"]?.stringValue ?? ""
        ]
    }
}
