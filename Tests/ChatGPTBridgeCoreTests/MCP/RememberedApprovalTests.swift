import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Remembered approvals")
struct RememberedApprovalTests {
    @Test("Same-argument build and inspection commands can be remembered; dangerous tools cannot")
    func persistentApprovalAllowlist() {
        for tool in ["bash", "move_path", "trash_path", "restore_path", "git_push", "coding_task"] {
            #expect(!BridgeApprovalScope.mayRemember(tool: tool, details: ["swift", "test"]))
        }
        for tool in ["edit", "write", "patch_file", "create_directory"] {
            #expect(BridgeApprovalScope.mayRemember(tool: tool))
        }
        for tool in ["run_command", "start_command"] {
            #expect(BridgeApprovalScope.mayRemember(tool: tool, details: ["swift", "test"]))
            #expect(BridgeApprovalScope.mayRemember(tool: tool, details: ["ps", "-axo"]))
            #expect(BridgeApprovalScope.mayRemember(tool: tool, details: ["npm", "run", "build"]))
            #expect(!BridgeApprovalScope.mayRemember(tool: tool, details: ["curl", "https://example.com"]))
            #expect(!BridgeApprovalScope.mayRemember(tool: tool, details: ["git", "push"]))
            #expect(!BridgeApprovalScope.mayRemember(tool: tool, details: ["sh", "-c", "echo hello"]))
            #expect(!BridgeApprovalScope.mayRemember(tool: tool, details: ["swift", "package", "reset"]))
            #expect(!BridgeApprovalScope.mayRemember(tool: tool))
        }
        let project = "/tmp/project"
        let same = BridgeApprovalScope.make(
            workspacePath: project, tool: "run_command",
            target: ".", details: ["swift", "test"]
        )
        let different = BridgeApprovalScope.make(
            workspacePath: project, tool: "run_command",
            target: ".", details: ["swift", "test", "--filter", "SecretTests"]
        )
        #expect(same != different)
    }

    @Test("Identical requests from two sessions receive independent approvals")
    func concurrentIdenticalRequests() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-approval-concurrency-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let project = base.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = BridgePaths(root: base.appendingPathComponent("bridge"))
        let store = BridgeApprovalStore(paths: paths)
        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        let router = ToolRouter(
            workspaceManager: manager,
            configuration: BridgeConfiguration(modificationPermission: .ask),
            auditLogger: AuditLogger(paths: paths),
            approvalStore: store
        )
        let first = ToolExecutionContext(sessionID: "approval-A")
        let second = ToolExecutionContext(sessionID: "approval-B")
        for context in [first, second] {
            _ = try await router.execute(
                name: "open_workspace", arguments: ["path": .string(project.path)],
                context: context
            )
        }
        let args: [String: JSONValue] = [
            "path": .string("same-file.txt"), "content": .string("not allowed")
        ]
        let a = Task { try? await router.execute(name: "write", arguments: args, context: first) }
        let b = Task { try? await router.execute(name: "write", arguments: args, context: second) }
        defer { a.cancel(); b.cancel() }

