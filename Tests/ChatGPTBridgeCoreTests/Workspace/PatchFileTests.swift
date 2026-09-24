import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Patch file")
struct PatchFileTests {
    @Test("old_new, line_range, and unified_diff produce real diffs")
    func patchModes() async throws {
        let fixture = try await PatchFixture()
        defer { fixture.cleanup() }
        let tool = fixture.tool

        let first = try await tool.execute(
            workspaceID: fixture.workspaceID,
            path: "Sample.swift",
            oldText: "first = 1",
            newText: "first = 10"
        )
        #expect(first.success)
        #expect(first.mode == "old_new")
        #expect(first.diff.contains("@@"))
        #expect(first.diff.contains("-let first = 1"))
        #expect(first.diff.contains("+let first = 10"))

        let second = try await tool.execute(
            workspaceID: fixture.workspaceID,
            path: "Sample.swift",
            mode: "line_range",
            startLine: 2,
            endLine: 2,
            content: "let second = 20"
        )
        #expect(second.mode == "line_range")
        #expect(second.diff.contains("-let second = 2"))
        #expect(second.diff.contains("+let second = 20"))

        let unified = """
        --- a/Sample.swift
        +++ b/Sample.swift
        @@ -1,2 +1,2 @@
         let first = 10
        -let second = 20
        +let second = 30
        """
        let third = try await tool.execute(
            workspaceID: fixture.workspaceID,
            path: "Sample.swift",
            mode: "unified_diff",
            patch: unified
        )
        #expect(third.mode == "unified_diff")
        #expect(third.diff.contains("@@ -1,2 +1,2 @@"))
        #expect(try String(contentsOf: fixture.file, encoding: .utf8) == "let first = 10\nlet second = 30\n")
    }

    @Test("unified diff rejects context mismatch without changing the file")
    func contextMismatch() async throws {
        let fixture = try await PatchFixture()
        defer { fixture.cleanup() }
        let before = try Data(contentsOf: fixture.file)
        let patch = """
        --- a/Sample.swift
        +++ b/Sample.swift
        @@ -1,2 +1,2 @@
         let first = 999
        -let second = 2
        +let second = 3
        """

        await #expect(throws: BridgeError.self) {
            _ = try await fixture.tool.execute(
                workspaceID: fixture.workspaceID,
                path: "Sample.swift",
                mode: "unified_diff",
                patch: patch
            )
        }
        #expect(try Data(contentsOf: fixture.file) == before)
    }

    @Test("patch rejects workspace path escape")
    func pathEscape() async throws {
        let fixture = try await PatchFixture()
        defer { fixture.cleanup() }
        let outside = fixture.root.appendingPathComponent("Outside.swift")
        try Data("let outside = true\n".utf8).write(to: outside)

        await #expect(throws: BridgeError.self) {
            _ = try await fixture.tool.execute(
                workspaceID: fixture.workspaceID,
                path: "../Outside.swift",
                oldText: "true",
                newText: "false"
            )
        }
        #expect(try String(contentsOf: outside, encoding: .utf8) == "let outside = true\n")
    }
}

private struct PatchFixture {
    let root: URL
    let project: URL
    let file: URL
    let workspaceID: UUID
    let tool: PatchFileTool

    init() async throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborPatchTests-\(UUID().uuidString)", isDirectory: true)
        project = root.appendingPathComponent("Project", isDirectory: true)
        file = project.appendingPathComponent("Sample.swift")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let first = 1\nlet second = 2\n".utf8).write(to: file)
        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        workspaceID = try await workspaces.open(path: project.path).id
        tool = PatchFileTool(
            workspaceManager: workspaces,
            permissionEngine: PermissionEngine(configuration: BridgeConfiguration(modificationPermission: .allow)),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
