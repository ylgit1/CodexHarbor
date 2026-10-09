import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("UI automation MCP fail-closed routing")
struct UIAutomationRouterTests {
    @Test("All UI entrypoints refuse reading/control/capture without a local grant")
    func refusesWithoutLocalGrant() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-ui-router-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BridgePaths(root: root)
        try paths.ensureDirectories()
        let workspace = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(
                allowedRoots: AllowedRootsManager(roots: [workspace])
            ),
            configuration: BridgeConfiguration(),
            auditLogger: AuditLogger(paths: paths),
            uiAutomationPaths: paths
        )
        let arguments: [String: JSONValue] = [
            "bundleID": .string("com.example.unapproved"),
            "windowIndex": .number(0),
            "windowTitle": .string("Window"),
            "titleContains": .string("Window"),
            "elementID": .string("0/1"),
            "expectedLabel": .string("Refresh"),
            "operation": .string("click"),
            "containsText": .string("Complete"),
            "timeoutSeconds": .number(1)
        ]
        for tool in ["ui_open_app", "ui_windows", "ui_inspect",
                     "ui_perform", "ui_capture", "ui_wait", "ui_wait_window"] {
            var denied = false
            do {
                _ = try await router.execute(
                    name: tool, arguments: arguments,
                    context: ToolExecutionContext(approvalGranted: true)
                )
            } catch let error as BridgeError {
                if case .permissionDenied = error { denied = true }
            }
            #expect(denied, "\(tool) must not bypass local UI grants")
        }
    }

    @Test("Missing grant requests the exact app; MCP approval alone cannot grant access")
    func onDemandApprovalFailClosed() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-ui-prompt-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BridgePaths(root: root)
        try paths.ensureDirectories()
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let approvals = BridgeApprovalStore(paths: paths)
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(
                allowedRoots: AllowedRootsManager(roots: [workspace])
            ),
            configuration: BridgeConfiguration(),
            auditLogger: AuditLogger(paths: paths),
            approvalStore: approvals,
            uiAutomationPaths: paths
        )
        let call = Task { () -> Bool in
            do {
                _ = try await router.execute(
                    name: "ui_windows",
                    arguments: ["bundleID": .string("com.example.target")]
                )
                return false
            } catch let error as BridgeError {
                if case .permissionDenied = error { return true }
                return false
            } catch { return false }
        }
        defer { call.cancel() }
        var pending: [BridgeApprovalRequest] = []
        for _ in 0..<50 {
            pending = approvals.pendingRequests()
            if !pending.isEmpty { break }
            try await Task.sleep(for: .milliseconds(100))
        }
        let request = try #require(pending.first)
        #expect(pending.count == 1)
        #expect(request.tool == "ui_authorize_read")
        #expect(request.target == "com.example.target")
        #expect(!HarborUIConsentStore(paths: paths).allows(
            bundleID: "com.example.target", capability: .read
        ))
        // Simulate a forged/accidental generic approval that did NOT go
        // through the local per-app panel. Router must still refuse.
        #expect(approvals.decide(id: request.id, allow: true))
        #expect(await call.value)
        #expect(!HarborUIConsentStore(paths: paths).allows(
            bundleID: "com.example.target", capability: .read
        ))
    }

    @Test("A UI test without an observable postcondition executes nothing")
    func requiresObservablePostcondition() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-ui-empty-expect-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let service = await HarborUIAutomationService(paths: BridgePaths(root: root))
        let report = await service.runTest(
            bundleID: "com.example.unapproved", windowIndex: 0,
            windowTitle: "Window",
            steps: [HarborUITestStep(
                elementID: "0/1", expectedLabel: "Run", operation: "click"
            )]
        )
        #expect(!report.passed)
        #expect(report.durationMilliseconds == 0)
        #expect(report.steps.count == 1)
        #expect(report.steps[0].message.contains("expectContains"))
    }

    @Test("MCP tool catalog retains existing developer tools and UI capabilities")
    func catalogHasBothFamilies() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-ui-list-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BridgePaths(root: root)
        let workspace = root.appendingPathComponent("project")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(
                allowedRoots: AllowedRootsManager(roots: [workspace])
            ),
            configuration: BridgeConfiguration(),
            auditLogger: AuditLogger(paths: paths),
            uiAutomationPaths: paths
        )
        let names = await router.definitions().map(\.name)
        for tool in ["open_workspace", "read", "patch_file", "git_status", "run_command",
                     "ui_apps", "ui_open_app", "ui_windows", "ui_inspect", "ui_perform",
                     "ui_wait", "ui_wait_window", "ui_test", "ui_capture"] {
            #expect(names.contains(tool))
        }
        #expect(names.count == MCPToolCatalogMetadata.toolCount)
    }
}
