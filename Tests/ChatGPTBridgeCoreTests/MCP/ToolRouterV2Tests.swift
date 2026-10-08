import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Tool router v2")
struct ToolRouterV2Tests {
    @Test("reversible workspace operations through MCP preserve data and reject protected paths")
    func workspaceReorganization() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborWorkspaceReorg-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("source".utf8).write(to: project.appendingPathComponent("source.txt"))
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project])),
            configuration: BridgeConfiguration(
                allowedRoots: [project.path], trustedDevelopmentRoots: [project.path]),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("bridge"))),
            trashRoot: root.appendingPathComponent("recoverable")
        )
        let a = ToolExecutionContext(sessionID: "first-chat")
        let b = ToolExecutionContext(sessionID: "second-chat")
        _ = try await router.execute(name: "open_workspace",
            arguments: ["path": .string(project.path)], context: a)
        _ = try await router.execute(name: "create_directory",
            arguments: ["path": .string("Sources/New")], context: a)
        _ = try await router.execute(name: "move_path",
            arguments: ["path": .string("source.txt"), "destination": .string("Sources/New/source.txt")], context: a)
        let trashed = try await router.execute(name: "trash_path",
            arguments: ["path": .string("Sources/New")], context: a)
        let trashID = try #require(trashed.objectValue?["trashID"]?.stringValue)
        #expect(!FileManager.default.fileExists(atPath: project.appendingPathComponent("Sources/New").path))
        _ = try await router.execute(name: "open_workspace",
            arguments: ["path": .string(project.path)], context: b)
        let items = try await router.execute(name: "list_trash", arguments: [:], context: b)
        #expect(items.arrayValue?.count == 1)
        _ = try await router.execute(name: "restore_path",
            arguments: ["trashId": .string(trashID)], context: b)
        #expect(try String(contentsOf: project.appendingPathComponent("Sources/New/source.txt"), encoding: .utf8) == "source")
        let secondTrash = try await router.execute(name: "trash_path",
            arguments: ["path": .string("Sources/New")], context: a)
        let secondID = try #require(secondTrash.objectValue?["trashID"]?.stringValue)
        _ = try await router.execute(name: "create_directory",
            arguments: ["path": .string("Sources/New")], context: a)
        await #expect(throws: Error.self) {
            _ = try await router.execute(name: "restore_path",
                arguments: ["trashId": .string(secondID)], context: b)
        }
        let outside = root.appendingPathComponent("external", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: project.appendingPathComponent("external-link"), withDestinationURL: outside)
        await #expect(throws: Error.self) {
            _ = try await router.execute(name: "trash_path",
                arguments: ["path": .string("external-link")], context: a)
        }
        await #expect(throws: Error.self) {
            _ = try await router.execute(name: "trash_path",
                arguments: ["path": .string(".")], context: a)
        }
        await #expect(throws: Error.self) {
            _ = try await router.execute(name: "trash_path",
                arguments: ["path": .string(".git/config")], context: a)
        }
        await #expect(throws: Error.self) {
            _ = try await router.execute(name: "move_path",
                arguments: ["path": .string("Sources"), "destination": .string("../outside")], context: a)
        }
    }

    @Test("new conversations can discover existing command IDs")
    func taskDiscoveryAcrossChats() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborTaskDiscovery-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root])),
            configuration: BridgeConfiguration(shellPermission: .allow),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("bridge")))
        )
        _ = try await router.execute(name: "open_workspace",
            arguments: ["path": .string(root.path)],
            context: ToolExecutionContext(sessionID: "chat-a"))
        let started = try await router.execute(name: "start_command",
            arguments: ["executable": .string("sleep"), "arguments": .array([.string("1")])],
            context: ToolExecutionContext(sessionID: "chat-a"))
        let commandID = try #require(started.objectValue?["commandID"]?.stringValue)
        let tasks = try await router.execute(name: "list_tasks", arguments: [:],
            context: ToolExecutionContext(sessionID: "chat-b"))
        #expect(tasks.objectValue?["commands"]?.arrayValue?.contains {
            $0.objectValue?["commandID"]?.stringValue == commandID
        } == true)
        _ = try await router.execute(name: "cancel_command",
            arguments: ["commandId": .string(commandID)],
            context: ToolExecutionContext(sessionID: "chat-a"))
    }

    @Test("tail_file reads actionable errors from logs larger than 4 MiB")
    func readsLargeLogTail() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborLargeLog-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var log = Data(repeating: 65, count: 5 * 1_024 * 1_024)
        log.append(Data("\\nBUILD_FAILURE_AT_END".utf8))
        try log.write(to: root.appendingPathComponent("build.log"))
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root])),
            configuration: BridgeConfiguration(),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("bridge")))
        )
        let context = ToolExecutionContext(sessionID: "logs")
        _ = try await router.execute(name: "open_workspace",
            arguments: ["path": .string(root.path)], context: context)
        let tail = try await router.execute(name: "tail_file", arguments: [
            "path": .string("build.log"), "limitBytes": .number(256)
        ], context: context)
        #expect(tail.objectValue?["content"]?.stringValue?.contains("BUILD_FAILURE_AT_END") == true)
        #expect(tail.objectValue?["truncated"]?.boolValue == true)
        #expect(tail.objectValue?["totalBytes"]?.intValue ?? 0 > 5_000_000)
    }

    @Test("new MCP tools execute through the active workspace session")
    func executesNewTools() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborToolRouterV2-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Sources", isDirectory: true),
            withIntermediateDirectories: true
        )
        try Data("demo".utf8).write(to: root.appendingPathComponent("README.md"))
        try initializeGit(at: root)

        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root]))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(
                modificationPermission: .allow,
                shellPermission: .allow,
                gitPushPermission: .allow
            ),
            auditLogger: AuditLogger(paths: BridgePaths(root: root.appendingPathComponent("Bridge")))
        )
        let context = ToolExecutionContext(sessionID: "tool-router-v2")

        _ = try await router.execute(
            name: "open_workspace",
            arguments: ["path": .string(root.path)],
            context: context
        )

        let list = try await router.execute(
            name: "list_directory",
            arguments: [:],
            context: context
        )
        let listObject = try #require(list.objectValue)
        let entries = try #require(listObject["entries"]?.arrayValue)
        #expect(entries.contains {
            $0.objectValue?["name"]?.stringValue == "Sources"
        })

        let tree = try await router.execute(
            name: "workspace_tree",
            arguments: ["depth": .number(2)],
            context: context
        )
        #expect(tree.objectValue?["entries"]?.arrayValue?.isEmpty == false)

        let gitStatus = try await router.execute(
            name: "git_status",
            arguments: [:],
            context: context
        )
        #expect(gitStatus.objectValue?["isClean"]?.boolValue == false)
        #expect(gitStatus.objectValue?["entries"]?.arrayValue?.isEmpty == false)

        let started = try await router.execute(
            name: "start_command",
            arguments: [
                "executable": .string("printf"),
                "arguments": .array([.string("hello-v2")])
            ],
            context: context
        )
        let commandID = try #require(started.objectValue?["commandID"]?.stringValue)

        var state = "running"
        for _ in 0..<20 where state == "running" {
            try await Task.sleep(for: .milliseconds(50))
            let status = try await router.execute(
                name: "command_status",
                arguments: ["commandId": .string(commandID)],
                context: context
            )
            state = status.objectValue?["state"]?.stringValue ?? "unknown"
        }
        #expect(state == "completed")

        let output = try await router.execute(
            name: "command_output",
            arguments: ["commandId": .string(commandID)],
            context: context
        )
        #expect(output.objectValue?["stdout"]?.stringValue == "hello-v2")

        let workflow = try await router.execute(
            name: "run_workflow",
            arguments: [:],
            context: context
        )
        #expect(workflow.objectValue?["state"]?.stringValue == "unsupported")

        let asyncWorkflow = try await router.execute(
            name: "start_workflow",
            arguments: [:],
            context: context
        )
        let workflowID = try #require(asyncWorkflow.objectValue?["workflowID"]?.stringValue)
        #expect(asyncWorkflow.objectValue?["state"]?.stringValue == "unsupported")

        let workflowStatus = try await router.execute(
            name: "workflow_status",
            arguments: ["workflowId": .string(workflowID)],
            context: context
        )
        #expect(workflowStatus.objectValue?["state"]?.stringValue == "unsupported")

        let workflowOutput = try await router.execute(
            name: "workflow_output",
            arguments: ["workflowId": .string(workflowID)],
            context: context
        )
        #expect(workflowOutput.objectValue?["stdout"]?.stringValue == "")

        let cancelledWorkflow = try await router.execute(
            name: "cancel_workflow",
            arguments: ["workflowId": .string(workflowID)],
            context: context
        )
        #expect(cancelledWorkflow.objectValue?["state"]?.stringValue == "unsupported")

        let codingTask = try await router.execute(
            name: "coding_task",
            arguments: [
                "action": .string("start"),
                "requirement": .string("verify Coding Task routing"),
                "includeTests": .bool(false),
                "includeBuild": .bool(false),
                "includePackage": .bool(false)
            ],
            context: context
        )
        let taskID = try #require(codingTask.objectValue?["taskID"]?.stringValue)
        #expect(codingTask.objectValue?["state"]?.stringValue == "unsupported")

        let codingTaskStatus = try await router.execute(
            name: "coding_task",
            arguments: [
                "action": .string("status"),
                "taskId": .string(taskID)
            ],
            context: context
        )
        #expect(codingTaskStatus.objectValue?["taskID"]?.stringValue == taskID)
        #expect(codingTaskStatus.objectValue?["state"]?.stringValue == "unsupported")
    }

    @Test("approvals for Coding Task are bound to complete patch contents")
    func codingTaskApprovalIntegrity() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborApprovalIntegrity-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("demo".utf8).write(to: root.appendingPathComponent("README.md"))
        let paths = BridgePaths(root: root.appendingPathComponent("Bridge", isDirectory: true))
        let approvals = BridgeApprovalStore(paths: paths)
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [root])),
            configuration: BridgeConfiguration(modificationPermission: .ask, shellPermission: .allow),
            auditLogger: AuditLogger(paths: paths),
            approvalStore: approvals
        )
        let context = ToolExecutionContext(sessionID: "approval-integrity")
        _ = try await router.execute(
            name: "open_workspace",
            arguments: ["path": .string(root.path)],
            context: context
        )
        func request(_ replacement: String) async throws -> JSONValue {
            try await router.execute(
                name: "coding_task",
                arguments: [
                    "requirement": .string("Update README"),
                    "changes": .array([.object([
                        "path": .string("README.md"),
                        "mode": .string("old_new"),
                        "oldText": .string("demo"),
                        "newText": .string(replacement)
                    ])]),
                    "includeTests": .bool(false),
                    "includeBuild": .bool(false),
                    "includePackage": .bool(false)
                ],
                context: context
            )
        }
        let first = Task { try await request("safe replacement") }
        let second = Task { try await request("different replacement") }
        var pending: [BridgeApprovalRequest] = []
        for _ in 0..<40 {
            pending = approvals.pendingRequests()
            if pending.count >= 2 { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        for item in pending { approvals.decide(id: item.id, allow: false) }
        #expect(pending.count == 2)
        await #expect(throws: BridgeError.self) { _ = try await first.value }
        await #expect(throws: BridgeError.self) { _ = try await second.value }
        #expect(try String(contentsOf: root.appendingPathComponent("README.md"), encoding: .utf8) == "demo")
    }

    private func initializeGit(at root: URL) throws {
        let fileManager = FileManager.default
        let bridge = root.appendingPathComponent("Bridge", isDirectory: true)
        try? fileManager.removeItem(at: bridge)

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
