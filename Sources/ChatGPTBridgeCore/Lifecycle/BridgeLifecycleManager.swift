import Darwin
import Foundation

public enum BridgeLifecyclePhase: String, Sendable {
    case idle
    case starting
    case running
    case stopping
    case switching
    case recovering
    case failed
}

public struct BridgeLifecycleSnapshot: Sendable {
    public let configuration: BridgeConfiguration
    public let runtime: BridgeRuntimeState
    public let launchAgentStatus: BridgeLaunchAgentStatus
    public let processRunning: Bool
    public let mcpHealthy: Bool

    public var localReady: Bool {
        processRunning && runtime.agent == .running && runtime.mcp == .ready && mcpHealthy
    }

    public var overallReady: Bool {
        localReady && runtime.tunnel == .connected
    }

    public init(
        configuration: BridgeConfiguration,
        runtime: BridgeRuntimeState,
        launchAgentStatus: BridgeLaunchAgentStatus,
        processRunning: Bool,
        mcpHealthy: Bool
    ) {
        self.configuration = configuration
        self.runtime = runtime
        self.launchAgentStatus = launchAgentStatus
        self.processRunning = processRunning
        self.mcpHealthy = mcpHealthy
    }
}

/// Serializes every operation that changes the ChatGPT Bridge runtime.
///
/// The app owns this coordinator. The helper process still owns MCP and
/// transport implementation details; this actor owns configuration/process
/// transitions so a new operation can never race an unfinished stop/start.
public actor BridgeLifecycleManager {
    public private(set) var phase: BridgeLifecyclePhase = .idle

    private let paths: BridgePaths
    private let store: BridgeConfigurationStore
    private let secretStore: BridgeSecretStore
    private let launchAgentManager: BridgeLaunchAgentManager

    public init(
        paths: BridgePaths,
        store: BridgeConfigurationStore? = nil,
        secretStore: BridgeSecretStore? = nil,
        launchAgentManager: BridgeLaunchAgentManager = BridgeLaunchAgentManager()
    ) {
        self.paths = paths
        self.store = store ?? BridgeConfigurationStore(paths: paths)
        self.secretStore = secretStore ?? BridgeSecretStore(url: paths.credentialsURL)
        self.launchAgentManager = launchAgentManager
    }

    public func start(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        phase = .starting
        do {
            guard !configuration.allowedRoots.isEmpty else {
                throw BridgeError.invalidPath("请先添加至少一个允许访问的开发目录")
            }
            guard FileManager.default.isExecutableFile(atPath: agentExecutableURL.path) else {
                throw BridgeError.invalidPath("HarborChatGPTAgent 不可执行：\(agentExecutableURL.path)")
            }

            // A start is always a clean replacement. This prevents a stale
            // helper or stale credential environment from surviving restart.
            await stopProcesses(configuration: configuration, agentExecutableURL: agentExecutableURL)
            guard await waitUntilPortIsAvailable(configuration.localMCPPort) else {
                let pids = Self.listeningProcessIdentifiers(on: configuration.localMCPPort)
                let detail = pids.isEmpty ? "未知进程" : "PID \(pids.map(String.init).joined(separator: ", "))"
                throw BridgeError.writeFailed(
                    "已停止旧 Agent，但 127.0.0.1:\(configuration.localMCPPort) 仍被 \(detail) 占用"
                )
            }

            if configuration.launchAtLogin {
                _ = try launchAgentManager.install(agentExecutableURL: agentExecutableURL, paths: paths)
            } else {
                try startManually(agentExecutableURL: agentExecutableURL)
            }

            var snapshot = await healthCheck(configuration: configuration)
            for _ in 0..<20 where !snapshot.localReady {
                try await Task.sleep(for: .milliseconds(200))
                snapshot = await healthCheck(configuration: configuration)
                if snapshot.runtime.agent == .failed || snapshot.runtime.mcp == .failed {
                    break
                }
            }
            guard snapshot.localReady else {
                phase = .failed
                throw BridgeError.writeFailed("本地 Agent 未能在 127.0.0.1:\(configuration.localMCPPort) 建立可用 MCP 服务")
            }
            phase = .running
            return snapshot
        } catch {
            phase = .failed
            throw error
        }
    }

    public func stop(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL?
    ) async -> BridgeLifecycleSnapshot {
        phase = .stopping
        await stopProcesses(configuration: configuration, agentExecutableURL: agentExecutableURL)
        phase = .idle
        return await healthCheck(configuration: configuration)
    }

    public func restart(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        // start() deliberately performs a complete stop first.
        try await start(configuration: configuration, agentExecutableURL: agentExecutableURL)
    }

    public func switchTransport(
        to mode: BridgeTransportMode,
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        phase = .switching
        try validateConfigured(mode, configuration: configuration)

        let previous = configuration
        var updated = configuration
        updated.transportMode = mode
        try store.save(updated)

        guard updated.enabled else {
            phase = .idle
            return await healthCheck(configuration: updated)
        }

        do {
            let snapshot = try await start(configuration: updated, agentExecutableURL: agentExecutableURL)
            phase = .running
            return snapshot
        } catch {
            // Configuration and process recovery are one transaction. If the
            // new helper cannot expose a local MCP endpoint, restore both.
            try? store.save(previous)
            _ = try? await start(configuration: previous, agentExecutableURL: agentExecutableURL)
            phase = .failed
            throw error
        }
    }

    public func recover(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL
    ) async throws -> BridgeLifecycleSnapshot {
        phase = .recovering
        guard configuration.enabled else {
            phase = .idle
            return await healthCheck(configuration: configuration)
        }

        let snapshot = await healthCheck(configuration: configuration)
        let binaryChanged = launchAgentManager.needsRestart(
            agentExecutableURL: agentExecutableURL,
            runtime: snapshot.runtime
        )
        let launchAgentMissing = configuration.launchAtLogin && !snapshot.launchAgentStatus.loaded
        if binaryChanged || launchAgentMissing || !snapshot.processRunning || !snapshot.mcpHealthy {
            return try await start(configuration: configuration, agentExecutableURL: agentExecutableURL)
        }

        // Transport/network recovery stays inside the running helper so MCP
        // workspace sessions survive. Do not restart a healthy local server
        // merely because the remote transport is reconnecting.
        phase = .running
        return snapshot
    }

    @discardableResult
    public func refreshRuntimeKey(
        _ runtimeKey: String,
        configuration: BridgeConfiguration,
        agentExecutableURL: URL?,
        restartIfActive: Bool = true
    ) async throws -> BridgeLifecycleSnapshot {
        let value = runtimeKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else {
            throw BridgeError.writeFailed("Runtime Key 不能为空")
        }
        try secretStore.set(value, for: .tunnelRuntimeAPIKey)
        guard try secretStore.string(for: .tunnelRuntimeAPIKey) == value else {
            throw BridgeError.writeFailed("Runtime Key 保存后校验失败")
        }

        if restartIfActive,
           configuration.enabled,
           configuration.transportMode == .secureTunnel,
           let agentExecutableURL {
            return try await restart(
                configuration: configuration,
                agentExecutableURL: agentExecutableURL
            )
        }
        phase = configuration.enabled ? .running : .idle
        return await healthCheck(configuration: configuration)
    }

    public func healthCheck(configuration: BridgeConfiguration) async -> BridgeLifecycleSnapshot {
        let runtime = loadRuntime()
        let processRunning = runtime.processIdentifier.map(Self.processExists) == true
        let repairedRuntime: BridgeRuntimeState
        if runtime.processIdentifier != nil && !processRunning {
            repairedRuntime = BridgeRuntimeState(transportMode: configuration.transportMode)
        } else {
            repairedRuntime = runtime
        }
        let healthy = processRunning
            ? await checkMCPHealth(runtime: repairedRuntime)
            : false
        return BridgeLifecycleSnapshot(
            configuration: configuration,
            runtime: repairedRuntime,
            launchAgentStatus: launchAgentManager.status(),
            processRunning: processRunning,
            mcpHealthy: healthy
        )
    }

    private func validateConfigured(
        _ mode: BridgeTransportMode,
        configuration: BridgeConfiguration
    ) throws {
        switch mode {
        case .secureTunnel:
            guard configuration.secureTunnel != nil,
                  let key = try secretStore.string(for: .tunnelRuntimeAPIKey),
                  !key.isEmpty else {
                throw BridgeError.writeFailed("OpenAI 本地管道尚未完整配置")
            }
        case .httpsCompatibility:
            guard configuration.httpsCompatibility != nil else {
                throw BridgeError.writeFailed("公网 HTTPS 尚未完整配置")
            }
        }
    }

    private func startManually(agentExecutableURL: URL) throws {
        let process = Process()
        process.executableURL = agentExecutableURL
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        var environment = ProcessInfo.processInfo.environment
        if let runtimeKey = try secretStore.string(for: .tunnelRuntimeAPIKey), !runtimeKey.isEmpty {
            environment["HARBOR_BRIDGE_TUNNEL_API_KEY"] = runtimeKey
        }
        process.environment = environment
        try process.run()
    }

    private func stopProcesses(
        configuration: BridgeConfiguration,
        agentExecutableURL: URL?
    ) async {
        try? launchAgentManager.uninstall()

        let storedRuntime = loadRuntime()
        let agentPaths = [agentExecutableURL?.path].compactMap { $0 }
        let transportPaths = [
            configuration.secureTunnel?.executablePath,
            configuration.httpsCompatibility?.cloudflaredPath
        ].compactMap { value -> String? in
            guard let value, !value.isEmpty else { return nil }
            return value
        }

        // Only terminate PIDs that can be verified as Harbor-owned. A random
        // process listening on the configured port must never be killed.
        var processIdentifiers = Set<Int32>()
        if let pid = storedRuntime.processIdentifier,
           pid > 0,
           Self.processMatches(pid, executablePaths: agentPaths) {
            processIdentifiers.insert(pid)
        }
        if let pid = storedRuntime.transportProcessIdentifier,
           pid > 0,
           Self.processMatches(pid, executablePaths: transportPaths) {
            processIdentifiers.insert(pid)
        }
        for pid in Self.listeningProcessIdentifiers(on: configuration.localMCPPort)
        where Self.processMatches(pid, executablePaths: agentPaths) {
            processIdentifiers.insert(pid)
        }

        for pid in processIdentifiers where pid != ProcessInfo.processInfo.processIdentifier {
            _ = Darwin.kill(pid, SIGTERM)
        }

        for _ in 0..<50 {
            if !processIdentifiers.contains(where: Self.processExists) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }

        for pid in processIdentifiers
        where pid != ProcessInfo.processInfo.processIdentifier && Self.processExists(pid) {
            _ = Darwin.kill(pid, SIGKILL)
        }

        // Do not force-clear an occupied port here. start() performs the final
        // availability check and reports the unknown owner instead.
        for _ in 0..<25 {
            if Self.isLoopbackPortAvailable(configuration.localMCPPort) { break }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    private func loadRuntime() -> BridgeRuntimeState {
        guard let data = try? Data(contentsOf: paths.runtimeURL) else {
            return BridgeRuntimeState()
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return (try? decoder.decode(BridgeRuntimeState.self, from: data)) ?? BridgeRuntimeState()
    }

    private func checkMCPHealth(runtime: BridgeRuntimeState) async -> Bool {
        guard let port = runtime.mcpPort,
              let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        for attempt in 0..<3 {
            var request = URLRequest(url: url)
            request.timeoutInterval = 1.5
            do {
                let (_, response) = try await URLSession.shared.data(for: request)
                if (response as? HTTPURLResponse)?.statusCode == 200 { return true }
            } catch {
                if attempt < 2 { try? await Task.sleep(for: .milliseconds(300)) }
            }
        }
        return false
    }

    private func waitUntilPortIsAvailable(_ port: UInt16) async -> Bool {
        for _ in 0..<25 {
            if Self.isLoopbackPortAvailable(port) { return true }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Self.isLoopbackPortAvailable(port)
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    private static func listeningProcessIdentifiers(on port: UInt16) -> [Int32] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        process.arguments = ["-nP", "-t", "-iTCP:\(port)", "-sTCP:LISTEN"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return []
        }
        return String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            .split(whereSeparator: \.isNewline)
            .compactMap { Int32($0) }
    }

    private static func processMatches(_ pid: Int32, executablePaths: [String]) -> Bool {
        guard pid > 0, !executablePaths.isEmpty else { return false }
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-p", String(pid), "-o", "command="]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return false
        }
        guard process.terminationStatus == 0 else { return false }
        let command = String(
            decoding: output.fileHandleForReading.readDataToEndOfFile(),
            as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        return executablePaths.contains { path in
            command == path || command.hasPrefix(path + " ")
        }
    }

    private static func isLoopbackPortAvailable(_ port: UInt16) -> Bool {
        listeningProcessIdentifiers(on: port).isEmpty
    }
}
