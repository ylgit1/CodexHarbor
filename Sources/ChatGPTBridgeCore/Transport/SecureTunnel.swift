import Foundation
import SystemConfiguration

public enum TunnelClientAvailability: Equatable, Sendable {
    case available(URL)
    case unavailable
}

public struct TunnelClientLaunchPlan: Equatable, Sendable {
    public let executableURL: URL
    public let arguments: [String]
    public let environment: [String: String]
    public let healthURLFile: URL
    public let pidFile: URL
    public let logFile: URL

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        healthURLFile: URL,
        pidFile: URL,
        logFile: URL
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.healthURLFile = healthURLFile
        self.pidFile = pidFile
        self.logFile = logFile
    }
}

public struct TunnelClientLocator: Sendable {
    public init() {}

    public func locatedPath(preferredPath: String? = nil) -> String? {
        guard case .available(let url) = locate(preferredPath: preferredPath) else { return nil }
        return url.path
    }

    public func locate(preferredPath: String? = nil) -> TunnelClientAvailability {
        let candidates: [URL] = [
            preferredPath.map { URL(fileURLWithPath: $0) },
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/tunnel-client"),
            URL(fileURLWithPath: "/opt/homebrew/bin/tunnel-client"),
            URL(fileURLWithPath: "/usr/local/bin/tunnel-client"),
            URL(fileURLWithPath: "/usr/bin/tunnel-client")
        ].compactMap { $0 }

        for candidate in candidates {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: candidate.path, isDirectory: &isDirectory),
               !isDirectory.boolValue,
               FileManager.default.isExecutableFile(atPath: candidate.path) {
                return .available(candidate.standardizedFileURL)
            }
        }
        return .unavailable
    }
}

public enum SecureTunnelManagerState: Equatable, Sendable {
    case stopped
    case starting
    case running(processIdentifier: Int32, healthBaseURL: URL?)
    case failed(String)
}

public struct SecureTunnelHealthSnapshot: Equatable, Sendable {
    public let live: Bool
    public let ready: Bool
    public let checkedAt: Date
    public let controlPlaneLastSuccessAt: Date?
    public let controlPlanePollCycles: Int
    public let controlPlanePollErrors: Int

    public init(
        live: Bool,
        ready: Bool,
        checkedAt: Date = Date(),
        controlPlaneLastSuccessAt: Date? = nil,
        controlPlanePollCycles: Int = 0,
        controlPlanePollErrors: Int = 0
    ) {
        self.live = live
        self.ready = ready
        self.checkedAt = checkedAt
        self.controlPlaneLastSuccessAt = controlPlaneLastSuccessAt
        self.controlPlanePollCycles = controlPlanePollCycles
        self.controlPlanePollErrors = controlPlanePollErrors
    }
}

