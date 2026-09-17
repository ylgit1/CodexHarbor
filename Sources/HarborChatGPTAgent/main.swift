import ChatGPTBridgeCore
import Darwin
import Dispatch
import Foundation

private struct AgentStartupInfo: Codable, Sendable {
    let status: String
    let pid: Int32
    let mcpURL: String
    let healthURL: String
    let allowedRootCount: Int
    let tunnelState: String
    let tunnelMessage: String
}

private actor AgentLifecycle {
    private let paths: BridgePaths
    private let configuration: BridgeConfiguration
    private let httpServer: LocalMCPHTTPServer
    private let mcpPort: UInt16
    private let mcpURL: URL
    private let localMCPAccessToken: String
    private let startedAt = Date()
    private var tunnelManager: SecureTunnelManager?
    private var tunnelState: TunnelRuntimeState = .disabled
    private var tunnelMessage: String?
    private var monitorTask: Task<Void, Never>?

    init(
        paths: BridgePaths,
        configuration: BridgeConfiguration,
        httpServer: LocalMCPHTTPServer,
        mcpPort: UInt16,
        mcpURL: URL,
        localMCPAccessToken: String
    ) {
        self.paths = paths
        self.configuration = configuration
        self.httpServer = httpServer
        self.mcpPort = mcpPort
        self.mcpURL = mcpURL
        self.localMCPAccessToken = localMCPAccessToken
    }

    func start() async {
        if configuration.secureTunnel != nil {
            await restartTunnel()
            monitorTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(5))
                    guard !Task.isCancelled else { return }
                    await self?.monitorTunnel()
                }
            }
        }
        writeRuntimeState(agent: .running, mcp: .ready)
    }

    func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        if let tunnelManager {
            await tunnelManager.stop()
        }
        tunnelManager = nil
        tunnelState = .disabled
        tunnelMessage = nil
        httpServer.stop()
        writeRuntimeState(agent: .stopped, mcp: .stopped)
    }

    func startupInfo() -> AgentStartupInfo {
        AgentStartupInfo(
            status: "running",
            pid: ProcessInfo.processInfo.processIdentifier,
            mcpURL: mcpURL.absoluteString,
            healthURL: "http://\(LocalMCPHTTPServer.host):\(mcpPort)/health",
            allowedRootCount: configuration.allowedRoots.count,
            tunnelState: tunnelState.rawValue,
            tunnelMessage: tunnelMessage ?? ""
        )
    }

    private func monitorTunnel() async {
        guard configuration.secureTunnel != nil else { return }
        guard let tunnelManager else {
            await restartTunnel()
            return
        }

        let processRunning = await tunnelManager.isProcessRunning()
        let ready = processRunning ? await tunnelManager.readiness() : false
        if ready {
            if tunnelState != .connected {
                tunnelState = .connected
                tunnelMessage = nil
                writeRuntimeState(agent: .running, mcp: .ready)
            }
            return
        }

        await restartTunnel()
    }

    private func restartTunnel() async {
        guard let tunnelConfiguration = configuration.secureTunnel else {
            tunnelState = .disabled
            tunnelMessage = nil
            return
        }

        if let existing = tunnelManager {
            await existing.stop()
        }
        tunnelState = .connecting
        tunnelMessage = "正在建立 Secure MCP Tunnel"
        writeRuntimeState(agent: .running, mcp: .ready)

        do {
            let runtimeKey = try resolveRuntimeKey()
            let manager = SecureTunnelManager(paths: paths)
            tunnelManager = manager
            _ = try await manager.start(
                configuration: tunnelConfiguration,
                mcpURL: mcpURL,
                runtimeAPIKey: runtimeKey,
                localMCPAccessToken: localMCPAccessToken
            )
            let ready = await manager.readiness()
            tunnelState = ready ? .connected : .connecting
            tunnelMessage = ready ? nil : "Secure Tunnel 已启动，等待 control-plane poll 完成"
        } catch {
            tunnelState = .failed
            tunnelMessage = error.localizedDescription
        }
        writeRuntimeState(agent: .running, mcp: .ready)
    }

    private func resolveRuntimeKey() throws -> String {
        if let injected = ProcessInfo.processInfo.environment["HARBOR_BRIDGE_TUNNEL_API_KEY"]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !injected.isEmpty {
            return injected
        }
        if let stored = try BridgeSecretStore().string(for: .tunnelRuntimeAPIKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !stored.isEmpty {
            return stored
        }
        throw BridgeError.permissionDenied("Secure Tunnel 已配置，但 Keychain 中没有 runtime API key")
    }

    private func writeRuntimeState(agent: AgentRuntimeState, mcp: MCPRuntimeState) {
        let overall: BridgeOverallState = {
            if agent == .stopped { return .disabled }
            if tunnelState == .connected { return .ready }
            return .degraded
        }()
        let state = BridgeRuntimeState(
            overall: overall,
            agent: agent,
            mcp: mcp,
            tunnel: tunnelState,
            chatGPT: configuration.secureTunnel == nil ? .notConfigured : .configured,
            processIdentifier: agent == .running ? ProcessInfo.processInfo.processIdentifier : nil,
            mcpPort: mcp == .ready ? mcpPort : nil,
            mcpURL: mcp == .ready ? mcpURL.absoluteString : nil,
            startedAt: agent == .running ? startedAt : nil
        )
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(state).write(to: paths.runtimeURL, options: .atomic)
        } catch {
            FileHandle.standardError.write(Data("runtime state write failed: \(error.localizedDescription)\n".utf8))
        }
    }
}

