import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Workspace inspection")
struct WorkspaceInspectionTests {
    @Test("list_directory is structured, sorted, and hides hidden entries by default")
    func listDirectory() async throws {
        let fixture = try WorkspaceInspectionFixture()
        defer { fixture.cleanup() }

        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [fixture.root]))
        let workspace = try await manager.open(path: fixture.root.path)
        let tool = WorkspaceInspectionTool(workspaceManager: manager)

        let result = try await tool.listDirectory(workspaceID: workspace.id)
        #expect(result.path == ".")
        #expect(result.truncated == false)
        #expect(result.entries.map(\.name) == ["Sources", "README.md"])
        #expect(result.entries.first?.kind == .directory)
        #expect(result.entries.last?.kind == .file)
        #expect(result.entries.contains { $0.name == ".secret" } == false)

        let hidden = try await tool.listDirectory(
            workspaceID: workspace.id,
            includeHidden: true
        )
        #expect(hidden.entries.contains { $0.name == ".secret" })
    }

    @Test("workspace_tree bounds depth and does not recurse generated directories")
    func workspaceTree() async throws {
        let fixture = try WorkspaceInspectionFixture()
        defer { fixture.cleanup() }

        let generated = fixture.root.appendingPathComponent(".build/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        try Data("ignored".utf8).write(to: generated.appendingPathComponent("Huge.o"))

        let nested = fixture.root.appendingPathComponent("Sources/App/Feature", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try Data("struct Demo {}".utf8).write(to: nested.appendingPathComponent("Demo.swift"))

        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [fixture.root]))
        let workspace = try await manager.open(path: fixture.root.path)
        let tool = WorkspaceInspectionTool(workspaceManager: manager)

        let result = try await tool.workspaceTree(
            workspaceID: workspace.id,
            depth: 3,
            includeHidden: true
        )

        #expect(result.maxDepth == 3)
        #expect(result.entries.contains { $0.path == ".build" && $0.kind == .directory })
        #expect(result.entries.contains { $0.path.contains("Huge.o") } == false)
        #expect(result.entries.contains { $0.path == "Sources/App/Feature" })
        #expect(result.entries.contains { $0.path == "Sources/App/Feature/Demo.swift" } == false)
    }
}

private struct WorkspaceInspectionFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborWorkspaceInspection-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("# Demo\n".utf8).write(to: root.appendingPathComponent("README.md"))
        try Data("secret".utf8).write(to: root.appendingPathComponent(".secret"))
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
