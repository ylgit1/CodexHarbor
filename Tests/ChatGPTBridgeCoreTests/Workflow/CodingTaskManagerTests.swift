import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Coding Task")
struct CodingTaskManagerTests {
    @Test("task applies changes then verifies, builds, and packages under one task ID")
    func completesFullLifecycle() async throws {
        let fixture = try await CodingTaskFixture()
        defer { fixture.cleanup() }

        let plan = ProjectWorkflowPlan(
            kind: .swiftPackage,
            commands: [
                ProjectWorkflowCommand(
                    name: "Tests",
                    executable: "zsh",
                    arguments: ["-c", "grep -q changed README.md"]
                ),
                ProjectWorkflowCommand(
                    name: "Build",
                    executable: "zsh",
                    arguments: ["-c", "printf build"]
                )
            ],
            message: "coding task test"
        )
        let package = ProjectWorkflowCommand(
            name: "Package",
            executable: "zsh",
            arguments: ["-c", "printf package"]
        )

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            requirement: "change the demo and verify it",
            changes: [
                CodingTaskChange(
                    path: "README.md",
                    oldText: "demo",
                    newText: "changed"
                )
            ],
            plan: plan,
            packageCommand: package,
            timeoutSeconds: 5,
            maximumRepairAttempts: 1,
            approvalGranted: true
        )
        let taskID = started.taskID

        let terminal = try await waitForState(
            manager: fixture.manager,
            taskID: taskID,
            states: [.completed, .failed, .timedOut]
        )
        #expect(terminal.taskID == taskID)
        #expect(terminal.state == .completed)
        #expect(terminal.appliedChanges == ["README.md"])
        #expect(terminal.changedFiles.contains { $0.path == "README.md" })
        #expect(terminal.steps.map(\.state) == [.completed, .completed, .completed])

        let output = try await fixture.manager.output(taskID: taskID)
        #expect(output.stdout.contains("package"))
    }

    @Test("unsupported task does not apply changes without a verification workflow")
    func unsupportedDoesNotMutate() async throws {
        let fixture = try await CodingTaskFixture()
        defer { fixture.cleanup() }

        let result = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            requirement: "do not modify without verification",
            changes: [
                CodingTaskChange(
                    path: "README.md",
                    oldText: "demo",
                    newText: "should-not-appear"
                )
            ],
            plan: ProjectWorkflowPlan(
                kind: .unknown,
                commands: [],
                message: "unsupported"
            ),
            packageCommand: nil,
            approvalGranted: true
        )

        #expect(result.state == .unsupported)
        let text = try String(
            contentsOf: fixture.root.appendingPathComponent("README.md"),
            encoding: .utf8
        )
        #expect(text == "demo\n")
    }

    @Test("failed verification enters needsRepair and repair continues the same task")
    func repairLoop() async throws {
        let fixture = try await CodingTaskFixture()
        defer { fixture.cleanup() }

        let plan = ProjectWorkflowPlan(
            kind: .swiftPackage,
            commands: [
                ProjectWorkflowCommand(
                    name: "Tests",
                    executable: "zsh",
                    arguments: ["-c", "grep -q fixed README.md"]
                ),
                ProjectWorkflowCommand(
                    name: "Build",
                    executable: "zsh",
                    arguments: ["-c", "printf build"]
                )
            ],
            message: "repair test"
        )

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            requirement: "make README satisfy verification",
            changes: [
                CodingTaskChange(
                    path: "README.md",
                    oldText: "demo",
                    newText: "broken"
                )
            ],
            plan: plan,
            packageCommand: nil,
            timeoutSeconds: 5,
            maximumRepairAttempts: 1,
            approvalGranted: true
        )

        let needsRepair = try await waitForState(
            manager: fixture.manager,
            taskID: started.taskID,
            states: [.needsRepair, .failed]
        )
        #expect(needsRepair.state == .needsRepair)
        #expect(needsRepair.repairAttempt == 0)

        let repairing = try await fixture.manager.repair(
            taskID: started.taskID,
            changes: [
                CodingTaskChange(
                    path: "README.md",
                    oldText: "broken",
                    newText: "fixed"
                )
            ],
            approvalGranted: true
        )
        #expect(repairing.taskID == started.taskID)
        #expect(repairing.repairAttempt == 1)

        let terminal = try await waitForState(
            manager: fixture.manager,
            taskID: started.taskID,
            states: [.completed, .failed, .timedOut]
        )
        #expect(terminal.state == .completed)
        #expect(terminal.repairAttempt == 1)
        #expect(terminal.steps.map(\.state) == [.completed, .completed])
    }

    private func waitForState(
        manager: CodingTaskManager,
        taskID: UUID,
        states: Set<CodingTaskState>,
        attempts: Int = 80
    ) async throws -> CodingTaskResponse {
        for _ in 0..<attempts {
            let status = try await manager.status(taskID: taskID)
            if states.contains(status.state) {
                return status
            }
            try await Task.sleep(for: .milliseconds(75))
        }
        Issue.record("Coding Task did not reach expected state")
        return try await manager.status(taskID: taskID)
    }
}

private struct CodingTaskFixture {
    let root: URL
    let workspaceID: UUID
    let manager: CodingTaskManager

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborCodingTask-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("demo\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Self.initializeGit(at: root)

        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        workspaceID = try await workspaces.open(path: root.path).id
        let audit = AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        let permissions = PermissionEngine(
            configuration: BridgeConfiguration(
                modificationPermission: .allow,
                shellPermission: .allow,
                gitPushPermission: .allow
            )
        )
        let patchTool = PatchFileTool(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        )
        let commandSessions = CommandSessionManager(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        )
        manager = CodingTaskManager(
            workspaceManager: workspaces,
            patchTool: patchTool,
            gitService: GitService(),
            commandSessionManager: commandSessions,
            auditLogger: audit
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }

    private static func initializeGit(at root: URL) throws {
        for arguments in [
            ["init"],
            ["config", "user.email", "tests@example.com"],
            ["config", "user.name", "Codex Harbor Tests"],
            ["add", "README.md"],
            ["commit", "-m", "initial"]
        ] {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = ["git"] + arguments
            process.currentDirectoryURL = root
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw BridgeError.gitFailed(arguments.joined(separator: " "))
            }
        }
    }
}
