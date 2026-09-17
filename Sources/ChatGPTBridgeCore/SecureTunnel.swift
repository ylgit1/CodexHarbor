import Foundation

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

    public init(
        executableURL: URL,
        arguments: [String],
        environment: [String: String],
        healthURLFile: URL,
        pidFile: URL
    ) {
        self.executableURL = executableURL
        self.arguments = arguments
        self.environment = environment
        self.healthURLFile = healthURLFile
        self.pidFile = pidFile
    }
}

public struct TunnelClientLocator: Sendable {
    public init() {}

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
        case .unavailable: throw BridgeError.invalidPath("未找到 tunnel-client")
        }

        try paths.ensureDirectories()
        let healthURLFile = paths.root.appendingPathComponent("tunnel-health.url")
        let pidFile = paths.root.appendingPathComponent("tunnel.pid")
        var environment = baseEnvironment
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
            pidFile: pidFile
        )
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
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { _ in }

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
        guard case .running(_, let baseURL) = state, let baseURL else { return false }
        let readyURL = baseURL.appendingPathComponent("readyz")
        var request = URLRequest(url: readyURL)
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
