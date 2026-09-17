import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("ChatGPT Bridge core")
struct ChatGPTBridgeCoreTests {
    @Test("Bridge configuration round-trips without Codex dependencies")
    func configurationRoundTrip() throws {
        let original = BridgeConfiguration(
            enabled: true,
            launchAtLogin: true,
            allowedRoots: ["/Users/example/project"]
        )
        let encoded = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(BridgeConfiguration.self, from: encoded)
        #expect(decoded == original)
    }

    @Test("Workspace tools open, read, and search only inside an allowed root")
    func workspaceReadAndSearch() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let source = project.appendingPathComponent("Example.swift")
        try Data("struct Example {\n    let marker = \"harbor-bridge-marker\"\n}\n".utf8).write(to: source)

        let roots = AllowedRootsManager(roots: [fixture.root])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let opened = try await OpenWorkspaceTool(workspaceManager: workspaces).execute(path: project.path)

        let read = try await ReadFileTool(workspaceManager: workspaces).execute(
            workspaceID: opened.workspaceID,
            path: "Example.swift",
            offset: 1,
            limit: 20
        )
        #expect(read.content.contains("harbor-bridge-marker"))
        #expect(read.truncated == false)

        let search = try await SearchTool(workspaceManager: workspaces).execute(
            workspaceID: opened.workspaceID,
            query: "harbor-bridge-marker"
        )
        #expect(search.matchLineCount == 1)
        #expect(search.output.contains("Example.swift"))
    }

    @Test("Path validation rejects parent traversal and symlink escape")
    func pathEscapeIsRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let allowed = fixture.root.appendingPathComponent("allowed", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("secret".utf8).write(to: outside.appendingPathComponent("secret.txt"))
        try FileManager.default.createSymbolicLink(
            at: allowed.appendingPathComponent("escape"),
            withDestinationURL: outside
        )

        let roots = AllowedRootsManager(roots: [allowed])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let workspace = try await workspaces.open(path: allowed.path)
        let validator = PathValidator()

        #expect(throws: BridgeError.self) {
            _ = try validator.resolve(workspace: workspace, relativePath: "../outside/secret.txt")
        }
        #expect(throws: BridgeError.self) {
            _ = try validator.resolve(workspace: workspace, relativePath: "escape/secret.txt")
        }
    }

    @Test("Opening a path outside Allowed Roots is rejected")
    func disallowedWorkspaceIsRejected() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let allowed = fixture.root.appendingPathComponent("allowed", isDirectory: true)
        let outside = fixture.root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: allowed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let roots = AllowedRootsManager(roots: [allowed])
        let workspaces = WorkspaceManager(allowedRoots: roots)

        await #expect(throws: BridgeError.self) {
            _ = try await workspaces.open(path: outside.path)
        }
    }

    @Test("Bridge workspace operations never modify Codex configuration")
    func codexIsolation() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let fakeHome = fixture.root.appendingPathComponent("home", isDirectory: true)
        let fakeCodex = fakeHome.appendingPathComponent(".codex", isDirectory: true)
        try FileManager.default.createDirectory(at: fakeCodex, withIntermediateDirectories: true)
        let configURL = fakeCodex.appendingPathComponent("config.toml")
        let authURL = fakeCodex.appendingPathComponent("auth.json")
        let configBefore = Data("model = \"gpt-5.6-sol\"\n".utf8)
        let authBefore = Data("{\"auth\":\"unchanged\"}".utf8)
        try configBefore.write(to: configURL)
        try authBefore.write(to: authURL)

        let project = fixture.root.appendingPathComponent("projects/Demo", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let bridgeIsolationMarker = true\n".utf8)
            .write(to: project.appendingPathComponent("Demo.swift"))

        let roots = AllowedRootsManager(roots: [fixture.root.appendingPathComponent("projects")])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let opened = try await OpenWorkspaceTool(workspaceManager: workspaces).execute(path: project.path)
        _ = try await ReadFileTool(workspaceManager: workspaces).execute(
            workspaceID: opened.workspaceID,
            path: "Demo.swift"
        )
        _ = try await SearchTool(workspaceManager: workspaces).execute(
            workspaceID: opened.workspaceID,
            query: "bridgeIsolationMarker"
        )

        let bridgePaths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let audit = AuditLogger(paths: bridgePaths)
        let permissions = PermissionEngine(configuration: BridgeConfiguration(modificationPermission: .allow))
        _ = try await EditFileTool(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        ).execute(
            workspaceID: opened.workspaceID,
            path: "Demo.swift",
            oldText: "true",
            newText: "false"
        )
        _ = try await WriteFileTool(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        ).execute(
            workspaceID: opened.workspaceID,
            path: "Generated.txt",
            content: "bridge only\n"
        )
        _ = try await ShellTool(
            workspaceManager: workspaces,
            permissionEngine: permissions,
            auditLogger: audit
        ).execute(
            workspaceID: opened.workspaceID,
            request: CommandRequest(executable: "pwd")
        )

        #expect(try Data(contentsOf: configURL) == configBefore)
        #expect(try Data(contentsOf: authURL) == authBefore)
    }

    @Test("Edit requires exactly one match and writes atomically")
    func exactEdit() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("Sample.swift")
        try Data("let value = 1\nlet other = 2\n".utf8).write(to: file)

        let roots = AllowedRootsManager(roots: [project])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let opened = try await OpenWorkspaceTool(workspaceManager: workspaces).execute(path: project.path)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let tool = EditFileTool(
            workspaceManager: workspaces,
            permissionEngine: PermissionEngine(configuration: BridgeConfiguration(modificationPermission: .allow)),
            auditLogger: audit
        )

        let result = try await tool.execute(
            workspaceID: opened.workspaceID,
            path: "Sample.swift",
            oldText: "value = 1",
            newText: "value = 3"
        )
        #expect(result.replacedOccurrences == 1)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("value = 3"))

        await #expect(throws: BridgeError.self) {
            _ = try await tool.execute(
                workspaceID: opened.workspaceID,
                path: "Sample.swift",
                oldText: "let",
                newText: "var"
            )
        }
        #expect(try String(contentsOf: file, encoding: .utf8).contains("let other = 2"))
    }

    @Test("Write creates files and refuses accidental overwrite")
    func safeWrite() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let roots = AllowedRootsManager(roots: [project])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let opened = try await OpenWorkspaceTool(workspaceManager: workspaces).execute(path: project.path)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let tool = WriteFileTool(
            workspaceManager: workspaces,
            permissionEngine: PermissionEngine(configuration: BridgeConfiguration(modificationPermission: .allow)),
            auditLogger: audit
        )

        let created = try await tool.execute(
            workspaceID: opened.workspaceID,
            path: "New.txt",
            content: "first"
        )
        #expect(created.created == true)

        await #expect(throws: BridgeError.self) {
            _ = try await tool.execute(
                workspaceID: opened.workspaceID,
                path: "New.txt",
                content: "second"
            )
        }
        #expect(try String(contentsOf: project.appendingPathComponent("New.txt"), encoding: .utf8) == "first")

        let overwritten = try await tool.execute(
            workspaceID: opened.workspaceID,
            path: "New.txt",
            content: "second",
            overwrite: true
        )
        #expect(overwritten.created == false)
        #expect(try String(contentsOf: project.appendingPathComponent("New.txt"), encoding: .utf8) == "second")
    }

    @Test("Modification permission requires approval by default")
    func modificationPermission() throws {
        let engine = PermissionEngine(configuration: BridgeConfiguration())
        #expect(throws: BridgeError.self) {
            try engine.authorizeModification(operation: "edit")
        }
        #expect(throws: Never.self) {
            try engine.authorizeModification(operation: "edit", approvalGranted: true)
        }
    }

    @Test("Command policy allows safe builds and blocks dangerous shells")
    func commandPolicy() throws {
        let policy = CommandPolicy()
        #expect(policy.assess(CommandRequest(executable: "swift", arguments: ["build"])).risk == .safe)
        #expect(policy.assess(CommandRequest(executable: "git", arguments: ["status"])).risk == .safe)
        #expect(policy.assess(CommandRequest(executable: "git", arguments: ["push"])).risk == .review)
        #expect(policy.assess(CommandRequest(executable: "git", arguments: ["push", "--force"])).risk == .blocked)
        #expect(policy.assess(CommandRequest(executable: "zsh", arguments: ["-c", "echo unsafe"])).risk == .blocked)
        #expect(policy.assess(CommandRequest(executable: "rm", arguments: ["-rf", "."])).risk == .blocked)
    }

    @Test("Shell executes safe commands inside the workspace")
    func safeShell() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)

        let roots = AllowedRootsManager(roots: [project])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let opened = try await OpenWorkspaceTool(workspaceManager: workspaces).execute(path: project.path)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let tool = ShellTool(
            workspaceManager: workspaces,
            permissionEngine: PermissionEngine(configuration: BridgeConfiguration(shellPermission: .safeOnly)),
            auditLogger: audit
        )

        let result = try await tool.execute(
            workspaceID: opened.workspaceID,
            request: CommandRequest(executable: "pwd")
        )
        #expect(result.exitCode == 0)
        let shellPath = URL(
            fileURLWithPath: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines),
            isDirectory: true
        ).standardizedFileURL.resolvingSymlinksInPath().path
        #expect(shellPath == project.standardizedFileURL.resolvingSymlinksInPath().path)

        await #expect(throws: BridgeError.self) {
            _ = try await tool.execute(
                workspaceID: opened.workspaceID,
                request: CommandRequest(executable: "zsh", arguments: ["-c", "echo blocked"])
            )
        }
    }

    @Test("Modern MCP discovery and tool listing use the stateless 2026 protocol")
    func modernMCPDiscoveryAndTools() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let roots = AllowedRootsManager(roots: [project])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(modificationPermission: .allow),
            auditLogger: audit
        )
        let server = MCPServer(router: router)

        let discover = await server.handle(request: MCPJSONRPCRequest(
            id: .number(1),
            method: "server/discover"
        ))
        let discoverObject = try #require(discover.result?.objectValue)
        #expect(discoverObject["resultType"]?.stringValue == "complete")
        #expect(discoverObject["supportedVersions"]?.arrayValue?.first?.stringValue == MCPProtocolVersion.modern)
        #expect(discoverObject["ttlMs"]?.intValue == 60_000)
        #expect(discoverObject["cacheScope"]?.stringValue == "private")

        let list = await server.handle(
            request: MCPJSONRPCRequest(id: .number(2), method: "tools/list"),
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/list"
            )
        )
        let listObject = try #require(list.result?.objectValue)
        let tools = try #require(listObject["tools"]?.arrayValue)
        #expect(tools.count == 6)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names == ["open_workspace", "read", "search", "edit", "write", "bash"])
        #expect(names.contains("initialize") == false)
    }

    @Test("MCP tools call the real workspace router")
    func mcpToolCallRoundTrip() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let mcpMarker = true\n".utf8).write(to: project.appendingPathComponent("Demo.swift"))

        let roots = AllowedRootsManager(roots: [project])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(modificationPermission: .allow),
            auditLogger: audit
        )
        let server = MCPServer(router: router)

        let open = await server.handle(
            request: MCPJSONRPCRequest(
                id: .number(1),
                method: "tools/call",
                params: [
                    "name": .string("open_workspace"),
                    "arguments": .object(["path": .string(project.path)])
                ]
            ),
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/call",
                nameHeader: "open_workspace"
            )
        )
        let openResult = try #require(open.result?.objectValue)
        #expect(openResult["isError"]?.boolValue == false)
        let structured = try #require(openResult["structuredContent"]?.objectValue)
        let workspaceID = try #require(structured["workspaceID"]?.stringValue)

        let read = await server.handle(
            request: MCPJSONRPCRequest(
                id: .number(2),
                method: "tools/call",
                params: [
                    "name": .string("read"),
                    "arguments": .object([
                        "workspaceId": .string(workspaceID),
                        "path": .string("Demo.swift")
                    ])
                ]
            ),
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/call",
                nameHeader: "read"
            )
        )
        let readResult = try #require(read.result?.objectValue)
        let readStructured = try #require(readResult["structuredContent"]?.objectValue)
        #expect(readStructured["content"]?.stringValue?.contains("mcpMarker") == true)
    }

    @Test("MCP rejects header routing mismatches")
    func mcpHeaderMismatch() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let roots = AllowedRootsManager(roots: [fixture.root])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(),
            auditLogger: audit
        )
        let server = MCPServer(router: router)

        let response = await server.handle(
            request: MCPJSONRPCRequest(id: .number(1), method: "tools/list"),
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/call"
            )
        )
        #expect(response.error?.code == -32600)
    }

    @Test("MCP cannot self-approve mutating tools")
    func mcpApprovalBoundary() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let value = 1\n".utf8).write(to: project.appendingPathComponent("Demo.swift"))

        let roots = AllowedRootsManager(roots: [project])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let opened = try await workspaces.open(path: project.path)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(modificationPermission: .ask),
            auditLogger: audit
        )
        let server = MCPServer(router: router)
        let request = MCPJSONRPCRequest(
            id: .number(1),
            method: "tools/call",
            params: [
                "name": .string("edit"),
                "arguments": .object([
                    "workspaceId": .string(opened.id.uuidString),
                    "path": .string("Demo.swift"),
                    "oldText": .string("value = 1"),
                    "newText": .string("value = 2"),
                    "approvalGranted": .bool(true)
                ])
            ]
        )

        let denied = await server.handle(
            request: request,
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/call",
                nameHeader: "edit",
                approvalGranted: false
            )
        )
        #expect(denied.result?.objectValue?["isError"]?.boolValue == true)
        #expect(try String(contentsOf: project.appendingPathComponent("Demo.swift"), encoding: .utf8).contains("value = 1"))

        let approved = await server.handle(
            request: request,
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/call",
                nameHeader: "edit",
                approvalGranted: true
            )
        )
        #expect(approved.result?.objectValue?["isError"]?.boolValue == false)
        #expect(try String(contentsOf: project.appendingPathComponent("Demo.swift"), encoding: .utf8).contains("value = 2"))
    }

    @Test("Local MCP HTTP server binds loopback and exposes health")
    func localMCPHTTPHealth() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let roots = AllowedRootsManager(roots: [fixture.root])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(),
            auditLogger: audit
        )
        let mcp = MCPServer(router: router)
        let http = LocalMCPHTTPServer(server: mcp)
        let port = try http.start()
        defer { http.stop() }
        #expect(port > 0)
        #expect(http.localURL?.host == "127.0.0.1")

        let url = try #require(URL(string: "http://127.0.0.1:\(port)/health"))
        let (data, response) = try await URLSession.shared.data(from: url)
        #expect((response as? HTTPURLResponse)?.statusCode == 200)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["status"] as? String == "ok")
        #expect(object["protocolVersion"] as? String == MCPProtocolVersion.modern)
    }

    @Test("Local MCP HTTP server serves modern discovery and tools list")
    func localMCPHTTPProtocol() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let roots = AllowedRootsManager(roots: [fixture.root])
        let workspaces = WorkspaceManager(allowedRoots: roots)
        let audit = AuditLogger(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(),
            auditLogger: audit
        )
        let http = LocalMCPHTTPServer(server: MCPServer(router: router))
        let port = try http.start()
        defer { http.stop() }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))

        let discoverRequest = MCPJSONRPCRequest(id: .number(1), method: "server/discover")
        let discoverBody = try JSONEncoder().encode(discoverRequest)
        var discoverURLRequest = URLRequest(url: endpoint)
        discoverURLRequest.httpMethod = "POST"
        discoverURLRequest.httpBody = discoverBody
        discoverURLRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        discoverURLRequest.setValue("server/discover", forHTTPHeaderField: "Mcp-Method")
        let (discoverData, discoverResponse) = try await URLSession.shared.data(for: discoverURLRequest)
        #expect((discoverResponse as? HTTPURLResponse)?.statusCode == 200)
        let discover = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: discoverData)
        #expect(discover.result?.objectValue?["supportedVersions"]?.arrayValue?.first?.stringValue == MCPProtocolVersion.modern)

        let listRequest = MCPJSONRPCRequest(id: .number(2), method: "tools/list")
        var listURLRequest = URLRequest(url: endpoint)
        listURLRequest.httpMethod = "POST"
        listURLRequest.httpBody = try JSONEncoder().encode(listRequest)
        listURLRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        listURLRequest.setValue("tools/list", forHTTPHeaderField: "Mcp-Method")
        listURLRequest.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
        let (listData, listResponse) = try await URLSession.shared.data(for: listURLRequest)
        #expect((listResponse as? HTTPURLResponse)?.statusCode == 200)
        let list = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: listData)
        #expect(list.result?.objectValue?["tools"]?.arrayValue?.count == 6)

        var invalidRequest = URLRequest(url: endpoint)
        invalidRequest.httpMethod = "POST"
        invalidRequest.httpBody = try JSONEncoder().encode(listRequest)
        invalidRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        invalidRequest.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
        let (_, invalidResponse) = try await URLSession.shared.data(for: invalidRequest)
        #expect((invalidResponse as? HTTPURLResponse)?.statusCode == 400)

        let callRequest = MCPJSONRPCRequest(
            id: .number(3),
            method: "tools/call",
            params: ["name": .string("open_workspace"), "arguments": .object(["path": .string(fixture.root.path)])]
        )
        var missingNameRequest = URLRequest(url: endpoint)
        missingNameRequest.httpMethod = "POST"
        missingNameRequest.httpBody = try JSONEncoder().encode(callRequest)
        missingNameRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        missingNameRequest.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
        missingNameRequest.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
        let (_, missingNameResponse) = try await URLSession.shared.data(for: missingNameRequest)
        #expect((missingNameResponse as? HTTPURLResponse)?.statusCode == 400)
    }

    @Test("Authenticated local MCP requests unlock trusted write actions")
    func authenticatedLocalMCPWrites() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let file = project.appendingPathComponent("Demo.swift")
        try Data("let value = 1\n".utf8).write(to: file)

        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(modificationPermission: .ask),
            auditLogger: AuditLogger(paths: paths)
        )
        let http = LocalMCPHTTPServer(server: MCPServer(router: router), accessToken: "local-secret")
        let port = try http.start()
        defer { http.stop() }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))

        let listRequest = MCPJSONRPCRequest(id: .number(1), method: "tools/list")
        var unauthorized = URLRequest(url: endpoint)
        unauthorized.httpMethod = "POST"
        unauthorized.httpBody = try JSONEncoder().encode(listRequest)
        unauthorized.setValue("application/json", forHTTPHeaderField: "Content-Type")
        unauthorized.setValue("tools/list", forHTTPHeaderField: "Mcp-Method")
        unauthorized.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
        let (_, unauthorizedResponse) = try await URLSession.shared.data(for: unauthorized)
        #expect((unauthorizedResponse as? HTTPURLResponse)?.statusCode == 401)

        func trustedRequest(_ request: MCPJSONRPCRequest, name: String) async throws -> MCPJSONRPCResponse {
            var urlRequest = URLRequest(url: endpoint)
            urlRequest.httpMethod = "POST"
            urlRequest.httpBody = try JSONEncoder().encode(request)
            urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
            urlRequest.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
            urlRequest.setValue(name, forHTTPHeaderField: "Mcp-Name")
            urlRequest.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
            urlRequest.setValue("local-secret", forHTTPHeaderField: "X-Harbor-Bridge-Token")
            let (data, response) = try await URLSession.shared.data(for: urlRequest)
            #expect((response as? HTTPURLResponse)?.statusCode == 200)
            return try JSONDecoder().decode(MCPJSONRPCResponse.self, from: data)
        }

        let opened = try await trustedRequest(
            MCPJSONRPCRequest(
                id: .number(2),
                method: "tools/call",
                params: [
                    "name": .string("open_workspace"),
                    "arguments": .object(["path": .string(project.path)])
                ]
            ),
            name: "open_workspace"
        )
        let workspaceID = try #require(opened.result?.objectValue?["structuredContent"]?.objectValue?["workspaceID"]?.stringValue)

        let edited = try await trustedRequest(
            MCPJSONRPCRequest(
                id: .number(3),
                method: "tools/call",
                params: [
                    "name": .string("edit"),
                    "arguments": .object([
                        "workspaceId": .string(workspaceID),
                        "path": .string("Demo.swift"),
                        "oldText": .string("value = 1"),
                        "newText": .string("value = 2")
                    ])
                ]
            ),
            name: "edit"
        )
        #expect(edited.result?.objectValue?["isError"]?.boolValue == false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("value = 2"))
    }

    @Test("Secure Tunnel launch plan stays outbound-only and does not persist runtime key")
    func secureTunnelLaunchPlan() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let manager = SecureTunnelManager(paths: paths)
        let configuration = SecureTunnelConfiguration(
            tunnelID: "tunnel_test",
            executablePath: "/usr/bin/true"
        )
        let mcpURL = try #require(URL(string: "http://127.0.0.1:51428/mcp"))
        let plan = try await manager.makeLaunchPlan(
            configuration: configuration,
            mcpURL: mcpURL,
            runtimeAPIKey: "runtime-secret",
            localMCPAccessToken: "local-secret",
            baseEnvironment: [:]
        )
        #expect(plan.executableURL.path == "/usr/bin/true")
        #expect(plan.arguments.contains("127.0.0.1:0"))
        #expect(plan.arguments.contains(mcpURL.absoluteString))
        #expect(plan.environment["CONTROL_PLANE_TUNNEL_ID"] == "tunnel_test")
        #expect(plan.environment["CONTROL_PLANE_API_KEY"] == "runtime-secret")
        #expect(plan.environment["HARBOR_LOCAL_MCP_TOKEN"] == "local-secret")
        #expect(plan.arguments.contains("--mcp.extra-headers"))
        #expect(plan.arguments.contains("--mcp.discovery-extra-headers"))

        let bridgeConfiguration = BridgeConfiguration(secureTunnel: configuration)
        let encoded = try JSONEncoder().encode(bridgeConfiguration)
        let text = String(decoding: encoded, as: UTF8.self)
        #expect(text.contains("runtime-secret") == false)
    }

    @Test("Secure Tunnel rejects non-loopback MCP targets")
    func secureTunnelRejectsRemoteMCP() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let manager = SecureTunnelManager(paths: BridgePaths(root: fixture.root.appendingPathComponent("bridge")))
        let configuration = SecureTunnelConfiguration(tunnelID: "tunnel_test", executablePath: "/usr/bin/true")
        let remote = try #require(URL(string: "https://example.com/mcp"))
        await #expect(throws: BridgeError.self) {
            _ = try await manager.makeLaunchPlan(
                configuration: configuration,
                mcpURL: remote,
                runtimeAPIKey: "runtime-secret",
                baseEnvironment: [:]
            )
        }
    }

    @Test("Read-only MCP tools are visible in the audit activity stream")
    func readOnlyToolsAreAudited() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let auditMarker = true\n".utf8).write(to: project.appendingPathComponent("Demo.swift"))

        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let audit = AuditLogger(paths: paths)
        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(),
            auditLogger: audit
        )
        let opened = try await router.execute(
            name: "open_workspace",
            arguments: ["path": .string(project.path)]
        )
        let workspaceID = try #require(opened.objectValue?["workspaceID"]?.stringValue)
        _ = try await router.execute(
            name: "read",
            arguments: ["workspaceId": .string(workspaceID), "path": .string("Demo.swift")]
        )
        _ = try await router.execute(
            name: "search",
            arguments: ["workspaceId": .string(workspaceID), "query": .string("auditMarker")]
        )

        let entries = try await audit.entries()
        #expect(entries.map(\.tool) == ["open_workspace", "read", "search"])
        #expect(entries.allSatisfy { $0.status == .success })
    }

    @Test("Bridge diagnostics exercise the live MCP discovery path")
    func bridgeDiagnostics() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        try paths.ensureDirectories()

        let workspaces = WorkspaceManager(allowedRoots: AllowedRootsManager(roots: [project]))
        let audit = AuditLogger(paths: paths)
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(allowedRoots: [project.path]),
            auditLogger: audit
        )
        let http = LocalMCPHTTPServer(server: MCPServer(router: router))
        let port = try http.start()
        defer { http.stop() }

        let runtime = BridgeRuntimeState(
            overall: .degraded,
            agent: .running,
            mcp: .ready,
            tunnel: .disabled,
            chatGPT: .notConfigured,
            processIdentifier: ProcessInfo.processInfo.processIdentifier,
            mcpPort: port,
            mcpURL: "http://127.0.0.1:\(port)/mcp",
            startedAt: Date()
        )
        let results = await BridgeDiagnosticsRunner().run(
            paths: paths,
            configuration: BridgeConfiguration(enabled: true, allowedRoots: [project.path]),
            runtime: runtime,
            launchAgentStatus: BridgeLaunchAgentStatus(
                installed: false,
                loaded: false,
                plistURL: fixture.root.appendingPathComponent("agent.plist")
            )
        )
        #expect(results.first(where: { $0.id == "mcp" })?.status == .passed)
        #expect(results.first(where: { $0.id == "roots" })?.status == .passed)
        #expect(results.first(where: { $0.id == "codex-isolation" })?.status == .passed)
    }

    @Test("LaunchAgent property list keeps the Bridge helper isolated")
    func launchAgentPropertyList() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let plist = BridgeLaunchAgentManager().makePropertyList(
            agentExecutableURL: URL(fileURLWithPath: "/usr/bin/true"),
            paths: paths
        )
        #expect(plist["Label"] as? String == BridgeLaunchAgentManager.label)
        #expect((plist["ProgramArguments"] as? [String]) == ["/usr/bin/true"])
        #expect(plist["RunAtLoad"] as? Bool == true)
        #expect((plist["KeepAlive"] as? [String: Bool])?["SuccessfulExit"] == false)
        #expect((plist["StandardOutPath"] as? String)?.contains("ChatGPTBridge") == false)
        #expect((plist["StandardOutPath"] as? String)?.contains("bridge/logs") == true)
    }

    @Test("Audit log redacts common secrets")
    func auditRedaction() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let logger = AuditLogger(paths: paths)
        try await logger.record(AuditEntry(
            tool: "bash",
            workspaceID: nil,
            target: nil,
            status: .failure,
            durationMilliseconds: 1,
            summary: "Authorization: Bearer secret-token api_key=abc123 password=hunter2 sk-1234567890"
        ))

        let entries = try await logger.entries()
        let summary = try #require(entries.first?.summary)
        #expect(summary.contains("secret-token") == false)
        #expect(summary.contains("abc123") == false)
        #expect(summary.contains("hunter2") == false)
        #expect(summary.contains("sk-1234567890") == false)
        #expect(summary.contains("[REDACTED]"))
    }
}

private struct TestFixture {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborBridgeTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
