import Foundation

public struct BridgeDiagnosticBundleExporter: Sendable {
    private struct Manifest: Codable {
        let generatedAt: Date
        let appVersion: String
        let buildVersion: String
        let osVersion: String
        let architecture: String
        let protocolVersion: String
        let toolCatalogVersion: String
        let toolCount: Int
    }

    private struct ConfigurationSummary: Codable {
        let enabled: Bool
        let launchAtLogin: Bool
        let allowedRootCount: Int
        let modificationPermission: String
        let shellPermission: String
        let gitPushPermission: String
        let transportMode: String
        let secureTunnelConfigured: Bool
        let httpsCompatibilityConfigured: Bool
    }

    private struct RuntimeSummary: Codable {
        let overall: String
        let agent: String
        let mcp: String
        let tunnel: String
        let chatGPT: String
        let transportMode: String
        let transportProcessRunning: Bool
        let transportProcessIdentifier: Int32?
        let processIdentifier: Int32?
        let remoteEndpointReady: Bool
        let mcpPort: UInt16?
        let toolCatalogVersion: String?
        let toolCatalogCount: Int?
        let startedAt: Date?
        let transportHealthCheckedAt: Date?
        let controlPlaneLastSuccessAt: Date?
        let controlPlanePollCycles: Int
        let controlPlanePollErrors: Int
        let lastToolCallAt: Date?
        let lastToolCallName: String?
        let lastToolCallSucceeded: Bool?
    }

    private struct DiagnosticNode: Codable {
        let id: String
        let title: String
        let state: String
        let message: String
        let lastCheckAt: Date?
        let latency: Int?
        let details: [String]
    }

    private struct IntegrationSummary: Codable {
        let transportMode: String
        let hostname: String?
        let configuredAt: Date
        let lastActivityAt: Date
        let discoveredToolCatalogVersion: String?
        let discoveredToolCount: Int?
        let catalogDiscoveredAt: Date?
        let toolCatalogRefreshRequired: Bool
    }

    private struct AuditSummary: Codable {
        let timestamp: Date
        let tool: String
        let status: String
        let durationMilliseconds: Int
        let summary: String
    }

    private struct ToolCatalogSummary: Codable {
        let version: String
        let count: Int
        let tools: [String]
    }

    public init() {}

    @discardableResult
    public func export(
        configuration: BridgeConfiguration,
        runtime: BridgeRuntimeState,
        destinationDirectory: URL,
        integrationMarker: ChatGPTIntegrationMarker? = nil,
        diagnostics: [BridgeDiagnosticResult] = [],
        auditEntries: [AuditEntry] = [],
        appVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
        buildVersion: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
    ) throws -> URL {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)

        let timestamp = Self.timestampString(Date())
        let baseName = "CodexHarbor-Diagnostics-\(timestamp)"
        let staging = destinationDirectory.appendingPathComponent(baseName, isDirectory: true)
        let archive = destinationDirectory.appendingPathComponent("\(baseName).zip")

        try? fileManager.removeItem(at: staging)
        try? fileManager.removeItem(at: archive)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let manifest = Manifest(
            generatedAt: Date(),
            appVersion: appVersion,
            buildVersion: buildVersion,
            osVersion: ProcessInfo.processInfo.operatingSystemVersionString,
            architecture: Self.architectureName,
            protocolVersion: MCPProtocolVersion.modern,
            toolCatalogVersion: MCPToolCatalogMetadata.version,
            toolCount: MCPToolCatalogMetadata.toolCount
        )
        try writeJSON(manifest, to: staging.appendingPathComponent("manifest.json"))

        let config = ConfigurationSummary(
            enabled: configuration.enabled,
            launchAtLogin: configuration.launchAtLogin,
            allowedRootCount: configuration.allowedRoots.count,
            modificationPermission: configuration.modificationPermission.rawValue,
            shellPermission: configuration.shellPermission.rawValue,
            gitPushPermission: configuration.gitPushPermission.rawValue,
            transportMode: configuration.transportMode.rawValue,
            secureTunnelConfigured: configuration.secureTunnel != nil,
            httpsCompatibilityConfigured: configuration.httpsCompatibility != nil
        )
        try writeJSON(config, to: staging.appendingPathComponent("configuration.json"))