        var ids: [String] = []
        for _ in 0..<40 {
            ids = store.pendingRequests().map(\.id)
            if ids.count == 2 { break }
            try? await Task.sleep(for: .milliseconds(50))
        }
        #expect(ids.count == 2)
        #expect(Set(ids).count == 2)
        for id in ids {
            #expect(store.decide(id: id, allow: false))
        }
        let firstResult = await a.value
        let secondResult = await b.value
        #expect(firstResult == nil)
        #expect(secondResult == nil)
        #expect(!FileManager.default.fileExists(
            atPath: project.appendingPathComponent("same-file.txt").path
        ))
    }

    @Test("Countdown shares the expiry deadline and never becomes negative")
    func countdown() {
        let start = Date(timeIntervalSince1970: 100)
        let legacy = BridgeApprovalRequest(id: "a", tool: "write", summary: "write", createdAt: start)
        #expect(legacy.remainingSeconds(at: start) == 90)
        #expect(legacy.remainingSeconds(at: start.addingTimeInterval(89.2)) == 1)
        #expect(legacy.remainingSeconds(at: start.addingTimeInterval(91)) == 0)
        let short = BridgeApprovalRequest(id: "b", tool: "write", summary: "write",
                                         createdAt: start, expiresAt: start.addingTimeInterval(5))
        #expect(short.remainingSeconds(at: start) == 5)
    }

    @Test("Remembered approval survives store restart, stays scoped and can be revoked")
    func persistence() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BridgePaths(root: root)
        let store = BridgeApprovalStore(paths: paths)
        let scope = try #require(BridgeApprovalScope.make(workspacePath: root.path, tool: "write", target: "a", details: []))
        store.request(id: "one", tool: "write", summary: "write", rememberScope: scope)
        #expect(store.decide(id: "one", allow: true, remember: true))
        let reloaded = BridgeApprovalStore(paths: paths)
        #expect(reloaded.hasRememberedApproval(scope))
        let anotherFile = try #require(BridgeApprovalScope.make(workspacePath: root.path, tool: "edit", target: "b", details: []))
        #expect(!reloaded.hasRememberedApproval(anotherFile))
        let sameTargetDifferentTool = try #require(BridgeApprovalScope.make(
            workspacePath: root.path, tool: "edit", target: "a", details: []
        ))
        #expect(!reloaded.hasRememberedApproval(sameTargetDifferentTool))
        let sameToolDifferentPayload = try #require(BridgeApprovalScope.make(
            workspacePath: root.path, tool: "write", target: "a", details: ["different content"]
        ))
        #expect(!reloaded.hasRememberedApproval(sameToolDifferentPayload))
        let otherWorkspace = try #require(BridgeApprovalScope.make(workspacePath: root.appendingPathComponent("other").path, tool: "write", target: "a", details: []))
        #expect(!reloaded.hasRememberedApproval(otherWorkspace))
        let deletion = try #require(BridgeApprovalScope.make(workspacePath: root.path, tool: "trash_path", target: "a", details: []))
        #expect(!reloaded.hasRememberedApproval(deletion))
        store.request(id: "queued", tool: "edit", summary: "edit", rememberScope: anotherFile)
        #expect(store.pendingRequests().map(\.id) == ["queued"])
        #expect(store.consumeDecision(id: "queued") == nil)
        try reloaded.revokeRememberedApprovals()
        #expect(!store.hasRememberedApproval(scope))
    }

    @Test("File grants never cover another path, tool or payload")
    func narrowFileScopes() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        func scope(_ tool: String, _ target: String, _ details: [String]) throws -> BridgeApprovalScope {
            try #require(BridgeApprovalScope.make(
                workspacePath: root.path, tool: tool, target: target, details: details
            ))
        }
        let a = try scope("write", "a.txt", ["create", "abc"])
        let differentFile = try scope("write", "b.txt", ["create", "abc"])
        let differentTool = try scope("edit", "a.txt", ["create", "abc"])
        let differentPayload = try scope("write", "a.txt", ["create", "changed"])
        #expect(a != differentFile)
        #expect(a != differentTool)
        #expect(a != differentPayload)
        #expect(BridgeApprovalScope.make(workspacePath: root.path, tool: "write", target: "..", details: []) == nil)
        #expect(BridgeApprovalScope.make(workspacePath: root.path, tool: "write", target: "../escape", details: []) == nil)
        #expect(BridgeApprovalScope.make(workspacePath: root.path, tool: "write", target: ".", details: []) == nil)
        #expect(BridgeApprovalScope.make(workspacePath: root.path, tool: "write", target: "", details: []) == nil)
    }

    @Test("Remembered grants expire and legacy unlimited grants are ignored")
    func rememberedRuleExpiration() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BridgeApprovalStore(paths: BridgePaths(root: root))
        let scope = try #require(BridgeApprovalScope.make(
            workspacePath: root.path, tool: "write", target: "hello.txt", details: ["create", "hi"]
        ))
        store.request(id: "short-lived", tool: "write", summary: "write", rememberScope: scope)
        #expect(store.decide(id: "short-lived", allow: true, remember: true))
        #expect(store.hasRememberedApproval(scope))
        let ruleFile = root.appendingPathComponent("approval-rules/\(scope.id).json")
        let expired = BridgeRememberedApprovalRule(
            scope: scope, expiresAt: Date().addingTimeInterval(-1), grantedAt: Date().addingTimeInterval(-3600)
        )
        try JSONEncoder().encode(expired).write(to: ruleFile)
        #expect(!store.hasRememberedApproval(scope))
        // Old saved JSON files without expiration must not silently survive.
        try JSONEncoder().encode(scope).write(to: ruleFile)
        #expect(!store.hasRememberedApproval(scope))
    }

    @Test("Program authorization binds exact arguments and working directory")
    func commandScope() throws {
        func scope(_ args: [String], _ target: String = ".", tool: String = "run_command") throws -> BridgeApprovalScope {
            try #require(BridgeApprovalScope.make(workspacePath: "/tmp/project", tool: tool, target: target, details: args))
        }
        let test = try scope(["swift", "test"])
        let alias = try scope(["swift", "test"], tool: "bash")
        let build = try scope(["swift", "build"])
        let subproject = try scope(["swift", "test"], "subproject")
        let oneArgument = try scope(["echo", "a b"])
        let twoArguments = try scope(["echo", "a", "b"])
        #expect(test == alias)
        #expect(test != build)
        #expect(test != subproject)
        #expect(oneArgument.id != twoArguments.id)
    }

    @Test("Expired and single-use approvals cannot create persistent grants")
    func expiredAndSingleUse() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BridgePaths(root: root)
        let scope = try #require(BridgeApprovalScope.make(workspacePath: root.path, tool: "write", target: "a", details: []))
        let expired = BridgeApprovalStore(paths: paths, ttl: 0)
        expired.request(id: "expired", tool: "write", summary: "write", rememberScope: scope)
        #expect(!expired.decide(id: "expired", allow: true, remember: true))
        #expect(!expired.hasRememberedApproval(scope))
        let store = BridgeApprovalStore(paths: paths)
        store.request(id: "once", tool: "write", summary: "write", rememberScope: scope)
        #expect(store.decide(id: "once", allow: true))
        #expect(!store.hasRememberedApproval(scope))
        #expect(store.consumeDecision(id: "once") == .granted)
        #expect(store.consumeDecision(id: "once") == nil)
    }

    @Test("Router reuses file grants while explicit denial and path limits still apply")
    func routerIntegration() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = BridgePaths(root: root.appendingPathComponent("bridge"))
        let store = BridgeApprovalStore(paths: paths)
        let scope = try #require(BridgeApprovalScope.make(workspacePath: project.path, tool: "write", target: "first.txt", details: ["create", "saved"]))
        store.request(id: "grant", tool: "write", summary: "write", rememberScope: scope)
        #expect(store.decide(id: "grant", allow: true, remember: true))
        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        let context = ToolExecutionContext(sessionID: "remember-test")
        let router = ToolRouter(workspaceManager: manager,
                                configuration: BridgeConfiguration(modificationPermission: .ask),
                                auditLogger: AuditLogger(paths: paths), approvalStore: store)
        _ = try await router.execute(name: "open_workspace", arguments: ["path": .string(project.path)], context: context)
        _ = try await router.execute(name: "write", arguments: [
            "path": .string("first.txt"), "content": .string("saved")
        ], context: context)
        #expect(try String(contentsOf: project.appendingPathComponent("first.txt"), encoding: .utf8) == "saved")
        let otherScope = try #require(BridgeApprovalScope.make(
            workspacePath: project.path, tool: "write", target: "second.txt",
            details: ["create", "saved"]
        ))
        #expect(!store.hasRememberedApproval(otherScope))
        #expect(store.pendingRequests().isEmpty)
        await #expect(throws: Error.self) {
            _ = try await router.execute(name: "write", arguments: ["path": .string("../escape.txt"), "content": .string("no")], context: context)
        }
        let denied = ToolRouter(workspaceManager: manager,
                                configuration: BridgeConfiguration(modificationPermission: .deny),
                                auditLogger: AuditLogger(paths: paths), approvalStore: store)
        await #expect(throws: Error.self) {
            _ = try await denied.execute(name: "write", arguments: ["path": .string("denied.txt"), "content": .string("no")], context: context)
        }
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("denied.txt").path))
    }
}