private final class TerminationSignalWaiter: @unchecked Sendable {
    private let lock = NSLock()
    private var resumed = false
    private var sources: [DispatchSourceSignal] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            for signalNumber in [SIGTERM, SIGINT] {
                Darwin.signal(signalNumber, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: signalNumber, queue: .global(qos: .utility))
                source.setEventHandler { [weak self] in
                    guard let self else { return }
                    self.lock.lock()
                    guard !self.resumed else {
                        self.lock.unlock()
                        return
                    }
                    self.resumed = true
                    self.lock.unlock()
                    continuation.resume()
                }
                sources.append(source)
                source.resume()
            }
        }
    }
}

@main
struct HarborChatGPTAgentMain {
    static func main() async throws {
        let paths = try BridgePaths.live()
        try paths.ensureDirectories()

        let configuration = try BridgeConfigurationStore(paths: paths).load()
        let allowedRoots = AllowedRootsManager(
            roots: configuration.allowedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        let workspaceManager = WorkspaceManager(allowedRoots: allowedRoots)
        let auditLogger = AuditLogger(paths: paths)
        let toolRouter = ToolRouter(
            workspaceManager: workspaceManager,
            configuration: configuration,
            auditLogger: auditLogger
        )
        let localMCPAccessToken = try BridgeSecretStore().localMCPAccessToken()
        let httpServer = LocalMCPHTTPServer(
            server: MCPServer(router: toolRouter),
            accessToken: localMCPAccessToken
        )
        let mcpPort = try httpServer.start()
        guard let mcpURL = URL(string: "http://\(LocalMCPHTTPServer.host):\(mcpPort)/mcp") else {
            throw BridgeError.invalidPath("MCP URL")
        }

        let lifecycle = AgentLifecycle(
            paths: paths,
            configuration: configuration,
            httpServer: httpServer,
            mcpPort: mcpPort,
            mcpURL: mcpURL,
            localMCPAccessToken: localMCPAccessToken
        )
        await lifecycle.start()

        let startupEncoder = JSONEncoder()
        startupEncoder.outputFormatting = [.sortedKeys]
        let startupData = try startupEncoder.encode(await lifecycle.startupInfo())
        print(String(decoding: startupData, as: UTF8.self))
        fflush(stdout)

        let waiter = TerminationSignalWaiter()
        await waiter.wait()
        await lifecycle.stop()
    }
}
