import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Command service")
struct CommandTests {
    @Test("run_command returns standardized output")
    func runCommand() async throws {
        let fixture = try await CommandFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.service.run(
            workspaceID: fixture.workspaceID,
            executable: "printf",
            arguments: ["hello"]
        )
        #expect(result.exitCode == 0)
        #expect(result.stdout == "hello")
        #expect(result.stderr.isEmpty)
        #expect(result.durationMilliseconds >= 0)
        #expect(result.errors.isEmpty)
    }

    @Test("run_command enforces timeout")
    func timeout() async throws {
        let fixture = try await CommandFixture()
        defer { fixture.cleanup() }
        await #expect(throws: BridgeError.self) {
            _ = try await fixture.service.run(
                workspaceID: fixture.workspaceID,
                executable: "sleep",
                arguments: ["5"],
                timeoutSeconds: 1
            )
        }
    }

    @Test("Swift build errors are parsed into locations")
    func errorParser() throws {
        let output = "/tmp/Project/Sources/Test.swift:120:15: error: cannot find 'missing' in scope\n"
        let errors = BuildErrorParser().parse(output)
        let error = try #require(errors.first)
        #expect(error.file == "/tmp/Project/Sources/Test.swift")
        #expect(error.line == 120)
        #expect(error.column == 15)
        #expect(error.message == "cannot find 'missing' in scope")
    }
}

private struct CommandFixture {
    let root: URL
    let workspaceID: UUID
    let service: CommandService

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        workspaceID = try await manager.open(path: root.path).id
        let shell = ShellTool(
            workspaceManager: manager,
            permissionEngine: PermissionEngine(configuration: BridgeConfiguration(shellPermission: .allow)),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        )
        service = CommandService(shellTool: shell)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
