import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Command sessions")
struct CommandSessionTests {
    @Test("long-running command exposes incremental output and completes")
    func incrementalOutput() async throws {
        let fixture = try await CommandSessionFixture()
        defer { fixture.cleanup() }

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            executable: "zsh",
            arguments: ["-c", "printf first; sleep 1; printf second"],
            timeoutSeconds: 5,
            approvalGranted: true
        )
        #expect(started.state == .running)

        try await Task.sleep(for: .milliseconds(250))
        let first = try await fixture.manager.output(commandID: started.commandID)
        #expect(first.stdout.contains("first"))
        #expect(first.nextStdoutOffset >= 5)

        let terminal = try await waitForTerminal(
            manager: fixture.manager,
            commandID: started.commandID
        )
        #expect(terminal.state == .completed)
        #expect(terminal.exitCode == 0)

        let second = try await fixture.manager.output(
            commandID: started.commandID,
            stdoutOffset: first.nextStdoutOffset
        )
        #expect((first.stdout + second.stdout).contains("second"))
    }

    @Test("running command can be cancelled without killing unrelated processes")
    func cancel() async throws {
        let fixture = try await CommandSessionFixture()
        defer { fixture.cleanup() }

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            executable: "sleep",
            arguments: ["5"],
            timeoutSeconds: 10,
            approvalGranted: true
        )
        let cancelled = try await fixture.manager.cancel(commandID: started.commandID)
        #expect(cancelled.state == .cancelled)

        let status = try await fixture.manager.status(commandID: started.commandID)
        #expect(status.state == .cancelled)
    }

    @Test("long-running command transitions to timedOut")
    func timeout() async throws {
        let fixture = try await CommandSessionFixture()
        defer { fixture.cleanup() }

        let started = try await fixture.manager.start(
            workspaceID: fixture.workspaceID,
            executable: "sleep",
            arguments: ["5"],
            timeoutSeconds: 1,
            approvalGranted: true
        )
        let terminal = try await waitForTerminal(
            manager: fixture.manager,
            commandID: started.commandID,
            attempts: 30
        )
        #expect(terminal.state == .timedOut)
    }

    private func waitForTerminal(
        manager: CommandSessionManager,
        commandID: UUID,
        attempts: Int = 40
    ) async throws -> CommandSessionStatus {
        for _ in 0..<attempts {
            let status = try await manager.status(commandID: commandID)
            if status.state != .running {
                return status
            }
            try await Task.sleep(for: .milliseconds(100))
        }
        Issue.record("command did not reach a terminal state")
        return try await manager.status(commandID: commandID)
    }
}

private struct CommandSessionFixture {
    let root: URL
    let workspaceID: UUID
    let manager: CommandSessionManager

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborCommandSession-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        workspaceID = try await workspaces.open(path: root.path).id
        let paths = BridgePaths(root: root.appendingPathComponent("Bridge", isDirectory: true))
        manager = CommandSessionManager(
            workspaceManager: workspaces,
            permissionEngine: PermissionEngine(
                configuration: BridgeConfiguration(shellPermission: .allow)
            ),
            auditLogger: AuditLogger(paths: paths)
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