        let runtimeSummary = RuntimeSummary(
            overall: runtime.overall.rawValue,
            agent: runtime.agent.rawValue,
            mcp: runtime.mcp.rawValue,
            tunnel: runtime.tunnel.rawValue,
            chatGPT: runtime.chatGPT.rawValue,
            transportMode: runtime.transportMode.rawValue,
            transportProcessRunning: runtime.transportProcessRunning,
            transportProcessIdentifier: runtime.transportProcessIdentifier,
            processIdentifier: runtime.processIdentifier,
            remoteEndpointReady: runtime.remoteEndpointReady,
            mcpPort: runtime.mcpPort,
            toolCatalogVersion: runtime.toolCatalogVersion,
            toolCatalogCount: runtime.toolCatalogCount,
            startedAt: runtime.startedAt,
            transportHealthCheckedAt: runtime.transportHealthCheckedAt,
            controlPlaneLastSuccessAt: runtime.controlPlaneLastSuccessAt,
            controlPlanePollCycles: runtime.controlPlanePollCycles,
            controlPlanePollErrors: runtime.controlPlanePollErrors,
            lastToolCallAt: runtime.lastToolCallAt,
            lastToolCallName: runtime.lastToolCallName.map(sanitize),
            lastToolCallSucceeded: runtime.lastToolCallSucceeded
        )
        try writeJSON(runtimeSummary, to: staging.appendingPathComponent("runtime.json"))

        let nodes = runtime.pipelineDiagnostics.nodes.map { node in
            DiagnosticNode(
                id: node.id,
                title: sanitize(node.title),
                state: node.state.rawValue,
                message: sanitize(node.message),
                lastCheckAt: node.lastCheckAt,
                latency: node.latency,
                details: node.details.map(sanitize)
            )
        }
        try writeJSON(nodes, to: staging.appendingPathComponent("pipeline.json"))

        if let integrationMarker {
            let refreshRequired = {
                guard let discovered = integrationMarker.discoveredToolCatalogVersion else {
                    return false
                }
                return discovered != MCPToolCatalogMetadata.version
                    || integrationMarker.discoveredToolCount != MCPToolCatalogMetadata.toolCount
            }()
            let integration = IntegrationSummary(
                transportMode: integrationMarker.transportMode.rawValue,
                hostname: integrationMarker.hostname.map(sanitize),
                configuredAt: integrationMarker.configuredAt,
                lastActivityAt: integrationMarker.lastActivityAt,
                discoveredToolCatalogVersion: integrationMarker.discoveredToolCatalogVersion,
                discoveredToolCount: integrationMarker.discoveredToolCount,
                catalogDiscoveredAt: integrationMarker.catalogDiscoveredAt,
                toolCatalogRefreshRequired: refreshRequired
            )
            try writeJSON(integration, to: staging.appendingPathComponent("integration.json"))
        }

        if !diagnostics.isEmpty {
            let sanitizedDiagnostics = diagnostics.map {
                BridgeDiagnosticResult(
                    id: $0.id,
                    title: sanitize($0.title),
                    status: $0.status,
                    message: sanitize($0.message),
                    durationMilliseconds: $0.durationMilliseconds
                )
            }
            try writeJSON(
                sanitizedDiagnostics,
                to: staging.appendingPathComponent("diagnostics.json")
            )
        }

        if !auditEntries.isEmpty {
            let audit = auditEntries.prefix(100).map {
                AuditSummary(
                    timestamp: $0.timestamp,
                    tool: $0.tool,
                    status: $0.status.rawValue,
                    durationMilliseconds: $0.durationMilliseconds,
                    summary: sanitize($0.summary)
                )
            }
            try writeJSON(audit, to: staging.appendingPathComponent("audit.json"))
        }

        let toolCatalog = ToolCatalogSummary(
            version: MCPToolCatalogMetadata.version,
            count: MCPToolCatalogMetadata.toolCount,
            tools: MCPToolCatalogMetadata.toolNames
        )
        try writeJSON(
            toolCatalog,
            to: staging.appendingPathComponent("tool-catalog.json")
        )

        let readme = """
        Codex Harbor diagnostic bundle

        This archive intentionally excludes credentials.json, Runtime Keys, API keys,
        access tokens, authorization headers, allowed-root paths, and raw request content.
        """
        try Data(readme.utf8).write(to: staging.appendingPathComponent("README.txt"), options: .atomic)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-c", "-k", "--sequesterRsrc", "--keepParent", staging.path, archive.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              fileManager.fileExists(atPath: archive.path) else {
            throw BridgeError.writeFailed("诊断包压缩失败")
        }
        return archive
    }

    private func writeJSON<T: Encodable>(_ value: T, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(value).write(to: url, options: .atomic)
    }

    private func sanitize(_ value: String) -> String {
        var result = value
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        if !home.isEmpty {
            result = result.replacingOccurrences(of: home, with: "~")
        }

        let patterns = [
            #"(?i)bearer\s+[A-Za-z0-9._~+/=-]{8,}"#,
            #"(?i)sk-[A-Za-z0-9_-]{8,}"#,
            #"(?i)(runtime[ _-]?key|api[ _-]?key|access[ _-]?token)\s*[:=]\s*[^\s,;]+"#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            result = regex.stringByReplacingMatches(
                in: result,
                range: range,
                withTemplate: "[REDACTED]"
            )
        }
        return result
    }

    private static func timestampString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}
