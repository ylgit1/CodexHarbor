import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("ChatGPT Bridge core")
struct ChatGPTBridgeCoreTests {
    @Test("Bridge secret store replaces an existing Runtime Key")
    func bridgeSecretStoreReplacesRuntimeKey() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let vaultURL = fixture.root.appendingPathComponent("credentials.json")
        let store = BridgeSecretStore(url: vaultURL)

        try store.set("old-runtime-key", for: .tunnelRuntimeAPIKey)
        try store.set("new-runtime-key", for: .tunnelRuntimeAPIKey)

        #expect(try store.string(for: .tunnelRuntimeAPIKey) == "new-runtime-key")
        let attributes = try FileManager.default.attributesOfItem(atPath: vaultURL.path)
        #expect((attributes[.posixPermissions] as? NSNumber)?.intValue == 0o600)
    }

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

    @Test("Bridge transports keep stable local MCP ports")
    func transportLocalMCPPortsAreStable() {
        let secure = BridgeConfiguration(transportMode: .secureTunnel)
        #expect(secure.localMCPPort == 19_473)

        let https = BridgeConfiguration(
            transportMode: .httpsCompatibility,
            httpsCompatibility: HTTPSCompatibilityConfiguration(
                tunnelName: "codex-harbor-demo",
                tunnelID: "11111111-2222-3333-4444-555555555555",
                hostname: "codex-harbor-demo.example.com",
                credentialsFilePath: "/tmp/cloudflare.json",
                cloudflaredPath: "/usr/local/bin/cloudflared",
                localPort: 19_473
            )
        )
        #expect(https.localMCPPort == 19_473)

        let sharedCustomPort = BridgeConfiguration(
            transportMode: .secureTunnel,
            httpsCompatibility: HTTPSCompatibilityConfiguration(
                tunnelName: "codex-harbor-custom",
                tunnelID: "11111111-2222-3333-4444-555555555555",
                hostname: "codex-harbor-custom.example.com",
                credentialsFilePath: "/tmp/cloudflare.json",
                cloudflaredPath: "/usr/local/bin/cloudflared",
                localPort: 20_000
            )
        )
        #expect(sharedCustomPort.localMCPPort == 20_000)
    }

    @Test("Tunnel health metrics expose real control-plane polling")
    func tunnelHealthMetricsExposeControlPlanePolling() {
        let metrics = """
        # HELP commands_poll_cycles_total Poll cycles
        commands_poll_cycles_total{otel_scope_name="controlplane"} 49
        commands_poll_errors_total{error_kind="timeout"} 1
        commands_poll_errors_total{error_kind="other"} 2
        commands_poll_last_successful_timestamp_seconds{otel_scope_name="controlplane"} 1790047303
        """
        let parsed = SecureTunnelManager.parseControlPlaneMetrics(metrics)
        #expect(parsed.pollCycles == 49)
        #expect(parsed.pollErrors == 3)
        #expect(parsed.lastSuccessAt == Date(timeIntervalSince1970: 1_790_047_303))
    }

    @Test("Bridge keeps both transport configurations while switching modes")
    func transportConfigurationsRemainIndependent() throws {
        let secure = SecureTunnelConfiguration(
            tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
            executablePath: "/usr/local/bin/tunnel-client"
        )
        let https = HTTPSCompatibilityConfiguration(
            tunnelName: "codex-harbor-demo",
            tunnelID: "11111111-2222-3333-4444-555555555555",
            hostname: "codex-harbor-demo.example.com",
            credentialsFilePath: "/tmp/cloudflare.json",
            cloudflaredPath: "/usr/local/bin/cloudflared"
        )
        var configuration = BridgeConfiguration(
            enabled: true,
            transportMode: .secureTunnel,
            secureTunnel: secure,
            httpsCompatibility: https
        )
        configuration.transportMode = .httpsCompatibility

        let data = try JSONEncoder().encode(configuration)
        let decoded = try JSONDecoder().decode(BridgeConfiguration.self, from: data)
        #expect(decoded.transportMode == .httpsCompatibility)
        #expect(decoded.secureTunnel == secure)
        #expect(decoded.httpsCompatibility == https)
        #expect(BridgeTransportMode.secureTunnel.displayName == "OpenAI 本地管道")
        #expect(BridgeTransportMode.httpsCompatibility.displayName == "公网 HTTPS")
    }

    @Test("An empty Cloudflare account reports no tunnels")
    func emptyCloudflareTunnelList() throws {
        #expect(try HTTPSCompatibilityConfigurator.decodeTunnelList(Data("null\n".utf8)).isEmpty)
        #expect(try HTTPSCompatibilityConfigurator.decodeTunnelList(Data("[]\n".utf8)).isEmpty)
        let existing = try HTTPSCompatibilityConfigurator.decodeTunnelList(
            Data(#"[{"id":"123","name":"existing"}]"#.utf8)
        )
        #expect(existing.count == 1)
        #expect(existing.first?.name == "existing")
    }

    @Test("Cloudflared installer selects the current Mac asset and verifies release checksums")
    func cloudflaredReleaseSelectionAndChecksum() throws {
        let arm = CloudflaredReleaseAsset(
            name: "cloudflared-darwin-arm64.tgz",
            browserDownloadURL: URL(string: "https://example.com/arm64.tgz")!,
            digest: "sha256:" + String(repeating: "a", count: 64)
        )
        let intel = CloudflaredReleaseAsset(
            name: "cloudflared-darwin-amd64.tgz",
            browserDownloadURL: URL(string: "https://example.com/amd64.tgz")!,
            digest: nil
        )
        let selected = CloudflaredInstaller.selectDarwinAsset(from: [arm, intel])
        #if arch(arm64)
        #expect(selected?.name == arm.name)
        #elseif arch(x86_64)
        #expect(selected?.name == intel.name)
        #endif

        #expect(CloudflaredInstaller.normalizedSHA256(arm.digest) == String(repeating: "a", count: 64))
        let releaseBody = """
        SHA256 Checksums:
        cloudflared-darwin-amd64.tgz: \(String(repeating: "b", count: 64))
        """
        #expect(
            CloudflaredInstaller.checksum(for: intel.name, in: releaseBody)
                == String(repeating: "b", count: 64)
        )
    }

    @Test("Cloudflared locator finds the app-managed executable without Homebrew")
    func cloudflaredLocatorFindsManagedExecutable() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let executable = paths.root.appendingPathComponent("bin/cloudflared/cloudflared")
        try FileManager.default.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        #expect(CloudflaredLocator().locate(paths: paths)?.path == executable.path)
    }

    @Test("Deleting the OpenAI tunnel removes only Harbor-managed downloads")
    func secureTunnelCleanupIsScoped() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        try paths.ensureDirectories()

        let tunnelDirectory = paths.root.appendingPathComponent("bin/v1.0.0", isDirectory: true)
        let tunnelExecutable = tunnelDirectory.appendingPathComponent("tunnel-client-runtime")
        let cloudflaredExecutable = paths.root.appendingPathComponent("bin/cloudflared/cloudflared")
        let tunnelArchive = paths.root.appendingPathComponent("downloads/tunnel-client-runtime-v1-darwin-arm64.zip")
        try FileManager.default.createDirectory(at: tunnelDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: cloudflaredExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: tunnelArchive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data().write(to: tunnelExecutable)
        try Data().write(to: cloudflaredExecutable)
        try Data().write(to: tunnelArchive)
        try Data().write(to: paths.root.appendingPathComponent("tunnel-client.log"))

        let configuration = BridgeConfiguration(
            secureTunnel: SecureTunnelConfiguration(
                tunnelID: "tunnel_0123456789abcdef0123456789abcdef",
                executablePath: tunnelExecutable.path
            )
        )
        try BridgeTransportArtifactCleaner(homeDirectory: fixture.root.appendingPathComponent("home"))
            .removeArtifacts(for: .secureTunnel, configuration: configuration, paths: paths)

        #expect(FileManager.default.fileExists(atPath: tunnelDirectory.path) == false)
        #expect(FileManager.default.fileExists(atPath: tunnelArchive.path) == false)
        #expect(FileManager.default.fileExists(atPath: paths.root.appendingPathComponent("tunnel-client.log").path) == false)
        #expect(FileManager.default.fileExists(atPath: cloudflaredExecutable.path))
    }

    @Test("Deleting public HTTPS removes Harbor artifacts but preserves shared Cloudflare authorization")
    func publicHTTPSCleanupPreservesSharedAuthorization() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        try paths.ensureDirectories()

        let home = fixture.root.appendingPathComponent("home", isDirectory: true)
        let cloudflareHome = home.appendingPathComponent(".cloudflared", isDirectory: true)
        let credentials = cloudflareHome.appendingPathComponent("11111111-2222-3333-4444-555555555555.json")
        let unrelated = cloudflareHome.appendingPathComponent("unrelated.json")
        let certificate = cloudflareHome.appendingPathComponent("cert.pem")
        let managedExecutable = paths.root.appendingPathComponent("bin/cloudflared/cloudflared")
        let managedArchive = paths.root.appendingPathComponent("downloads/cloudflared/cloudflared.tgz")
        try FileManager.default.createDirectory(at: cloudflareHome, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: managedExecutable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: managedArchive.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        for file in [credentials, unrelated, certificate, managedExecutable, managedArchive] {
            try Data().write(to: file)
        }

        let configuration = BridgeConfiguration(
            transportMode: .httpsCompatibility,
            httpsCompatibility: HTTPSCompatibilityConfiguration(
                tunnelName: "codex-harbor-demo",
                tunnelID: "11111111-2222-3333-4444-555555555555",
                hostname: "codex-harbor-demo.example.com",
                credentialsFilePath: credentials.path,
                cloudflaredPath: managedExecutable.path
            )
        )
        try BridgeTransportArtifactCleaner(homeDirectory: home)
            .removeArtifacts(for: .httpsCompatibility, configuration: configuration, paths: paths)

        #expect(FileManager.default.fileExists(atPath: managedExecutable.path) == false)
        #expect(FileManager.default.fileExists(atPath: managedArchive.path) == false)
        #expect(FileManager.default.fileExists(atPath: credentials.path) == false)
        #expect(FileManager.default.fileExists(atPath: certificate.path))
        #expect(FileManager.default.fileExists(atPath: unrelated.path))
    }

    @Test("Legacy runtime state gains transport monitoring defaults")
    func legacyRuntimeMonitoringDefaults() throws {
        let data = Data(#"{"overall":"ready","agent":"running","mcp":"ready","tunnel":"connected","chatGPT":"configured","transportMode":"secureTunnel"}"#.utf8)
        let runtime = try JSONDecoder().decode(BridgeRuntimeState.self, from: data)
        #expect(runtime.transportProcessRunning)
        #expect(runtime.remoteEndpointReady)
        #expect(runtime.transportMessage == nil)
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

    @Test("Workspace IDs survive Agent restarts")
    func workspacePersistence() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        let persistenceURL = fixture.root.appendingPathComponent("workspaces.json")
        let roots = AllowedRootsManager(roots: [project])

        let firstManager = WorkspaceManager(
            allowedRoots: roots,
            persistenceURL: persistenceURL
        )
        let opened = try await firstManager.open(path: project.path)

        let secondManager = WorkspaceManager(
            allowedRoots: roots,
            persistenceURL: persistenceURL
        )
        let restored = try await secondManager.workspace(id: opened.id)
        #expect(restored.id == opened.id)
        #expect(restored.rootPath == project.standardizedFileURL.resolvingSymlinksInPath().path)

        let reopened = try await secondManager.open(path: project.path)
        #expect(reopened.id == opened.id)

        await roots.replace(with: [])
        await #expect(throws: BridgeError.self) {
            _ = try await secondManager.workspace(id: opened.id)
        }
    }

    @Test("MCP workspace session survives Agent and transport reconnection")
    func workspaceSessionPersistence() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let restoredSession = true\n".utf8).write(
            to: project.appendingPathComponent("Session.swift")
        )

        let bridgeRoot = fixture.root.appendingPathComponent("bridge", isDirectory: true)
        let paths = BridgePaths(root: bridgeRoot)
        try paths.ensureDirectories()
        let roots = AllowedRootsManager(roots: [project])
        let configuration = BridgeConfiguration(allowedRoots: [project.path])

        let firstRouter = ToolRouter(
            workspaceManager: WorkspaceManager(
                allowedRoots: roots,
                persistenceURL: paths.workspacesURL
            ),
            configuration: configuration,
            auditLogger: AuditLogger(paths: paths),
            workspaceSessionStore: WorkspaceSessionStore(
                persistenceURL: paths.workspaceSessionsURL
            )
        )
        let opened = try await firstRouter.execute(
            name: "open_workspace",
            arguments: ["path": .string(project.path)],
            context: ToolExecutionContext(sessionID: "session-A")
        )
        let workspaceID = try #require(opened.objectValue?["workspaceID"]?.stringValue)

        let restartedSessionStore = WorkspaceSessionStore(
            persistenceURL: paths.workspaceSessionsURL
        )
        let restartedRouter = ToolRouter(
            workspaceManager: WorkspaceManager(
                allowedRoots: roots,
                persistenceURL: paths.workspacesURL
            ),
            configuration: configuration,
            auditLogger: AuditLogger(paths: paths),
            workspaceSessionStore: restartedSessionStore
        )

        let sameSessionRead = try await restartedRouter.execute(
            name: "read",
            arguments: ["path": .string("Session.swift")],
            context: ToolExecutionContext(sessionID: "session-A")
        )
        #expect(sameSessionRead.objectValue?["content"]?.stringValue?.contains("restoredSession") == true)

        let newSessionRead = try await restartedRouter.execute(
            name: "read",
            arguments: ["path": .string("Session.swift")],
            context: ToolExecutionContext(sessionID: "session-B")
        )
        #expect(newSessionRead.objectValue?["content"]?.stringValue?.contains("restoredSession") == true)

        let invalidHandleRead = try await restartedRouter.execute(
            name: "read",
            arguments: [
                "workspaceId": .string("expired-workspace-handle"),
                "path": .string("Session.swift")
            ],
            context: ToolExecutionContext(sessionID: "session-A")
        )
        #expect(invalidHandleRead.objectValue?["content"]?.stringValue?.contains("restoredSession") == true)

        let staleUUIDRead = try await restartedRouter.execute(
            name: "read",
            arguments: [
                "workspaceId": .string(UUID().uuidString),
                "path": .string("Session.swift")
            ],
            context: ToolExecutionContext(sessionID: "session-A")
        )
        #expect(staleUUIDRead.objectValue?["content"]?.stringValue?.contains("restoredSession") == true)

        let reloadedStore = WorkspaceSessionStore(persistenceURL: paths.workspaceSessionsURL)
        #expect(await reloadedStore.resolve(sessionID: "session-A")?.uuidString == workspaceID)
        #expect(await reloadedStore.resolve(sessionID: "session-B")?.uuidString == workspaceID)
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

    @Test("Command policy classifies risky commands")
    func commandPolicy() throws {
        let policy = CommandPolicy()
        #expect(policy.assess(CommandRequest(executable: "swift", arguments: ["build"])).risk == .safe)
        #expect(policy.assess(CommandRequest(executable: "git", arguments: ["push", "--force"])).risk == .review)
        #expect(policy.assess(CommandRequest(executable: "zsh", arguments: ["-c", "echo allowed"])).risk == .safe)
        #expect(policy.assess(CommandRequest(executable: "bash", arguments: ["./Scripts/build-app.sh"])).risk == .review)
        #expect(policy.assess(CommandRequest(executable: "rm", arguments: ["-rf", "."])).risk == .blocked)
        #expect(policy.assess(CommandRequest(executable: "sudo", arguments: ["rm", "-rf", "/"])).risk == .blocked)
    }

    @Test("Blocked commands stay blocked in unrestricted development mode")
    func unrestrictedShellPermissionStillBlocksProhibitedCommands() throws {
        let request = CommandRequest(executable: "sudo", arguments: ["echo", "ok"])
        let assessment = CommandPolicy().assess(request)
        #expect(assessment.risk == .blocked)

        let restricted = PermissionEngine(
            configuration: BridgeConfiguration(shellPermission: .safeOnly)
        )
        #expect(throws: BridgeError.self) {
            try restricted.authorizeCommand(
                assessment,
                request: request,
                approvalGranted: true
            )
        }

        let unrestricted = PermissionEngine(
            configuration: BridgeConfiguration(
                modificationPermission: .allow,
                shellPermission: .allow,
                gitPushPermission: .allow
            )
        )
        #expect(throws: BridgeError.self) {
            try unrestricted.authorizeCommand(
                assessment,
                request: request,
                approvalGranted: false
            )
        }
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

        let shellResult = try await tool.execute(
            workspaceID: opened.workspaceID,
            request: CommandRequest(executable: "zsh", arguments: ["-c", "echo allowed"])
        )
        #expect(shellResult.exitCode == 0)
        #expect(shellResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "allowed")
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
        #expect(discoverObject["toolCatalogVersion"]?.stringValue == MCPToolCatalogMetadata.version)
        #expect(discoverObject["toolCount"]?.intValue == MCPToolCatalogMetadata.toolCount)
        #expect(discoverObject["instructions"]?.stringValue?.contains("continuous coding workflow") == true)

        let list = await server.handle(
            request: MCPJSONRPCRequest(id: .number(2), method: "tools/list"),
            context: MCPRequestContext(
                protocolVersion: MCPProtocolVersion.modern,
                methodHeader: "tools/list"
            )
        )
        let listObject = try #require(list.result?.objectValue)
        #expect(listObject["toolCatalogVersion"]?.stringValue == MCPToolCatalogMetadata.version)
        #expect(listObject["toolCount"]?.intValue == MCPToolCatalogMetadata.toolCount)
        let tools = try #require(listObject["tools"]?.arrayValue)
        #expect(tools.count == MCPToolCatalogMetadata.toolCount)
        let names = tools.compactMap { $0.objectValue?["name"]?.stringValue }
        #expect(names == [
            "open_workspace", "read", "search", "list_directory", "workspace_tree",
            "edit", "patch_file", "git_diff", "git_status", "write",
            "run_command", "bash", "start_command", "command_status", "command_output",
            "cancel_command", "start_workflow", "workflow_status", "workflow_output",
            "cancel_workflow", "run_workflow", "coding_task", "repair_project"
        ])
        #expect(tools.allSatisfy { $0.objectValue?["outputSchema"] != nil })
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
        let openContent = openResult["content"]?.arrayValue?.first?.objectValue?["text"]?.stringValue
        #expect(openContent?.contains("do not stop after opening the workspace") == true)
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
        #expect(object["toolCatalogVersion"] as? String == MCPToolCatalogMetadata.version)
        #expect(object["toolCount"] as? Int == MCPToolCatalogMetadata.toolCount)
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
        let catalogMarker = fixture.root.appendingPathComponent("catalog-discovered")
        let http = LocalMCPHTTPServer(
            server: MCPServer(router: router),
            onToolCatalogDiscovered: {
                try? Data("seen".utf8).write(to: catalogMarker, options: .atomic)
            }
        )
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
        #expect(list.result?.objectValue?["tools"]?.arrayValue?.count == MCPToolCatalogMetadata.toolCount)
        #expect(FileManager.default.fileExists(atPath: catalogMarker.path))

        try? FileManager.default.removeItem(at: catalogMarker)
        var internalListRequest = listURLRequest
        internalListRequest.setValue("1", forHTTPHeaderField: "X-Harbor-Internal-Diagnostics")
        let (_, internalListResponse) = try await URLSession.shared.data(for: internalListRequest)
        #expect((internalListResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect(FileManager.default.fileExists(atPath: catalogMarker.path) == false)

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

    @Test("Local MCP session header restores the active workspace")
    func localMCPWorkspaceSessionHeader() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let project = fixture.root.appendingPathComponent("project", isDirectory: true)
        try FileManager.default.createDirectory(at: project, withIntermediateDirectories: true)
        try Data("let transportSession = true\n".utf8).write(
            to: project.appendingPathComponent("Session.swift")
        )

        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        try paths.ensureDirectories()
        let roots = AllowedRootsManager(roots: [project])
        let router = ToolRouter(
            workspaceManager: WorkspaceManager(
                allowedRoots: roots,
                persistenceURL: paths.workspacesURL
            ),
            configuration: BridgeConfiguration(allowedRoots: [project.path]),
            auditLogger: AuditLogger(paths: paths),
            workspaceSessionStore: WorkspaceSessionStore(persistenceURL: paths.workspaceSessionsURL)
        )
        let http = LocalMCPHTTPServer(server: MCPServer(router: router))
        let port = try http.start()
        defer { http.stop() }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp"))

        var initialize = URLRequest(url: endpoint)
        initialize.httpMethod = "POST"
        initialize.httpBody = try JSONEncoder().encode(MCPJSONRPCRequest(
            id: .number(1),
            method: "initialize",
            params: ["protocolVersion": .string(MCPProtocolVersion.modern)]
        ))
        initialize.setValue("application/json", forHTTPHeaderField: "Content-Type")
        initialize.setValue("initialize", forHTTPHeaderField: "Mcp-Method")
        let (_, initializeResponse) = try await URLSession.shared.data(for: initialize)
        let sessionID = try #require(
            (initializeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Mcp-Session-Id")
        )
        #expect(sessionID.isEmpty == false)

        func toolRequest(name: String, arguments: [String: JSONValue], id: Double) throws -> URLRequest {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(MCPJSONRPCRequest(
                id: .number(id),
                method: "tools/call",
                params: ["name": .string(name), "arguments": .object(arguments)]
            ))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("tools/call", forHTTPHeaderField: "Mcp-Method")
            request.setValue(name, forHTTPHeaderField: "Mcp-Name")
            request.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
            request.setValue(sessionID, forHTTPHeaderField: "Mcp-Session-Id")
            return request
        }

        let (_, openResponse) = try await URLSession.shared.data(for: toolRequest(
            name: "open_workspace",
            arguments: ["path": .string(project.path)],
            id: 2
        ))
        #expect((openResponse as? HTTPURLResponse)?.statusCode == 200)

        let (readData, readResponse) = try await URLSession.shared.data(for: toolRequest(
            name: "read",
            arguments: ["path": .string("Session.swift")],
            id: 3
        ))
        #expect((readResponse as? HTTPURLResponse)?.statusCode == 200)
        let read = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: readData)
        let content = read.result?.objectValue?["structuredContent"]?.objectValue?["content"]?.stringValue
        #expect(content?.contains("transportSession") == true)
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
        let approvalStore = BridgeApprovalStore(paths: paths)
        let router = ToolRouter(
            workspaceManager: workspaces,
            configuration: BridgeConfiguration(modificationPermission: .ask),
            auditLogger: AuditLogger(paths: paths),
            approvalStore: approvalStore
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

        let editRequest = MCPJSONRPCRequest(
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
        )

        let editTask = Task {
            try await trustedRequest(editRequest, name: "edit")
        }

        var approval: BridgeApprovalRequest?
        for _ in 0..<50 {
            if let pending = approvalStore.pendingRequests().first {
                approval = pending
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let pendingApproval = try #require(approval)
        approvalStore.decide(id: pendingApproval.id, allow: true)

        let edited = try await editTask.value
        #expect(edited.result?.objectValue?["isError"]?.boolValue == false)
        #expect(try String(contentsOf: file, encoding: .utf8).contains("value = 2"))
    }

    @Test("HTTPS compatibility endpoint supports public secret-path discovery and legacy initialize")
    func httpsCompatibilityEndpoint() async throws {
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
        let http = LocalMCPHTTPServer(
            server: MCPServer(router: router),
            accessToken: "local-secret",
            publicAccessToken: "compat-secret"
        )
        let port = try http.start()
        defer { http.stop() }
        let endpoint = try #require(URL(string: "http://127.0.0.1:\(port)/mcp/compat-secret"))

        var probe = URLRequest(url: endpoint)
        probe.httpMethod = "GET"
        probe.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        let (probeData, probeResponse) = try await URLSession.shared.data(for: probe)
        #expect((probeResponse as? HTTPURLResponse)?.statusCode == 200)
        #expect((probeResponse as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type") == "text/event-stream")
        #expect(String(decoding: probeData, as: UTF8.self).contains("codex-harbor-ready"))

        let discoverRequest = MCPJSONRPCRequest(id: .number(1), method: "server/discover")
        var discover = URLRequest(url: endpoint)
        discover.httpMethod = "POST"
        discover.httpBody = try JSONEncoder().encode(discoverRequest)
        discover.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (discoverData, discoverResponse) = try await URLSession.shared.data(for: discover)
        #expect((discoverResponse as? HTTPURLResponse)?.statusCode == 200)
        let discoverResult = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: discoverData)
        #expect(discoverResult.result?.objectValue?["supportedVersions"]?.arrayValue?.contains(.string(MCPProtocolVersion.modern)) == true)

        let initializeRequest = MCPJSONRPCRequest(
            id: .number(2),
            method: "initialize",
            params: [
                "protocolVersion": .string(MCPProtocolVersion.legacy),
                "capabilities": .object([:]),
                "clientInfo": .object(["name": .string("compat-test"), "version": .string("1")])
            ]
        )
        var initialize = URLRequest(url: endpoint)
        initialize.httpMethod = "POST"
        initialize.httpBody = try JSONEncoder().encode(initializeRequest)
        initialize.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (initializeData, initializeResponse) = try await URLSession.shared.data(for: initialize)
        #expect((initializeResponse as? HTTPURLResponse)?.statusCode == 200)
        let initialized = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: initializeData)
        #expect(initialized.result?.objectValue?["protocolVersion"]?.stringValue == MCPProtocolVersion.legacy)
    }

    @Test("HTTPS compatibility cloudflared config uses an isolated hostname and local port")
    func httpsCompatibilityCloudflaredConfig() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let configuration = HTTPSCompatibilityConfiguration(
            tunnelName: "codex-harbor-test",
            tunnelID: "11111111-2222-3333-4444-555555555555",
            hostname: "codex-harbor-test.example.com",
            credentialsFilePath: "/tmp/credentials.json",
            cloudflaredPath: "/usr/local/bin/cloudflared",
            localPort: 19_473
        )
        try HTTPSCompatibilityConfigurator.writeCloudflaredConfiguration(configuration, paths: paths)
        let text = try String(
            contentsOf: HTTPSCompatibilityConfigurator.configurationURL(paths: paths),
            encoding: .utf8
        )
        #expect(text.contains("codex-harbor-test.example.com"))
        #expect(text.contains("http://127.0.0.1:19473"))
        #expect(text.contains("devspace") == false)
        #expect(text.contains("mcp/") == false)
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
        #expect(plan.environment["NO_PROXY"]?.contains("127.0.0.1") == true)
        #expect(plan.environment["NO_PROXY"]?.contains("localhost") == true)
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

    @Test("A replaced Agent binary is reloaded after an app update")
    func updatedAgentBinaryRequiresRestart() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let executable = fixture.root.appendingPathComponent("HarborChatGPTAgent")
        try Data("agent".utf8).write(to: executable)
        let launchedAt = Date(timeIntervalSince1970: 1_800_000_000)
        try FileManager.default.setAttributes(
            [.modificationDate: launchedAt.addingTimeInterval(10)],
            ofItemAtPath: executable.path
        )

        let runtime = BridgeRuntimeState(
            agent: .running,
            processIdentifier: 123,
            startedAt: launchedAt
        )
        let manager = BridgeLaunchAgentManager()
        #expect(manager.needsRestart(agentExecutableURL: executable, runtime: runtime))

        try FileManager.default.setAttributes(
            [.modificationDate: launchedAt.addingTimeInterval(-10)],
            ofItemAtPath: executable.path
        )
        #expect(manager.needsRestart(agentExecutableURL: executable, runtime: runtime) == false)
    }

    @Test("Bridge logs rotate when they exceed the size limit")
    func logRotation() throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }

        let logURL = fixture.root.appendingPathComponent("bridge.log")
        try Data(repeating: 0x41, count: 64).write(to: logURL)
        BridgeLogRotator.rotateIfNeeded(logURL, maximumBytes: 32, backups: 2)

        #expect(FileManager.default.fileExists(atPath: logURL.path) == false)
        #expect(FileManager.default.fileExists(atPath: logURL.path + ".1"))

        try Data(repeating: 0x42, count: 64).write(to: logURL)
        BridgeLogRotator.rotateIfNeeded(logURL, maximumBytes: 32, backups: 2)

        #expect(FileManager.default.fileExists(atPath: logURL.path + ".1"))
        #expect(FileManager.default.fileExists(atPath: logURL.path + ".2"))
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

    @Test("Lifecycle manager switches configuration and refreshes credentials atomically")
    func lifecycleManagerOwnsBridgeTransitions() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        let store = BridgeConfigurationStore(paths: paths)
        let secrets = BridgeSecretStore(url: paths.credentialsURL)
        let manager = BridgeLifecycleManager(paths: paths, store: store, secretStore: secrets)
        let secure = SecureTunnelConfiguration(
            tunnelID: "tunnel_0123456789abcdef0123456789abcdef"
        )
        let https = HTTPSCompatibilityConfiguration(
            tunnelName: "codex-harbor-demo",
            tunnelID: "11111111-2222-3333-4444-555555555555",
            hostname: "mcp.example.com",
            credentialsFilePath: "/tmp/cloudflare.json",
            cloudflaredPath: "/tmp/cloudflared"
        )
        let configuration = BridgeConfiguration(
            enabled: false,
            allowedRoots: [fixture.root.path],
            transportMode: .secureTunnel,
            secureTunnel: secure,
            httpsCompatibility: https
        )
        try store.save(configuration)

        // Public HTTPS is an independent transport and must not require the
        // OpenAI Tunnel Runtime Key.
        let switched = try await manager.switchTransport(
            to: .httpsCompatibility,
            configuration: configuration,
            agentExecutableURL: fixture.root.appendingPathComponent("unused-agent")
        )
        #expect(switched.configuration.transportMode == .httpsCompatibility)
        #expect(try store.load().transportMode == .httpsCompatibility)

        var secureRejectedWithoutKey = false
        do {
            _ = try await manager.switchTransport(
                to: .secureTunnel,
                configuration: switched.configuration,
                agentExecutableURL: fixture.root.appendingPathComponent("unused-agent")
            )
        } catch {
            secureRejectedWithoutKey = true
        }
        #expect(secureRejectedWithoutKey)

        _ = try await manager.refreshRuntimeKey(
            "new-runtime-key",
            configuration: switched.configuration,
            agentExecutableURL: nil,
            restartIfActive: false
        )
        #expect(try secrets.string(for: .tunnelRuntimeAPIKey) == "new-runtime-key")
        #expect(await manager.phase == .idle)
    }

    @Test("Tunnel diagnostics ignore authentication errors from an older process")
    func tunnelDiagnosticsAreScopedToCurrentProcess() async throws {
        let fixture = try TestFixture()
        defer { fixture.cleanup() }
        let paths = BridgePaths(root: fixture.root.appendingPathComponent("bridge", isDirectory: true))
        try paths.ensureDirectories()
        let logURL = paths.root.appendingPathComponent("tunnel-client.log")
        try Data("401 unauthorized old key\nstarting control-plane poller\ntunnel metadata fetched\n".utf8)
            .write(to: logURL)

        let manager = SecureTunnelManager(paths: paths)
        #expect(await manager.latestIssue() == nil)

        let handle = try FileHandle(forWritingTo: logURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("401 unauthorized current key\n".utf8))
        try handle.close()
        #expect(await manager.latestIssue()?.contains("鉴权失败") == true)
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
