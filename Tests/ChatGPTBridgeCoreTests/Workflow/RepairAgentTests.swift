import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Repair agent")
struct RepairAgentTests {
    @Test("workflow stops at needsPatch with parsed Swift errors")
    func workflowState() async throws {
        let fixture = try await RepairFixture()
        defer { fixture.cleanup() }
        let result = try await fixture.agent.repair(
            workspaceID: fixture.workspaceID,
            timeoutSeconds: 60
        )
        #expect(result.state == .needsPatch)
        #expect(result.test.exitCode != 0)
        #expect(result.errors.contains { $0.file.hasSuffix("Broken.swift") })
        #expect(result.steps.map(\.state) == [.inspecting, .testing, .needsPatch])
    }
}

private struct RepairFixture {
    let root: URL
    let workspaceID: UUID
    let agent: RepairAgent

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborRepairTests-\(UUID().uuidString)", isDirectory: true)
        let sources = root.appendingPathComponent("Sources/Broken", isDirectory: true)
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        try Data("""
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(name: "Broken", targets: [.executableTarget(name: "Broken")])
        """.utf8).write(to: root.appendingPathComponent("Package.swift"))
        try Data("let value: Int = missingSymbol\nprint(value)\n".utf8)
            .write(to: sources.appendingPathComponent("Broken.swift"))
        try Self.runGit(["init"], at: root)

        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        workspaceID = try await manager.open(path: root.path).id
        let permission = PermissionEngine(configuration: BridgeConfiguration(
            modificationPermission: .allow,
            shellPermission: .safeOnly
        ))
        let audit = AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        let patch = PatchFileTool(
            workspaceManager: manager,
            permissionEngine: permission,
            auditLogger: audit
        )
        let command = CommandService(shellTool: ShellTool(
            workspaceManager: manager,
            permissionEngine: permission,
            auditLogger: audit
        ))
        agent = RepairAgent(
            workspaceManager: manager,
            gitService: GitService(),
            commandService: command,
            patchTool: patch
        )
    }

    private static func runGit(_ arguments: [String], at directory: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = directory
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw BridgeError.gitFailed(arguments.joined(separator: " "))
        }
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
