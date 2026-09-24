import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Git service")
struct GitTests {
    @Test("diff and status return structured changed files")
    func diffAndStatus() async throws {
        let fixture = try GitFixture()
        defer { fixture.cleanup() }
        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [fixture.project]))
        let workspace = try await manager.open(path: fixture.project.path)
        let service = GitService()

        let diff = try service.getDiff(workspace: workspace)
        #expect(diff.diff.contains("+let value = 2"))
        let changed = try #require(diff.files.first)
        #expect(changed.path == "Sample.swift")
        #expect(changed.additions == 1)
        #expect(changed.deletions == 1)

        let status = try service.getStatus(workspace: workspace)
        #expect(status.isClean == false)
        #expect(status.entries.contains { $0.path == "Sample.swift" })
        #expect(try service.getChangedFiles(workspace: workspace).files.count == 1)
    }
}

private struct GitFixture {
    let root: URL
    let project: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborGitTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("Sample.swift")
        try Data("let value = 1\n".utf8).write(to: file)
        try run(["init"])
        try run(["config", "user.email", "tests@example.com"])
        try run(["config", "user.name", "Codex Harbor Tests"])
        try run(["add", "Sample.swift"])
        try run(["commit", "-m", "initial"])
        try Data("let value = 2\n".utf8).write(to: file)
    }

    private func run(_ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = project
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
