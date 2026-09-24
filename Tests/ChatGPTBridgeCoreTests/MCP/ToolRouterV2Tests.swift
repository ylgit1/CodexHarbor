import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Tool router v2")
struct ToolRouterV2Tests {
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
