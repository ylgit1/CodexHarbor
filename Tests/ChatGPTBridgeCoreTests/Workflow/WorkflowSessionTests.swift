import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Workflow sessions")
struct WorkflowSessionTests {
    @Test("workflow runs commands sequentially and exposes current step output")
    func sequentialExecution() async throws {
        let fixture = try await WorkflowSessionFixture()
        defer { fixture.cleanup() }

        let plan = ProjectWorkflowPlan(
            kind: .swiftPackage,
            commands: [
                ProjectWorkflowCommand(
                    name: "First",
                    executable: "zsh",
                    arguments: ["-c", "printf first"]
                ),
                ProjectWorkflowCommand(
                    name: "Second",
                    executable: "zsh",
                    arguments: ["-c", "printf second"]
                )
            ],
            message: "test workflow"
        )

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            plan: plan,
            timeoutSeconds: 5,
            approvalGranted: true
        )
        #expect(started.state == .planned)

        let terminal = try await waitForTerminal(
            manager: fixture.manager,
            workflowID: started.workflowID
        )
        #expect(terminal.state == .completed)
        #expect(terminal.steps.map(\.state) == [.completed, .completed])
        #expect(terminal.currentStepIndex == 1)

        let output = try await fixture.manager.output(workflowID: started.workflowID)
        #expect(output.currentStepName == "Second")
        #expect(output.stdout.contains("second"))
    }

    @Test("cancelling workflow cancels current command and prevents later steps")
    func cancellation() async throws {
        let fixture = try await WorkflowSessionFixture()
        defer { fixture.cleanup() }

        let plan = ProjectWorkflowPlan(
            kind: .node,
            commands: [
                ProjectWorkflowCommand(
                    name: "Long",
                    executable: "sleep",
                    arguments: ["5"]
                ),
                ProjectWorkflowCommand(
                    name: "Never",
                    executable: "printf",
                    arguments: ["never"]
                )
            ],
            message: "cancel workflow"
        )

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            plan: plan,
            timeoutSeconds: 10,
            approvalGranted: true
        )
        try await waitForRunningStep(
            manager: fixture.manager,
            workflowID: started.workflowID
        )

        let cancelled = try await fixture.manager.cancel(workflowID: started.workflowID)
        #expect(cancelled.state == .cancelled)
        #expect(cancelled.steps[0].state == .cancelled)
        #expect(cancelled.steps[1].state == .pending)
        #expect(cancelled.steps[1].commandID == nil)
    }

    @Test("command timeout propagates to workflow")
    func timeout() async throws {
        let fixture = try await WorkflowSessionFixture()
        defer { fixture.cleanup() }

        let plan = ProjectWorkflowPlan(
            kind: .python,
            commands: [
                ProjectWorkflowCommand(
                    name: "Timeout",
                    executable: "sleep",
                    arguments: ["5"]
                )
            ],
            message: "timeout workflow"
        )

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            plan: plan,
            timeoutSeconds: 1,
            approvalGranted: true
        )
        let terminal = try await waitForTerminal(
            manager: fixture.manager,
            workflowID: started.workflowID,
            attempts: 40
        )
        #expect(terminal.state == .timedOut)
        #expect(terminal.steps.first?.state == .timedOut)
    }

    private func waitForRunningStep(
        manager: WorkflowSessionManager,
        workflowID: UUID,
        attempts: Int = 30
    ) async throws {
        for _ in 0..<attempts {
            let status = try await manager.status(workflowID: workflowID)
            if status.state == .running,
               status.currentStepIndex != nil,
               status.steps.contains(where: { $0.state == .running }) {
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("workflow did not start a command")
    }

    private func waitForTerminal(
        manager: WorkflowSessionManager,
        workflowID: UUID,
        attempts: Int = 50
    ) async throws -> WorkflowSessionStatus {
        for _ in 0..<attempts {
            let status = try await manager.status(workflowID: workflowID)
            if ![.planned, .running].contains(status.state) {
                return status
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("workflow did not reach a terminal state")
        return try await manager.status(workflowID: workflowID)
    }
}

private struct WorkflowSessionFixture {
    let root: URL
    let workspaceID: UUID
    let manager: WorkflowSessionManager

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborWorkflowSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        workspaceID = try await workspaces.open(path: root.path).id
        let audit = AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        let permissions = PermissionEngine(
            configuration: BridgeConfiguration(shellPermission: .allow)
        )
        let shell = ShellTool(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        )
        let commandService = CommandService(shellTool: shell)
        let commandSessions = CommandSessionManager(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        )
        let workflowAgent = ProjectWorkflowAgent(
            workspaceManager: workspaces,
            commandService: commandService
        )
        manager = WorkflowSessionManager(
            workflowAgent: workflowAgent,
            commandSessionManager: commandSessions,
            auditLogger: audit
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
