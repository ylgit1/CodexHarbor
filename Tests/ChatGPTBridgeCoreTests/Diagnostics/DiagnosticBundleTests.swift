import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Diagnostic bundle")
struct DiagnosticBundleTests {
    @Test("export contains health metadata but excludes secrets and root paths")
    func redactedBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborDiagnostics-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let homeSecretPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("PrivateProject")
            .path
        let runtimeSecret = "super-secret-runtime-key"
        let bearerSecret = "Bearer abcdefghijklmnopqrstuvwxyz"

        let configuration = BridgeConfiguration(
            enabled: true,
            launchAtLogin: true,
            allowedRoots: [homeSecretPath],
            modificationPermission: .ask,
            shellPermission: .safeOnly,
            gitPushPermission: .ask,
            transportMode: .secureTunnel,
            secureTunnel: SecureTunnelConfiguration(
                tunnelID: "tunnel-private-identifier",
                executablePath: "/private/bin/tunnel-client"
            )
        )
        let runtime = BridgeRuntimeState(
            overall: .ready,
            agent: .running,
            mcp: .ready,
            tunnel: .connected,
            chatGPT: .recentlyActive,
            transportMode: .secureTunnel,
            transportProcessRunning: true,
            transportProcessIdentifier: 456,
            remoteEndpointReady: true,
            processIdentifier: 123,
            mcpPort: 19_473,
            toolCatalogVersion: MCPToolCatalogMetadata.version,
            toolCatalogCount: MCPToolCatalogMetadata.toolCount,
            lastToolCallName: "read",
            lastToolCallSucceeded: true,
            pipelineDiagnostics: BridgePipelineDiagnostics(nodes: [
                BridgeNodeDiagnostic(
                    id: "mcp",
                    title: "Local MCP",
                    state: .ready,
                    message: bearerSecret,
                    details: [
                        "Runtime Key: \(runtimeSecret)",
                        homeSecretPath,
                        "tools：\(MCPToolCatalogMetadata.toolCount) 个"
                    ]
                )
            ])
        )

        let archive = try BridgeDiagnosticBundleExporter().export(
            configuration: configuration,
            runtime: runtime,
            destinationDirectory: root,
            appVersion: "1.2.3",
            buildVersion: "456"
        )
        #expect(FileManager.default.fileExists(atPath: archive.path))

        let extracted = root.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", archive.path, extracted.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let contents = try FileManager.default
            .enumerator(
                at: extracted,
                includingPropertiesForKeys: [.isRegularFileKey],
                options: [.skipsHiddenFiles]
            )?
            .compactMap { $0 as? URL }
            .filter { (try? $0.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true }
            .compactMap { try? String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n") ?? ""

        #expect(contents.contains(MCPToolCatalogMetadata.version))
        #expect(contents.contains("\"toolCount\""))
        #expect(contents.contains("\"allowedRootCount\""))
        #expect(contents.contains("\"processIdentifier\" : 123"))
        #expect(contents.contains("\"transportProcessIdentifier\" : 456"))
        #expect(contents.contains(runtimeSecret) == false)
        #expect(contents.contains(bearerSecret) == false)
        #expect(contents.contains(homeSecretPath) == false)
        #expect(contents.contains("credentials.json") == true)
        #expect(contents.contains("tunnel-private-identifier") == false)
    }
}
