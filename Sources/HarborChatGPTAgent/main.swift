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
    private let mcpToolCount: Int
    private let localMCPAccessToken: String
    private let compatibilityAccessToken: String
    private let startedAt = Date()
    private var tunnelManager: SecureTunnelManager?
    private var compatibilityManager: HTTPSCompatibilityManager?
    private var tunnelState: TunnelRuntimeState = .disabled
    private var tunnelMessage: String?
    private var proxyStatus: TunnelProxyStatus?
    private var transportProcessRunning = false
    private var transportProcessIdentifier: Int32?
    private var remoteEndpointReady = false
    private var runtimeKeyState: BridgeRuntimeKeyState = .notRequired
    private var controlPlaneState: BridgeNodeState = .waiting
    private var endpointState: BridgeNodeState = .waiting
    private var pipelineDiagnostics = BridgePipelineDiagnostics()
    private var monitorTask: Task<Void, Never>?
    private var tunnelRetryAttempt = 0
    private var tunnelSelfHealAttempt = 0
    private var nextTunnelRetryAt: Date?
    private var tunnelNotReadySince: Date?
    private var lastToolCallAt: Date?
    private var transportHealthCheckedAt: Date?
    private var controlPlaneLastSuccessAt: Date?
    private var controlPlanePollCycles = 0
    private var controlPlanePollErrors = 0
    private var lastToolCallName: String?
    private var lastToolCallSucceeded: Bool?
    private var lastToolCallMessage: String?

    init(
        paths: BridgePaths,
        configuration: BridgeConfiguration,
        httpServer: LocalMCPHTTPServer,
        mcpPort: UInt16,
        mcpURL: URL,
        mcpToolCount: Int,
        localMCPAccessToken: String,
        compatibilityAccessToken: String
    ) {
        self.paths = paths
        self.configuration = configuration
        self.httpServer = httpServer
        self.mcpPort = mcpPort
        self.mcpURL = mcpURL
        self.mcpToolCount = mcpToolCount
        self.localMCPAccessToken = localMCPAccessToken
        self.compatibilityAccessToken = compatibilityAccessToken
    }

    private func stopInactiveTransport() async {
        switch configuration.transportMode {
        case .secureTunnel:
            if let compatibilityManager {
                await compatibilityManager.stop()
                self.compatibilityManager = nil
            }
        case .httpsCompatibility:
            if let tunnelManager {
                await tunnelManager.stop()
                self.tunnelManager = nil
            }
        }
    }

    func start() async {
        // Only one external transport is allowed to be active at a time.
        // This prevents stale cloudflared/tunnel-client processes after mode switches.
        await stopInactiveTransport()

        switch configuration.transportMode {
        case .secureTunnel:
            if configuration.secureTunnel != nil { await restartTunnel() }
        case .httpsCompatibility:
            if configuration.httpsCompatibility != nil { await restartCompatibility() }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { return }
                await self?.performScheduledHealthCheck()
                await self?.refreshIntegrationRuntimeState()
            }
        }
        writeRuntimeState(agent: .running, mcp: .ready)
    }

    func stop() async {
        monitorTask?.cancel()
        monitorTask = nil
        if let tunnelManager { await tunnelManager.stop() }
        if let compatibilityManager { await compatibilityManager.stop() }
        tunnelManager = nil
        compatibilityManager = nil
        tunnelState = .disabled
        tunnelMessage = nil
        proxyStatus = nil
        transportProcessRunning = false
        transportProcessIdentifier = nil
        remoteEndpointReady = false
        runtimeKeyState = .notRequired
        controlPlaneState = .waiting
        endpointState = .waiting
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

    private func performScheduledHealthCheck() async {
        let processStillRunning: Bool
        switch configuration.transportMode {
        case .secureTunnel:
            processStillRunning = await tunnelManager?.isProcessRunning() == true
        case .httpsCompatibility:
            processStillRunning = await compatibilityManager?.isProcessRunning() == true
        }

        if !processStillRunning || BridgeHealthPolicy.shouldRunRemoteHealth(
            lastCheck: transportHealthCheckedAt,
            diagnostics: pipelineDiagnostics
        ) {
            await monitorTransport()
        }
    }

    private func monitorTransport() async {
        switch configuration.transportMode {
        case .secureTunnel:
            guard configuration.secureTunnel != nil else { return }
            guard let tunnelManager else {
                await restartTunnel()
                return
            }
            let processRunning = await tunnelManager.isProcessRunning()
            let health = processRunning ? await tunnelManager.healthSnapshot() : SecureTunnelHealthSnapshot(live: false, ready: false)
            let ready = health.ready
            transportProcessRunning = processRunning
            transportProcessIdentifier = await tunnelManager.processIdentifier()
            transportHealthCheckedAt = health.checkedAt
            controlPlaneLastSuccessAt = health.controlPlaneLastSuccessAt
            controlPlanePollCycles = health.controlPlanePollCycles
            controlPlanePollErrors = health.controlPlanePollErrors

            let pollAge = health.controlPlaneLastSuccessAt.map { Date().timeIntervalSince($0) }
            let controlPlaneFresh = pollAge.map {
                $0 <= BridgeHealthPolicy.controlPlaneFreshnessInterval
            } ?? false
            let initialControlPlaneReady = health.controlPlaneLastSuccessAt == nil
                && health.controlPlanePollErrors == 0
            remoteEndpointReady = ready && (controlPlaneFresh || initialControlPlaneReady)

            if ready && controlPlaneFresh {
                runtimeKeyState = .valid
                controlPlaneState = .ready
                endpointState = .ready
                tunnelRetryAttempt = 0
                tunnelSelfHealAttempt = 0
                nextTunnelRetryAt = nil
                tunnelNotReadySince = nil
                if tunnelState != .connected || tunnelMessage != nil {
                    tunnelState = .connected
                    tunnelMessage = nil
                    writeRuntimeState(agent: .running, mcp: .ready)
                }
                return
            }

            if processRunning {
                let now = Date()
                if tunnelNotReadySince == nil {
                    tunnelNotReadySince = now
                }

                let waitingSeconds = Int(now.timeIntervalSince(tunnelNotReadySince ?? now))
                let issue = await tunnelManager.latestIssue()
                let authenticationFailed = issue.map(BridgeHealthPolicy.isTerminalAuthenticationFailure) == true
                let rateLimited = issue?.contains("429") == true
                    || issue?.contains("限流") == true
                let recoverable = !authenticationFailed && !rateLimited
                let selfHealDelay = BridgeHealthPolicy.tunnelSelfHealDelay(
                    for: tunnelSelfHealAttempt
                )

                if BridgeHealthPolicy.shouldRestartTunnel(
                    notReadySince: tunnelNotReadySince,
                    attempt: tunnelSelfHealAttempt,
                    recoverable: recoverable,
                    now: now
                ) {
                    tunnelSelfHealAttempt += 1
                    tunnelState = .connecting
                    tunnelMessage = "远程连接持续中断，正在自动重启本地管道（第 \(tunnelSelfHealAttempt) 次）"
                    writeRuntimeState(agent: .running, mcp: .ready)
                    await restartTunnel()
                    return
                }

                runtimeKeyState = authenticationFailed ? .invalid : .checking
                controlPlaneState = authenticationFailed ? .failed : .recovering
                endpointState = authenticationFailed ? .failed : .recovering
                tunnelState = authenticationFailed ? .failed : .connecting
                if !health.live {
                    tunnelMessage = "tunnel-client 进程存在，但健康接口不可达"
                } else if !ready {
                    tunnelMessage = issue ?? "tunnel-client 已运行，等待 OpenAI Tunnel 就绪"
                } else if let issue {
                    tunnelMessage = issue
                } else if let pollAge, pollAge > 75 {
                    tunnelMessage = "OpenAI 控制面轮询已停顿 \(Int(pollAge)) 秒"
                } else if health.controlPlaneLastSuccessAt == nil {
                    tunnelMessage = "尚未完成 OpenAI 控制面轮询"
                } else {
                    tunnelMessage = waitingSeconds < 30
                        ? "tunnel-client 已运行，等待 OpenAI Tunnel 就绪"
                        : "OpenAI Tunnel 尚未恢复，约 \(max(1, Int(selfHealDelay) - waitingSeconds)) 秒后自动重启本地管道"
                }
                writeRuntimeState(agent: .running, mcp: .ready)
                return
            }

            let now = Date()
            transportProcessIdentifier = nil
            controlPlaneState = .recovering
            endpointState = .recovering
            if let retryAt = nextTunnelRetryAt, now < retryAt {
                let remaining = max(1, Int(ceil(retryAt.timeIntervalSince(now))))
                tunnelState = .connecting
                tunnelMessage = "本地管道连接中断，\(remaining) 秒后重试"
                writeRuntimeState(agent: .running, mcp: .ready)
                return
            }

            await restartTunnel()

        case .httpsCompatibility:
            guard let compatibility = configuration.httpsCompatibility else { return }
            guard let compatibilityManager else {
                await restartCompatibility()
                return
            }
            let processRunning = await compatibilityManager.isProcessRunning()
            guard processRunning else {
                await restartCompatibility()
                return
            }
            let ready = await compatibilityManager.readiness(
                configuration: compatibility,
                localMCPAccessToken: compatibilityAccessToken
            )
            let issue = ready ? nil : await compatibilityManager.latestReadinessIssue()
            let nextState: TunnelRuntimeState = ready ? .connected : .connecting
            let nextMessage = ready ? nil : (issue ?? "cloudflared 已启动，等待公网 HTTPS 端点就绪")
            let changed = tunnelState != nextState || tunnelMessage != nextMessage || !transportProcessRunning
            transportProcessRunning = processRunning
            transportProcessIdentifier = await compatibilityManager.processIdentifier()
            remoteEndpointReady = ready
            runtimeKeyState = .notRequired
            controlPlaneState = ready ? .ready : .recovering
            endpointState = ready ? .ready : .recovering
            tunnelState = nextState
            tunnelMessage = nextMessage
            if changed {
                writeRuntimeState(agent: .running, mcp: .ready)
            }
        }
    }

    private func restartTunnel() async {
        guard let tunnelConfiguration = configuration.secureTunnel else {
            tunnelState = .disabled
            tunnelMessage = nil
            proxyStatus = nil
            transportProcessRunning = false
            transportProcessIdentifier = nil
            remoteEndpointReady = false
            runtimeKeyState = .notRequired
            controlPlaneState = .waiting
            endpointState = .waiting
            return
        }

        if let existing = tunnelManager {
            await existing.stop()
        }
        transportProcessRunning = false
        transportProcessIdentifier = nil
        remoteEndpointReady = false
        proxyStatus = nil
        runtimeKeyState = .checking
        controlPlaneState = .recovering
        endpointState = .recovering
        tunnelState = .connecting
        tunnelMessage = "Runtime Key 刷新中，正在恢复 OpenAI Tunnel"
        writeRuntimeState(agent: .running, mcp: .ready)

        let manager = SecureTunnelManager(paths: paths)
        tunnelManager = manager
        do {
            let runtimeKey = try resolveRuntimeKey()
            let managerState = try await manager.start(
                configuration: tunnelConfiguration,
                mcpURL: mcpURL,
                runtimeAPIKey: runtimeKey,
                localMCPAccessToken: localMCPAccessToken
            )
            proxyStatus = await manager.proxyStatus()
            transportProcessRunning = await manager.isProcessRunning()
            if case .running(let pid, _) = managerState {
                transportProcessIdentifier = pid
            } else {
                transportProcessIdentifier = await manager.processIdentifier()
            }
            let health = await manager.healthSnapshot()
            transportHealthCheckedAt = health.checkedAt
            controlPlaneLastSuccessAt = health.controlPlaneLastSuccessAt
            controlPlanePollCycles = health.controlPlanePollCycles
            controlPlanePollErrors = health.controlPlanePollErrors
            let controlPlaneFresh = health.controlPlaneLastSuccessAt.map {
                Date().timeIntervalSince($0) <= BridgeHealthPolicy.controlPlaneFreshnessInterval
            } ?? false
            let initialControlPlaneReady = health.controlPlaneLastSuccessAt == nil
                && health.controlPlanePollErrors == 0
            remoteEndpointReady = health.ready && (controlPlaneFresh || initialControlPlaneReady)
            if remoteEndpointReady {
                runtimeKeyState = .valid
                controlPlaneState = .ready
                endpointState = .ready
                tunnelRetryAttempt = 0
                tunnelSelfHealAttempt = 0
                nextTunnelRetryAt = nil
                tunnelNotReadySince = nil
                tunnelState = .connected
                tunnelMessage = nil
            } else {
                tunnelNotReadySince = Date()
                tunnelState = .connecting
                runtimeKeyState = .checking
                controlPlaneState = .recovering
                endpointState = .recovering
                tunnelMessage = "tunnel-client 已启动，Runtime Key 与控制面正在恢复"
            }
        } catch {
            proxyStatus = await manager.proxyStatus()
            transportProcessRunning = false
            transportProcessIdentifier = nil
            remoteEndpointReady = false
            tunnelRetryAttempt += 1
            let delay = tunnelRetryDelay(for: tunnelRetryAttempt)
            nextTunnelRetryAt = Date().addingTimeInterval(delay)
            let message = error.localizedDescription
            let authenticationFailed = BridgeHealthPolicy.isTerminalAuthenticationFailure(message)
            runtimeKeyState = authenticationFailed ? .invalid : .checking
            controlPlaneState = authenticationFailed ? .failed : .recovering
            endpointState = authenticationFailed ? .failed : .recovering
            tunnelState = authenticationFailed ? .failed : .connecting
            tunnelMessage = authenticationFailed
                ? "OpenAI Tunnel 连接失败：\(message)"
                : "OpenAI Tunnel 正在恢复：\(message)。\(Int(delay)) 秒后重试"
        }
        writeRuntimeState(agent: .running, mcp: .ready)
    }

    private func tunnelRetryDelay(for attempt: Int) -> TimeInterval {
        let delays: [TimeInterval] = [1, 2, 4, 8, 15, 30]
        let index = min(max(attempt - 1, 0), delays.count - 1)
        return delays[index]
    }

    private func restartCompatibility() async {
        guard let compatibility = configuration.httpsCompatibility else {
            tunnelState = .disabled
            tunnelMessage = nil
            proxyStatus = nil
            transportProcessRunning = false
            transportProcessIdentifier = nil
            remoteEndpointReady = false
            runtimeKeyState = .notRequired
            controlPlaneState = .waiting
            endpointState = .waiting
            return
        }
        if let existing = compatibilityManager { await existing.stop() }
        transportProcessRunning = false
        transportProcessIdentifier = nil
        remoteEndpointReady = false
        proxyStatus = nil
        runtimeKeyState = .notRequired
        controlPlaneState = .recovering
        endpointState = .recovering
        tunnelState = .connecting
        tunnelMessage = "正在建立公网 HTTPS 连接"
        writeRuntimeState(agent: .running, mcp: .ready)

        do {
            let manager = HTTPSCompatibilityManager(paths: paths)
            compatibilityManager = manager
            _ = try await manager.start(
                configuration: compatibility,
                localMCPAccessToken: compatibilityAccessToken
            )
            transportProcessRunning = await manager.isProcessRunning()
            transportProcessIdentifier = await manager.processIdentifier()
            remoteEndpointReady = false
            tunnelState = .connecting
            tunnelMessage = "cloudflared 已启动，正在探测公网 HTTPS 端点"
        } catch {
            transportProcessRunning = false
            transportProcessIdentifier = nil
            remoteEndpointReady = false
            controlPlaneState = .failed
            endpointState = .failed
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
        throw BridgeError.permissionDenied("OpenAI 本地管道已配置，但本地凭据中没有 runtime API key")
    }

    private func refreshIntegrationRuntimeState() async {
        let entries = (try? await AuditLogger(paths: paths).entries()) ?? []
        if let latest = entries.max(by: { $0.timestamp < $1.timestamp }), latest.timestamp >= startedAt {
            lastToolCallAt = latest.timestamp
            lastToolCallName = latest.tool
            lastToolCallSucceeded = latest.status == .success
            lastToolCallMessage = latest.summary
        } else {
            lastToolCallAt = nil
            lastToolCallName = nil
            lastToolCallSucceeded = nil
            lastToolCallMessage = nil
        }
        writeRuntimeState(agent: .running, mcp: .ready)
    }

    private func makeHealthSnapshot(
        agent: AgentRuntimeState,
        mcp: MCPRuntimeState
    ) -> BridgeHealthSnapshot {
        let agentState: BridgeNodeState = switch agent {
        case .running: .ready
        case .starting: .connecting
        case .failed: .failed
        case .stopped: .waiting
        }
        let mcpState: BridgeNodeState = switch mcp {
        case .ready: .ready
        case .starting: .connecting
        case .failed: .failed
        case .stopped: .waiting
        }
        let processState: BridgeNodeState = {
            if transportProcessRunning { return .ready }
            if tunnelState == .failed { return .failed }
            if tunnelState == .connecting { return .recovering }
            return .waiting
        }()
        return BridgeHealthSnapshot(
            agent: BridgeServiceHealth(
                state: agentState,
                processIdentifier: agent == .running ? ProcessInfo.processInfo.processIdentifier : nil
            ),
            mcp: BridgeServiceHealth(
                state: mcpState,
                message: mcp == .ready ? "127.0.0.1:\(mcpPort)" : nil
            ),
            tunnel: BridgeTunnelHealth(
                process: BridgeServiceHealth(
                    state: processState,
                    processIdentifier: transportProcessIdentifier,
                    message: tunnelMessage
                ),
                runtimeKey: runtimeKeyState,
                controlPlane: controlPlaneState,
                endpoint: endpointState
            )
        )
    }

    private func makePipelineDiagnostics(
        agent: AgentRuntimeState,
        mcp: MCPRuntimeState,
        health: BridgeHealthSnapshot
    ) -> BridgePipelineDiagnostics {
        let checkedAt = transportHealthCheckedAt ?? Date()
        let transportTitle = configuration.transportMode == .secureTunnel
            ? "Tunnel Client"
            : "cloudflared"
        let endpointTitle = configuration.transportMode == .secureTunnel
            ? "OpenAI Tunnel"
            : "公网 HTTPS"

        let endpointMessage: String = {
            switch health.tunnel.endpoint {
            case .ready: return "已连接"
            case .recovering:
                return runtimeKeyState == .checking ? "Runtime Key 刷新中" : "正在恢复"
            case .connecting: return "正在连接"
            case .waiting: return "等待连接"
            case .failed: return tunnelMessage ?? "连接失败"
            }
        }()
        let runtimeKeyDetail: String = switch runtimeKeyState {
        case .notRequired: "Runtime Key：不适用"
        case .checking: "Runtime Key：刷新中"
        case .valid: "Runtime Key：有效"
        case .invalid: "Runtime Key：无效"
        }
        let controlPlaneDetail: String = switch controlPlaneState {
        case .ready: "Control Plane：正常"
        case .connecting: "Control Plane：连接中"
        case .recovering: "Control Plane：恢复中"
        case .waiting: "Control Plane：等待"
        case .failed: "Control Plane：失败"
        }

        let chatGPTState: BridgeNodeState
        let chatGPTMessage: String
        if lastToolCallSucceeded == true, lastToolCallAt != nil {
            chatGPTState = .ready
            chatGPTMessage = "最近调用成功"
        } else if lastToolCallSucceeded == false, lastToolCallAt != nil {
            chatGPTState = .failed
            chatGPTMessage = lastToolCallMessage ?? "最近调用失败"
        } else if health.tunnel.endpoint == .ready {
            chatGPTState = .waiting
            chatGPTMessage = "等待首次调用"
        } else {
            chatGPTState = .waiting
            chatGPTMessage = "等待链路就绪"
        }

        return BridgePipelineDiagnostics(nodes: [
            BridgeNodeDiagnostic(
                id: "agent",
                title: "Harbor Agent",
                state: health.agent.state,
                message: agent == .running ? "已运行" : (agent == .starting ? "正在启动" : "未运行"),
                lastCheckAt: checkedAt,
                details: health.agent.processIdentifier.map { ["PID \($0)"] } ?? []
            ),
            BridgeNodeDiagnostic(
                id: "mcp",
                title: "Local MCP",
                state: health.mcp.state,
                message: mcp == .ready ? "MCP 正常" : "MCP 未就绪",
                lastCheckAt: checkedAt,
                details: [
                    "127.0.0.1:\(mcpPort)",
                    "tools：\(mcpToolCount) 个",
                    "工具目录：\(MCPToolCatalogMetadata.version)"
                ]
            ),
            BridgeNodeDiagnostic(
                id: "tunnel-client",
                title: transportTitle,
                state: health.tunnel.process.state,
                message: transportProcessRunning ? "已连接" : (tunnelMessage ?? "未运行"),
                lastCheckAt: checkedAt,
                details: transportProcessIdentifier.map { ["PID \($0)"] } ?? []
            ),
            BridgeNodeDiagnostic(
                id: "openai-tunnel",
                title: endpointTitle,
                state: health.tunnel.endpoint,
                message: endpointMessage,
                lastCheckAt: checkedAt,
                details: configuration.transportMode == .secureTunnel
                    ? [runtimeKeyDetail, controlPlaneDetail]
                    : ["公网端点：\(configuration.httpsCompatibility?.hostname ?? "未配置")"]
            ),
            BridgeNodeDiagnostic(
                id: "chatgpt-mcp",
                title: "ChatGPT MCP",
                state: chatGPTState,
                message: chatGPTMessage,
                lastCheckAt: lastToolCallAt,
                details: [lastToolCallName, lastToolCallMessage].compactMap { $0 }
            )
        ])
    }

    private func writeRuntimeState(agent: AgentRuntimeState, mcp: MCPRuntimeState) {
        let overall: BridgeOverallState = {
            if agent == .stopped { return .disabled }
            if tunnelState == .connected { return .ready }
            return .degraded
        }()
        let health = makeHealthSnapshot(agent: agent, mcp: mcp)
        pipelineDiagnostics = makePipelineDiagnostics(agent: agent, mcp: mcp, health: health)
        let state = BridgeRuntimeState(
            overall: overall,
            agent: agent,
            mcp: mcp,
            tunnel: tunnelState,
            chatGPT: chatGPTIntegrationState,
            transportMode: configuration.transportMode,
            publicMCPHost: configuration.transportMode == .httpsCompatibility
                ? configuration.httpsCompatibility?.hostname
                : nil,
            transportProcessRunning: transportProcessRunning,
            transportProcessIdentifier: transportProcessIdentifier,
            remoteEndpointReady: remoteEndpointReady,
            transportMessage: tunnelMessage,
            proxyStatus: proxyStatus,
            processIdentifier: agent == .running ? ProcessInfo.processInfo.processIdentifier : nil,
            mcpPort: mcp == .ready ? mcpPort : nil,
            mcpURL: mcp == .ready ? mcpURL.absoluteString : nil,
            toolCatalogVersion: mcp == .ready ? MCPToolCatalogMetadata.version : nil,
            toolCatalogCount: mcp == .ready ? MCPToolCatalogMetadata.toolCount : nil,
            startedAt: agent == .running ? startedAt : nil,
            lastToolCallAt: lastToolCallAt,
            transportHealthCheckedAt: transportHealthCheckedAt,
            controlPlaneLastSuccessAt: controlPlaneLastSuccessAt,
            controlPlanePollCycles: controlPlanePollCycles,
            controlPlanePollErrors: controlPlanePollErrors,
            lastToolCallName: lastToolCallName,
            lastToolCallSucceeded: lastToolCallSucceeded,
            lastToolCallMessage: lastToolCallMessage,
            health: health,
            pipelineDiagnostics: pipelineDiagnostics
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

    private var chatGPTIntegrationState: ChatGPTIntegrationState {
        switch configuration.transportMode {
        case .secureTunnel:
            guard configuration.secureTunnel != nil else { return .notConfigured }
            if let lastToolCallAt, lastToolCallAt >= startedAt {
                return .recentlyActive
            }
            return .configured

        case .httpsCompatibility:
            let store = ChatGPTIntegrationMarkerStore(paths: paths)
            guard store.matchesPublicHTTPS(hostname: configuration.httpsCompatibility?.hostname),
                  let marker = store.load() else {
                return .notConfigured
            }
            return Date().timeIntervalSince(marker.lastActivityAt) <= 600
                ? .recentlyActive
                : .configured
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
        if CommandLine.arguments.contains("--print-tool-catalog") {
            print("\(MCPToolCatalogMetadata.version)|\(MCPToolCatalogMetadata.toolCount)")
            return
        }

        let paths = try BridgePaths.live()
        try paths.ensureDirectories()

        let configuration = try BridgeConfigurationStore(paths: paths).load()
        let allowedRoots = AllowedRootsManager(
            roots: configuration.allowedRoots.map { URL(fileURLWithPath: $0, isDirectory: true) }
        )
        let workspaceManager = WorkspaceManager(
            allowedRoots: allowedRoots,
            persistenceURL: paths.workspacesURL
        )
        let auditLogger = AuditLogger(paths: paths)
        let approvalStore = BridgeApprovalStore(paths: paths)
        let workspaceSessionStore = WorkspaceSessionStore(
            persistenceURL: paths.workspaceSessionsURL
        )
        let toolRouter = ToolRouter(
            workspaceManager: workspaceManager,
            configuration: configuration,
            auditLogger: auditLogger,
            approvalStore: approvalStore,
            workspaceSessionStore: workspaceSessionStore
        )
        let secretStore = BridgeSecretStore()
        let localMCPAccessToken = try secretStore.localMCPAccessToken()
        let compatibilityAccessToken = try secretStore.httpsCompatibilityAccessToken()
        let integrationStore = ChatGPTIntegrationMarkerStore(paths: paths)
        let httpServer = LocalMCPHTTPServer(
            server: MCPServer(router: toolRouter),
            accessToken: localMCPAccessToken,
            publicAccessToken: compatibilityAccessToken,
            onPublicClientInitialized: {
                guard configuration.transportMode == .httpsCompatibility,
                      let hostname = configuration.httpsCompatibility?.hostname else { return }

                let now = Date()
                let existing = integrationStore.load()
                let configuredAt: Date
                if existing?.transportMode == .httpsCompatibility,
                   existing?.hostname?.caseInsensitiveCompare(hostname) == .orderedSame {
                    configuredAt = existing?.configuredAt ?? now
                } else {
                    configuredAt = now
                }

                try? integrationStore.save(
                    ChatGPTIntegrationMarker(
                        transportMode: .httpsCompatibility,
                        hostname: hostname,
                        configuredAt: configuredAt,
                        lastActivityAt: now,
                        discoveredToolCatalogVersion: existing?.discoveredToolCatalogVersion,
                        discoveredToolCount: existing?.discoveredToolCount,
                        catalogDiscoveredAt: existing?.catalogDiscoveredAt
                    )
                )
            },
            onToolCatalogDiscovered: {
                let now = Date()
                let existing = integrationStore.load()
                let hostname = configuration.transportMode == .httpsCompatibility
                    ? configuration.httpsCompatibility?.hostname
                    : nil
                let sameTransport = existing?.transportMode == configuration.transportMode
                let sameHost = configuration.transportMode == .secureTunnel
                    || existing?.hostname?.caseInsensitiveCompare(hostname ?? "") == .orderedSame
                let configuredAt = sameTransport && sameHost
                    ? (existing?.configuredAt ?? now)
                    : now

                try? integrationStore.save(
                    ChatGPTIntegrationMarker(
                        transportMode: configuration.transportMode,
                        hostname: hostname,
                        configuredAt: configuredAt,
                        lastActivityAt: now,
                        discoveredToolCatalogVersion: MCPToolCatalogMetadata.version,
                        discoveredToolCount: MCPToolCatalogMetadata.toolCount,
                        catalogDiscoveredAt: now
                    )
                )
            }
        )
        let mcpPort = try httpServer.start(preferredPort: configuration.localMCPPort)
        guard let mcpURL = URL(string: "http://\(LocalMCPHTTPServer.host):\(mcpPort)/mcp") else {
            throw BridgeError.invalidPath("MCP URL")
        }

        let lifecycle = AgentLifecycle(
            paths: paths,
            configuration: configuration,
            httpServer: httpServer,
            mcpPort: mcpPort,
            mcpURL: mcpURL,
            mcpToolCount: await toolRouter.definitions().count,
            localMCPAccessToken: localMCPAccessToken,
            compatibilityAccessToken: compatibilityAccessToken
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
