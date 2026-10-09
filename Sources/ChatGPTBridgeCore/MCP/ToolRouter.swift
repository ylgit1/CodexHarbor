import Foundation

public actor ToolRouter {
    private let workspaceManager: WorkspaceManager
    private let openWorkspaceTool: OpenWorkspaceTool
    private let readTool: ReadFileTool
    private let tailTool: WorkspaceTailTool
    private let searchTool: SearchTool
    private let editTool: EditFileTool
    private let patchTool: PatchFileTool
    private let gitService: GitService
    private let workspaceInspectionTool: WorkspaceInspectionTool
    private let writeTool: WriteFileTool
    private let fileOperations: WorkspaceFileOperations
    private let commandService: CommandService
    private let commandSessionManager: CommandSessionManager
    private let repairAgent: RepairAgent
    private let workflowAgent: ProjectWorkflowAgent
    private let workflowSessionManager: WorkflowSessionManager
    private let codingTaskManager: CodingTaskManager
    private let permissionEngine: PermissionEngine
    private let trustedDevelopment: TrustedDevelopmentPolicy
    private let auditLogger: AuditLogger
    private let approvalStore: BridgeApprovalStore?
    private let workspaceSessionStore: WorkspaceSessionStore
    private let uiAutomationPaths: BridgePaths?

    public init(
        workspaceManager: WorkspaceManager,
        configuration: BridgeConfiguration,
        auditLogger: AuditLogger,
        approvalStore: BridgeApprovalStore? = nil,
        workspaceSessionStore: WorkspaceSessionStore = WorkspaceSessionStore(),
        trashRoot: URL? = nil,
        codingTaskJournalDirectory: URL? = nil,
        uiAutomationPaths: BridgePaths? = nil
    ) {
        self.uiAutomationPaths = uiAutomationPaths
        self.workspaceManager = workspaceManager
        self.auditLogger = auditLogger
        self.approvalStore = approvalStore
        self.workspaceSessionStore = workspaceSessionStore
        let permissions = PermissionEngine(configuration: configuration)
        self.permissionEngine = permissions
        self.trustedDevelopment = TrustedDevelopmentPolicy(configuration: configuration)
        self.openWorkspaceTool = OpenWorkspaceTool(workspaceManager: workspaceManager)
        self.readTool = ReadFileTool(workspaceManager: workspaceManager)
        self.tailTool = WorkspaceTailTool(workspaceManager: workspaceManager)
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
        self.fileOperations = WorkspaceFileOperations(
            workspaceManager: workspaceManager,
            permissionEngine: permissions,
            auditLogger: auditLogger,
            trashRoot: trashRoot ?? ((try? BridgePaths.live().root.appendingPathComponent("workspace-trash", isDirectory: true))
                ?? FileManager.default.temporaryDirectory.appendingPathComponent("harbor-workspace-trash", isDirectory: true))
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
            auditLogger: auditLogger,
            journalDirectory: codingTaskJournalDirectory
        )
    }

    private func uiPaths() throws -> BridgePaths {
        if let uiAutomationPaths { return uiAutomationPaths }
        return try BridgePaths.live()
    }

    /// Ask only when a tool needs a specific app and capability.
    /// The local Harbor panel persists consent; a remote tool call cannot.
    private func authorizeUIIfNeeded(
        bundleID: String, capability: HarborUIConsentStore.Capability
    ) async throws {
        guard HarborUIAuthorization.isValidTarget(bundleID) else {
            throw BridgeError.permissionDenied("目标应用不支持界面自动化授权")
        }
        let store = HarborUIConsentStore(paths: try uiPaths())
        if store.allows(bundleID: bundleID, capability: capability) { return }
        guard let approvalStore else {
            throw BridgeError.permissionDenied("本地授权弹窗不可用，已拒绝访问 \(bundleID)")
        }
        // Unique per invocation: concurrent requests cannot borrow another
        // command's decision or accidentally consume its approval.
        let requestID = BridgeApprovalStore.requestID(
            tool: HarborUIAuthorization.toolName(for: capability),
            workspaceID: nil, target: bundleID, details: []
        ) + "-" + UUID().uuidString
        approvalStore.request(
            id: requestID,
            tool: HarborUIAuthorization.toolName(for: capability),
            summary: "访问指定应用的界面",
            target: bundleID
        )
        switch await approvalStore.waitForDecision(id: requestID) {
        case .granted:
            // Even an approved request is useless without the local GUI having
            // actually written this exact capability for this exact app.
            guard store.allows(bundleID: bundleID, capability: capability) else {
                throw BridgeError.permissionDenied("本地授权未保存，已拒绝访问 \(bundleID)")
            }
        case .denied:
            throw BridgeError.permissionDenied("用户已拒绝对 \(bundleID) 的界面授权")
        case .pending, .none:
            throw BridgeError.approvalRequired("等待应用界面授权超时：\(bundleID)")
        }
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
            // UI automation is intentionally independent of workspace roots.
            // Consent is requested on demand and granted only by a user's
            // click on Harbor's local approval panel, never by MCP itself.
            case "ui_apps":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                return try JSONValue.encoded(await service.runningApps())

            case "ui_open_app":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .read)
                let app = try await service.open(bundleID: bundleID)
                try? await auditLogger.record(AuditEntry(
                    tool: "ui_open_app", workspaceID: nil, target: bundleID,
                    status: .success, durationMilliseconds: 0,
                    summary: "Opened locally authorized application"
                ))
                return try JSONValue.encoded(app)

            case "ui_windows":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .read)
                return try JSONValue.encoded(try await service.windows(bundleID: bundleID))

            case "ui_inspect":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .read)
                return try JSONValue.encoded(try await service.inspect(
                    bundleID: bundleID,
                    windowIndex: try requiredInt("windowIndex", in: arguments),
                    windowTitle: requiredString("windowTitle", in: arguments)
                ))

            case "ui_perform":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                let operation = try requiredString("operation", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .control)
                let result = try await service.perform(
                    bundleID: bundleID,
                    windowIndex: try requiredInt("windowIndex", in: arguments),
                    windowTitle: requiredString("windowTitle", in: arguments),
                    elementID: requiredString("elementID", in: arguments),
                    expectedLabel: requiredString("expectedLabel", in: arguments),
                    operation: operation,
                    text: optionalString("text", in: arguments)
                )
                try? await auditLogger.record(AuditEntry(
                    tool: "ui_perform", workspaceID: nil, target: bundleID,
                    status: .success, durationMilliseconds: 0,
                    summary: "AX \\(operation) succeeded; no entered text logged"
                ))
                return try JSONValue.encoded(result)

            case "ui_capture":
                let bundleID = try requiredString("bundleID", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .capture)
                // Run ScreenCaptureKit in the foreground signed app; invoking
                // it from the headless launchd Agent may crash CGS initialization.
                let result = try await HarborUICaptureSocket.capture(
                    paths: try uiPaths(),
                    bundleID: bundleID,
                    windowIndex: try requiredInt("windowIndex", in: arguments),
                    windowTitle: requiredString("windowTitle", in: arguments)
                )
                try? await auditLogger.record(AuditEntry(
                    tool: "ui_capture", workspaceID: nil, target: bundleID,
                    status: .success, durationMilliseconds: 0,
                    summary: "One authorized window frame captured; image not stored in audit"
                ))
                return try JSONValue.encoded(result)

            case "ui_test":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                let values = arguments["steps"]?.arrayValue ?? []
                guard !values.isEmpty, values.count <= 8 else {
                    throw ToolRouterError.invalidArguments("ui_test 只允许 1–8 个步骤")
                }
                let steps = try values.map { value -> HarborUITestStep in
                    guard let fields = value.objectValue,
                          let id = fields["elementID"]?.stringValue,
                          let label = fields["expectedLabel"]?.stringValue,
                          let action = fields["operation"]?.stringValue else {
                        throw ToolRouterError.invalidArguments("每步需要 elementID/expectedLabel/operation")
                    }
                    return HarborUITestStep(
                        elementID: id, expectedLabel: label, operation: action,
                        text: fields["text"]?.stringValue,
                        expectContains: fields["expectContains"]?.stringValue,
                        expectWindowGone: fields["expectWindowGone"]?.boolValue ?? false
                    )
                }
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .control)
                let report = await service.runTest(
                    bundleID: bundleID,
                    windowIndex: try requiredInt("windowIndex", in: arguments),
                    windowTitle: try requiredString("windowTitle", in: arguments),
                    steps: steps
                )
                try? await auditLogger.record(AuditEntry(
                    tool: "ui_test", workspaceID: nil, target: bundleID,
                    status: report.passed ? .success : .failure,
                    durationMilliseconds: report.durationMilliseconds,
                    summary: "AX test \(report.steps.count) steps, passed=\(report.passed)"
                ))
                return try JSONValue.encoded(report)

            case "ui_wait_window":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .read)
                return try JSONValue.encoded(try await service.waitForWindow(
                    bundleID: bundleID,
                    titleContains: requiredString("titleContains", in: arguments),
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? 10
                ))

            case "ui_wait":
                let service = await HarborUIAutomationService(paths: try uiPaths())
                let bundleID = try requiredString("bundleID", in: arguments)
                try await authorizeUIIfNeeded(bundleID: bundleID, capability: .read)
                return try JSONValue.encoded(try await service.waitFor(
                    bundleID: bundleID,
                    windowIndex: try requiredInt("windowIndex", in: arguments),
                    windowTitle: requiredString("windowTitle", in: arguments),
                    containsText: requiredString("containsText", in: arguments),
                    timeoutSeconds: try optionalInt("timeoutSeconds", in: arguments) ?? 10
                ))

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

            case "tail_file":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let result = try await tailTool.execute(
                    workspaceID: workspaceID,
                    path: try requiredString("path", in: arguments),
                    limitBytes: try optionalInt("limitBytes", in: arguments) ?? 64 * 1_024
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
                    fallback: await automaticApproval(workspaceID: targetWorkspace, context: context, modifyingFiles: true)
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
                    fallback: await automaticApproval(workspaceID: targetWorkspace, context: context, modifyingFiles: true)
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
                    fallback: await automaticApproval(workspaceID: targetWorkspace, context: context, modifyingFiles: true)
                )
                let result = try await writeTool.execute(
                    workspaceID: targetWorkspace,
                    path: path,
                    content: try requiredString("content", in: arguments),
                    overwrite: overwrite,
                    approvalGranted: approvalGranted
                )
                return try JSONValue.encoded(result)

            case "restore_path":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let id = try requiredUUID("trashId", in: arguments)
                let approved = try approvalState(
                    tool: name, workspaceID: workspaceID, target: id.uuidString,
                    details: approvalDetails(name: name, arguments: arguments),
                    fallback: await automaticApproval(workspaceID: workspaceID, context: context, modifyingFiles: true)
                )
                return try JSONValue.encoded(try await fileOperations.restore(
                    workspaceID: workspaceID, trashID: id, approvalGranted: approved
                ))

            case "list_trash":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                return try JSONValue.encoded(await fileOperations.listTrash(workspaceID: workspaceID))

            case "trash_path":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let approved = try approvalState(
                    tool: name, workspaceID: workspaceID, target: path,
                    details: approvalDetails(name: name, arguments: arguments),
                    fallback: await automaticApproval(workspaceID: workspaceID, context: context, modifyingFiles: true)
                )
                return try JSONValue.encoded(try await fileOperations.trash(
                    workspaceID: workspaceID, path: path, approvalGranted: approved
                ))

            case "move_path":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let destination = try requiredString("destination", in: arguments)
                let approved = try approvalState(
                    tool: name, workspaceID: workspaceID, target: path,
                    details: approvalDetails(name: name, arguments: arguments),
                    fallback: await automaticApproval(workspaceID: workspaceID, context: context, modifyingFiles: true)
                )
                return try JSONValue.encoded(try await fileOperations.move(
                    workspaceID: workspaceID, source: path, destination: destination, approvalGranted: approved
                ))

            case "create_directory":
                let workspaceID = try await resolveWorkspaceID(in: arguments, sessionID: context.sessionID)
                let path = try requiredString("path", in: arguments)
                let approved = try approvalState(
                    tool: name, workspaceID: workspaceID, target: path,
                    details: approvalDetails(name: name, arguments: arguments),
                    fallback: await automaticApproval(workspaceID: workspaceID, context: context, modifyingFiles: true)
                )
                return try JSONValue.encoded(try await fileOperations.createDirectory(
                    workspaceID: workspaceID, path: path, approvalGranted: approved
                ))

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
                    fallback: await automaticApproval(
                        workspaceID: targetWorkspace, context: context,
                        command: CommandRequest(executable: executable, arguments: commandArguments,
                                                workingDirectory: workingDirectory)
                    )
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
                    fallback: await automaticApproval(
                        workspaceID: targetWorkspace, context: context,
                        command: CommandRequest(executable: executable, arguments: commandArguments,
                                                workingDirectory: workingDirectory)
                    )
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
                    fallback: await automaticApproval(
                        workspaceID: targetWorkspace, context: context,
                        workflowCommands: try await workflowAgent.plan(
                            workspaceID: targetWorkspace, includeTests: includeTests, includeBuild: includeBuild
                        ).commands
                    )
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
                    fallback: await automaticApproval(
                        workspaceID: targetWorkspace, context: context,
                        workflowCommands: try await workflowAgent.plan(
                            workspaceID: targetWorkspace, includeTests: includeTests, includeBuild: includeBuild
                        ).commands
                    )
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
                    fallback: await automaticApproval(workspaceID: targetWorkspace, context: context, modifyingFiles: true)
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

            case "list_tasks":
                // A different ChatGPT session can discover existing task IDs
                // without guessing the last workspace or inheriting its binding.
                let workspaceID = try optionalUUID("workspaceId", in: arguments)
                if let workspaceID {
                    _ = try await workspaceManager.workspace(id: workspaceID)
                }
                return .object([
                    "codingTasks": try JSONValue.encoded(await codingTaskManager.list(workspaceID: workspaceID)),
                    "commands": try JSONValue.encoded(await commandSessionManager.list(workspaceID: workspaceID)),
                    "workflows": try JSONValue.encoded(await workflowSessionManager.list(workspaceID: workspaceID))
                ])

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
                        details: approvalDetails(name: name, arguments: arguments),
                        fallback: await automaticApproval(
                            workspaceID: targetWorkspace, context: context,
                            modifyingFiles: true, workflowCommands: commands
                        )
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
                        details: approvalDetails(name: name, arguments: arguments),
                        fallback: await automaticApproval(
                            workspaceID: taskStatus.workspaceID, context: context,
                            modifyingFiles: true,
                            workflowCommands: try await codingTaskManager.commands(taskID: taskID)
                        )
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
                        "coding_task action 仅支持 start/list/status/output/repair/cancel"
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
                let target = approvalTarget(name: name, arguments: arguments)
                let details = approvalDetails(name: name, arguments: arguments)
                var validatedScope: BridgeApprovalScope?
                if let workspace, let resolved = try? await workspaceManager.workspace(id: workspace) {
                    validatedScope = BridgeApprovalScope.make(
                        workspacePath: resolved.rootPath, tool: name, target: target, details: details
                    )
                }
                // Reject obviously invalid file targets before opening the
                // approval prompt. The mutation tool still revalidates paths.
                if ["edit", "write", "patch_file", "create_directory",
                    "move_path", "trash_path"].contains(name),
                   validatedScope == nil {
                    throw BridgeError.invalidPath(target ?? ".")
                }
                // Exact, repeatable build/test or process-inspection commands
                // can be remembered. Arbitrary shell, network, destructive
                // and Git commands remain strictly one-shot.
                let rememberScope = BridgeApprovalScope.mayRemember(
                    tool: name, details: details
                ) ? validatedScope : nil
                // This is reached only for an ask decision. Explicit denials
                // and workspace path validation still run on execution.
                if let rememberScope, approvalStore.hasRememberedApproval(rememberScope) {
                    return try await execute(name: name, arguments: arguments,
                        context: ToolExecutionContext(approvalGranted: true, sessionID: context.sessionID))
                }
                // Every invocation has its own decision. A deterministic
                // content fingerprint alone lets two identical concurrent
                // calls accidentally share or consume one approval.
                let requestID = BridgeApprovalStore.requestID(
                    tool: name,
                    workspaceID: workspace,
                    target: target,
                    details: details
                ) + "-" + UUID().uuidString
                approvalStore.request(
                    id: requestID,
                    tool: name,
                    summary: approvalDisplaySummary(name: name, arguments: arguments, fallback: operation),
                    target: target,
                    rememberScope: rememberScope,
                    actionDescription: BridgeApprovalPresentation.describe(tool: name, arguments: arguments)
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

        // An unrelated workspace must never be selected automatically.
        // If this session has no surviving binding, ask the client to open it.
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

    private func optionalUUID(_ key: String, in arguments: [String: JSONValue]) throws -> UUID? {
        guard let raw = arguments[key]?.stringValue else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw ToolRouterError.invalidArguments("参数 \(key) 必须是有效 UUID")
        }
        return value
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

    private func requiredInt(_ key: String, in arguments: [String: JSONValue]) throws -> Int {
        guard let value = try optionalInt(key, in: arguments) else {
            throw ToolRouterError.invalidArguments("缺少必填整数参数 \(key)")
        }
        return value
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
        // A decision belongs only to the suspended invocation in
        // waitForDecision. Never let a later call silently consume a previous
        // invocation's saved authorization by matching its command hash.
        return fallback
    }

    private func automaticApproval(
        workspaceID: UUID,
        context: ToolExecutionContext,
        modifyingFiles: Bool = false,
        command: CommandRequest? = nil,
        workflowCommands: [ProjectWorkflowCommand]? = nil
    ) async -> Bool {
        if context.approvalGranted { return true }
        guard let workspace = try? await workspaceManager.workspace(id: workspaceID) else { return false }
        if modifyingFiles && !trustedDevelopment.autoApprovesModification(in: workspace) {
            return false
        }
        if let command, !trustedDevelopment.autoApprovesCommand(command, in: workspace) {
            return false
        }
        if let workflowCommands {
            for step in workflowCommands {
                guard trustedDevelopment.autoApprovesCommand(CommandRequest(
                    executable: step.executable,
                    arguments: step.arguments,
                    workingDirectory: step.workingDirectory
                ), in: workspace) else {
                    return false
                }
            }
        }
        return modifyingFiles || command != nil || workflowCommands != nil
    }

    /// User-facing approval text is specific to the invocation. Do not show
    /// generic "execute project operation" labels or persist file contents in
    /// the approval record. Shell arguments are displayed in full so the
    /// user can distinguish two otherwise similar commands.
    private func approvalDisplaySummary(
        name: String,
        arguments: [String: JSONValue],
        fallback: String
    ) -> String {
        let path = arguments["path"]?.stringValue ?? "（未指定路径）"
        switch name {
        case "edit":
            let before = arguments["oldText"]?.stringValue?.utf8.count ?? 0
            let after = arguments["newText"]?.stringValue?.utf8.count ?? 0
            return "在 \(path) 精确替换 1 处文本（\(before) → \(after) 字节）"
        case "patch_file":
            let mode = arguments["mode"]?.stringValue ?? "old_new"
            if mode == "line_range",
               let start = arguments["startLine"]?.intValue,
               let end = arguments["endLine"]?.intValue {
                return "替换 \(path) 第 \(start)–\(end) 行"
            }
            return "对 \(path) 应用 \(mode) 补丁"
        case "write":
            let overwrite = arguments["overwrite"]?.boolValue ?? false
            let count = arguments["content"]?.stringValue?.utf8.count ?? 0
            return "\(overwrite ? "允许覆盖写入" : "创建文件")：\(path)（\(count) 字节）"
        case "create_directory":
            return "创建目录：\(path)"
        case "move_path":
            let destination = arguments["destination"]?.stringValue ?? "（未知目标）"
            return "移动：\(path) → \(destination)"
        case "trash_path":
            return "将 \(path) 移入回收站"
        case "restore_path":
            return "恢复回收站记录：\(arguments["trashId"]?.stringValue ?? "（未知 ID）")"
        case "bash", "run_command", "start_command":
            guard let executable = arguments["executable"]?.stringValue else { return fallback }
            let argv = (arguments["arguments"]?.arrayValue ?? []).compactMap(\.stringValue)
            return ([executable] + argv).map { arg in
                arg.rangeOfCharacter(from: .whitespacesAndNewlines) == nil
                    ? arg
                    : String(reflecting: arg)
            }.joined(separator: " ")
        case "start_workflow", "run_workflow":
            let tests = arguments["includeTests"]?.boolValue != false ? "是" : "否"
            let build = arguments["includeBuild"]?.boolValue != false ? "是" : "否"
            return "运行项目工作流（测试：\(tests)，构建：\(build)）"
        default:
            return fallback
        }
    }

    private func approvalTarget(name: String, arguments: [String: JSONValue]) -> String? {
        switch name {
        case "bash", "run_command", "start_command":
            return arguments["workingDirectory"]?.stringValue ?? "."
        case "create_directory", "move_path", "trash_path":
            return arguments["path"]?.stringValue
        case "restore_path":
            return arguments["trashId"]?.stringValue
        case "start_workflow", "run_workflow", "coding_task":
            return "."
        case "repair_project":
            return arguments["path"]?.stringValue ?? "."
        default:
            return arguments["path"]?.stringValue
        }
    }

    private func approvalDetails(name: String, arguments: [String: JSONValue]) -> [String] {
        switch name {
        case "create_directory", "move_path", "trash_path", "restore_path":
            return [arguments["path"]?.stringValue ?? "", arguments["destination"]?.stringValue ?? "", arguments["trashId"]?.stringValue ?? ""]
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
            // The approval must be tied to the exact patch, task ID, flags,
            // and every argument -- never only the list of file paths.
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let data = try? encoder.encode(arguments),
                  let canonical = String(data: data, encoding: .utf8) else {
                return ["invalid-request"]
            }
            return [canonical]
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