public actor SecureTunnelManager {
    private let paths: BridgePaths
    private let locator: TunnelClientLocator
    private var process: Process?
    private var state: SecureTunnelManagerState = .stopped

    public init(paths: BridgePaths, locator: TunnelClientLocator = TunnelClientLocator()) {
        self.paths = paths
        self.locator = locator
    }

    public func currentState() -> SecureTunnelManagerState {
        state
    }

    public func isProcessRunning() -> Bool {
        process?.isRunning == true
    }

    public func processIdentifier() -> Int32? {
        guard process?.isRunning == true else { return nil }
        return process?.processIdentifier
    }

    public func makeLaunchPlan(
        configuration: SecureTunnelConfiguration,
        mcpURL: URL,
        runtimeAPIKey: String,
        localMCPAccessToken: String? = nil,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> TunnelClientLaunchPlan {
        let tunnelID = configuration.tunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tunnelID.isEmpty else {
            throw BridgeError.invalidPath("Secure MCP Tunnel ID 不能为空")
        }
        guard mcpURL.host == "127.0.0.1" || mcpURL.host == "localhost" else {
            throw BridgeError.invalidPath("MCP Server 必须绑定本机 loopback")
        }
        guard !runtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw BridgeError.permissionDenied("缺少 Secure MCP Tunnel runtime API key")
        }

        let executable: URL
        switch locator.locate(preferredPath: configuration.executablePath) {
        case .available(let url): executable = url
        case .unavailable: throw BridgeError.invalidPath("配置存在，但 tunnel-client 不可用，需要重新安装或检查路径")
        }

        try paths.ensureDirectories()
        let healthURLFile = paths.root.appendingPathComponent("tunnel-health.url")
        let pidFile = paths.root.appendingPathComponent("tunnel.pid")
        let logFile = paths.root.appendingPathComponent("tunnel-client.log")
        var environment = baseEnvironment
        Self.applySystemProxyEnvironment(to: &environment)
        environment["CONTROL_PLANE_API_KEY"] = runtimeAPIKey
        environment["CONTROL_PLANE_TUNNEL_ID"] = tunnelID
        environment["CONTROL_PLANE_BASE_URL"] = configuration.controlPlaneBaseURL
        environment["MCP_SERVER_URL"] = mcpURL.absoluteString
        let localToken = localMCPAccessToken?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let localToken, !localToken.isEmpty {
            environment["HARBOR_LOCAL_MCP_TOKEN"] = localToken
        }

        var arguments = [
            "run",
            "--control-plane.tunnel-id", tunnelID,
            "--mcp.server-url", mcpURL.absoluteString,
            "--health.listen-addr", "127.0.0.1:0",
            "--health.url-file", healthURLFile.path,
            "--pid.file", pidFile.path,
            "--log.level", "info",
            "--log.format", "json"
        ]
        if localToken?.isEmpty == false {
            let header = "X-Harbor-Bridge-Token: env:HARBOR_LOCAL_MCP_TOKEN"
            arguments += ["--mcp.extra-headers", header]
            arguments += ["--mcp.discovery-extra-headers", header]
        }
        return TunnelClientLaunchPlan(
            executableURL: executable,
            arguments: arguments,
            environment: environment,
            healthURLFile: healthURLFile,
            pidFile: pidFile,
            logFile: logFile
        )
    }

    private static func applySystemProxyEnvironment(to environment: inout [String: String]) {
        let hasExplicitProxy = ["HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy", "ALL_PROXY", "all_proxy"]
            .contains { key in
                guard let value = environment[key] else { return false }
                return !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
        guard !hasExplicitProxy,
              let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else {
            return
        }

        func enabled(_ key: CFString) -> Bool {
            (settings[key as String] as? NSNumber)?.boolValue == true
        }

        func host(_ key: CFString) -> String? {
            guard let raw = settings[key as String] as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        func port(_ key: CFString) -> Int? {
            (settings[key as String] as? NSNumber)?.intValue
        }

        if enabled(kSCPropNetProxiesHTTPEnable),
           let proxyHost = host(kSCPropNetProxiesHTTPProxy),
           let proxyPort = port(kSCPropNetProxiesHTTPPort) {
            let proxy = "http://\(proxyHost):\(proxyPort)"
            environment["HTTP_PROXY"] = proxy
            environment["http_proxy"] = proxy
        }

        if enabled(kSCPropNetProxiesHTTPSEnable),
           let proxyHost = host(kSCPropNetProxiesHTTPSProxy),
           let proxyPort = port(kSCPropNetProxiesHTTPSPort) {
            let proxy = "http://\(proxyHost):\(proxyPort)"
            environment["HTTPS_PROXY"] = proxy
            environment["https_proxy"] = proxy
        }

        if enabled(kSCPropNetProxiesSOCKSEnable),
           let proxyHost = host(kSCPropNetProxiesSOCKSProxy),
           let proxyPort = port(kSCPropNetProxiesSOCKSPort) {
            let proxy = "socks5://\(proxyHost):\(proxyPort)"
            environment["ALL_PROXY"] = proxy
            environment["all_proxy"] = proxy
        }

        let existingNoProxy = environment["NO_PROXY"] ?? environment["no_proxy"] ?? ""
        let requiredNoProxy = ["127.0.0.1", "localhost", "::1"]
        let merged = ([existingNoProxy] + requiredNoProxy)
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let noProxy = Array(Set(merged)).sorted().joined(separator: ",")
        environment["NO_PROXY"] = noProxy
        environment["no_proxy"] = noProxy
    }

    public func start(
        configuration: SecureTunnelConfiguration,
        mcpURL: URL,
        runtimeAPIKey: String,
        localMCPAccessToken: String? = nil
    ) async throws -> SecureTunnelManagerState {
        if case .running = state { return state }
        state = .starting
        let plan = try makeLaunchPlan(
            configuration: configuration,
            mcpURL: mcpURL,
            runtimeAPIKey: runtimeAPIKey,
            localMCPAccessToken: localMCPAccessToken
        )

        let process = Process()
        process.executableURL = plan.executableURL
        process.arguments = plan.arguments
        process.environment = plan.environment

        try? FileManager.default.createDirectory(
            at: plan.logFile.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        BridgeLogRotator.rotateIfNeeded(plan.logFile)
        if !FileManager.default.fileExists(atPath: plan.logFile.path) {
            FileManager.default.createFile(atPath: plan.logFile.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: plan.logFile)
        _ = try? logHandle?.seekToEnd()
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        process.terminationHandler = { _ in
            try? logHandle?.close()
        }

        do {
            try? FileManager.default.removeItem(at: plan.healthURLFile)
            try? FileManager.default.removeItem(at: plan.pidFile)
            try process.run()
            self.process = process

            let deadline = Date().addingTimeInterval(10)
            var healthURL: URL?
            while Date() < deadline {
                if !process.isRunning {
                    state = .failed("tunnel-client 启动后立即退出")
                    throw BridgeError.writeFailed("tunnel-client 启动后立即退出")
                }
                if let text = try? String(contentsOf: plan.healthURLFile, encoding: .utf8),
                   let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) {
                    healthURL = url
                    break
                }
                try await Task.sleep(for: .milliseconds(150))
            }
            state = .running(processIdentifier: process.processIdentifier, healthBaseURL: healthURL)
            return state
        } catch {
            process.terminate()
            self.process = nil
            state = .failed(error.localizedDescription)
            throw error
        }
    }

    public func stop() async {
        guard let process else {
            state = .stopped
            return
        }
        if process.isRunning {
            process.terminate()
            let deadline = Date().addingTimeInterval(2)
            while process.isRunning && Date() < deadline {
                try? await Task.sleep(for: .milliseconds(100))
            }
            if process.isRunning { process.interrupt() }
        }
        self.process = nil
        state = .stopped
    }

    public func readiness() async -> Bool {
        await healthSnapshot().ready
    }

    public func healthSnapshot() async -> SecureTunnelHealthSnapshot {
        let checkedAt = Date()
        guard case .running(_, let baseURL) = state, let baseURL else {
            return SecureTunnelHealthSnapshot(live: false, ready: false, checkedAt: checkedAt)
        }

        async let live = endpointIsHealthy(baseURL.appendingPathComponent("healthz"))
        async let ready = endpointIsHealthy(baseURL.appendingPathComponent("readyz"))
        async let metrics = fetchMetrics(baseURL.appendingPathComponent("metrics"))
        let parsed = Self.parseControlPlaneMetrics(await metrics)
        return SecureTunnelHealthSnapshot(
            live: await live,
            ready: await ready,
            checkedAt: checkedAt,
            controlPlaneLastSuccessAt: parsed.lastSuccessAt,
            controlPlanePollCycles: parsed.pollCycles,
            controlPlanePollErrors: parsed.pollErrors
        )
    }

    private func endpointIsHealthy(_ url: URL) async -> Bool {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func fetchMetrics(_ url: URL) async -> String? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 3
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func parseControlPlaneMetrics(_ text: String?) -> (
        lastSuccessAt: Date?, pollCycles: Int, pollErrors: Int
    ) {
        guard let text else { return (nil, 0, 0) }
        var lastSuccess: TimeInterval?
        var pollCycles = 0.0
        var pollErrors = 0.0

        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let fields = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard !line.hasPrefix("#"), fields.count >= 2,
                  let value = Double(fields[fields.count - 1]) else { continue }
            let metricName = fields[0].split(separator: "{", maxSplits: 1).first.map(String.init) ?? ""
            if metricName == "commands_poll_last_successful_timestamp_seconds" {
                lastSuccess = value
            } else if metricName == "commands_poll_cycles_total" {
                pollCycles += value
            } else if metricName == "commands_poll_errors_total" {
                pollErrors += value
            }
        }
        return (
            lastSuccess.flatMap { $0 > 0 ? Date(timeIntervalSince1970: $0) : nil },
            Int(pollCycles),
            Int(pollErrors)
        )
    }

    public func latestIssue() -> String? {
        let logURL = paths.root.appendingPathComponent("tunnel-client.log")
        guard let data = try? Data(contentsOf: logURL),
              !data.isEmpty else { return nil }

        let tail = data.suffix(64 * 1_024)
        let text = String(decoding: tail, as: UTF8.self)
        // The log file is shared across process restarts. Only inspect the
        // latest control-plane run; otherwise an old 401 makes a newly
        // connected Runtime Key look permanently invalid in the UI.
        let currentRun: Substring
        if let marker = text.range(of: "starting control-plane poller", options: .backwards) {
            currentRun = text[marker.lowerBound...]
        } else {
            currentRun = text[...]
        }
        let lowered = currentRun.lowercased()

        if lowered.contains("429") || lowered.contains("rate limit") || lowered.contains("too many requests") {
            return "OpenAI Tunnel 返回 429 限流；已保持当前进程并降低重连频率"
        }
        if lowered.contains("token_invalidated") {
            return "正在验证 Runtime Key，请稍候；如果持续失败，请在本地管道配置中更新"
        }
        if lowered.contains("401") || lowered.contains("unauthorized") || lowered.contains("invalid api key") {
            return "OpenAI Tunnel 鉴权失败，请检查 Runtime Key"
        }
        if lowered.contains("403") || lowered.contains("forbidden") {
            return "OpenAI Tunnel 拒绝访问，请检查 Tunnel ID 与 Runtime Key 是否匹配"
        }
        if lowered.contains("timeout") || lowered.contains("timed out") {
            return "OpenAI Tunnel 连接超时，正在等待网络恢复"
        }

        return nil
    }
}
