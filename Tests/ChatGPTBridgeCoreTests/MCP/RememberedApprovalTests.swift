import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Remembered approvals")
struct RememberedApprovalTests {
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
        #expect(reloaded.hasRememberedApproval(anotherFile))
        let otherWorkspace = try #require(BridgeApprovalScope.make(workspacePath: root.appendingPathComponent("other").path, tool: "write", target: "a", details: []))
        #expect(!reloaded.hasRememberedApproval(otherWorkspace))
        let deletion = try #require(BridgeApprovalScope.make(workspacePath: root.path, tool: "trash_path", target: "a", details: []))
        #expect(!reloaded.hasRememberedApproval(deletion))
        store.request(id: "queued", tool: "edit", summary: "edit", rememberScope: anotherFile)
        #expect(store.pendingRequests().isEmpty)
        #expect(store.consumeDecision(id: "queued") == .granted)
        try reloaded.revokeRememberedApprovals()
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
        let scope = try #require(BridgeApprovalScope.make(workspacePath: project.path, tool: "write", target: "first.txt", details: []))
        store.request(id: "grant", tool: "write", summary: "write", rememberScope: scope)
        #expect(store.decide(id: "grant", allow: true, remember: true))
        let manager = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        let context = ToolExecutionContext(sessionID: "remember-test")
        let router = ToolRouter(workspaceManager: manager,
                                configuration: BridgeConfiguration(modificationPermission: .ask),
                                auditLogger: AuditLogger(paths: paths), approvalStore: store)
        _ = try await router.execute(name: "open_workspace", arguments: ["path": .string(project.path)], context: context)
        for filename in ["first.txt", "second.txt"] {
            _ = try await router.execute(name: "write", arguments: ["path": .string(filename), "content": .string("saved")], context: context)
            #expect(try String(contentsOf: project.appendingPathComponent(filename), encoding: .utf8) == "saved")
        }
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
