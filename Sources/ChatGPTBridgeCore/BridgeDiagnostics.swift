import Darwin
import Foundation

public enum BridgeDiagnosticStatus: String, Codable, Sendable {
    case passed
    case warning
    case failed
}

public struct BridgeDiagnosticResult: Codable, Identifiable, Equatable, Sendable {
    public let id: String
    public let title: String
    public let status: BridgeDiagnosticStatus
    public let message: String
    public let durationMilliseconds: Int

    public init(
        id: String,
        title: String,
        status: BridgeDiagnosticStatus,
        message: String,
        durationMilliseconds: Int
    ) {
        self.id = id
        self.title = title
        self.status = status
        self.message = message
        self.durationMilliseconds = durationMilliseconds
    }
}

public struct BridgeDiagnosticsRunner: Sendable {
    private let secretStore: BridgeSecretStore

    public init(secretStore: BridgeSecretStore = BridgeSecretStore()) {
        self.secretStore = secretStore
    }

    public func run(
        paths: BridgePaths,
        configuration: BridgeConfiguration,
        runtime: BridgeRuntimeState,
        launchAgentStatus: BridgeLaunchAgentStatus
    ) async -> [BridgeDiagnosticResult] {
        var results: [BridgeDiagnosticResult] = []
        results.append(measure(id: "storage", title: "Bridge 数据目录") {
            FileManager.default.fileExists(atPath: paths.root.path)
                ? (.passed, paths.root.path)
                : (.failed, "Bridge 数据目录不存在")
        })
        results.append(measure(id: "roots", title: "允许访问目录") {
            guard !configuration.allowedRoots.isEmpty else {
                return (.failed, "尚未配置允许访问的开发目录")
            }
            let unavailable = configuration.allowedRoots.filter { path in
                var isDirectory: ObjCBool = false
                return !FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) || !isDirectory.boolValue
            }
            return unavailable.isEmpty
                ? (.passed, "\(configuration.allowedRoots.count) 个目录可访问")
                : (.failed, "\(unavailable.count) 个目录不存在或不可访问")
        })
        results.append(measure(id: "agent", title: "Local Agent") {
            guard let pid = runtime.processIdentifier, Self.processExists(pid), runtime.agent == .running else {
                return configuration.enabled
                    ? (.failed, "已启用，但 Agent 当前没有运行")
                    : (.warning, "本地访问当前已关闭")
            }
            return (.passed, "PID \(pid)")
        })
        results.append(await checkMCP(runtime: runtime))
        results.append(measure(id: "tunnel-client", title: "Secure Tunnel Client") {
            switch TunnelClientLocator().locate(preferredPath: configuration.secureTunnel?.executablePath) {
            case .available(let url): return (.passed, url.path)
            case .unavailable:
                return configuration.secureTunnel == nil
                    ? (.warning, "尚未配置 Secure MCP Tunnel")
                    : (.failed, "已配置 Tunnel，但未找到 tunnel-client")
            }
        })
        results.append(measure(id: "tunnel-key", title: "Tunnel Runtime Key") {
            guard configuration.secureTunnel != nil else {
                return (.warning, "尚未配置 Secure MCP Tunnel")
            }
            do {
                let value = try secretStore.string(for: .tunnelRuntimeAPIKey)
                return value?.isEmpty == false
                    ? (.passed, "已安全保存在 macOS Keychain")
                    : (.failed, "Keychain 中没有 runtime API key")
            } catch {
                return (.failed, error.localizedDescription)
            }
        })
        results.append(measure(id: "tunnel", title: "Secure Tunnel") {
            guard configuration.secureTunnel != nil else {
                return (.warning, "尚未配置")
            }
            switch runtime.tunnel {
            case .connected: return (.passed, "安全通道已连接")
            case .connecting: return (.warning, "安全通道正在连接")
            case .failed: return (.failed, "安全通道连接失败")
            case .disabled: return (.failed, "已配置但当前未运行")
            }
        })
        results.append(measure(id: "launch-agent", title: "登录自动启动") {
            guard configuration.launchAtLogin else {
                return (.warning, "未启用登录自动启动")
            }
            if launchAgentStatus.installed && launchAgentStatus.loaded {
                return (.passed, "launchd 已托管 HarborChatGPTAgent")
            }
            return (.failed, "已开启设置，但 LaunchAgent 未正确加载")
        })
        results.append(measure(id: "codex-isolation", title: "Codex 隔离") {
            let bridgeRoot = paths.root.standardizedFileURL.path
            let codexHome = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").standardizedFileURL.path
            return bridgeRoot.hasPrefix(codexHome + "/") || bridgeRoot == codexHome
                ? (.failed, "Bridge 数据目录错误地位于 ~/.codex")
                : (.passed, "Bridge 使用独立数据目录、进程和端口")
        })
        return results
    }

    private func checkMCP(runtime: BridgeRuntimeState) async -> BridgeDiagnosticResult {
        let started = Date()
        guard runtime.mcp == .ready,
              let port = runtime.mcpPort,
              let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return result(
                id: "mcp",
                title: "MCP 协议",
                status: .failed,
                message: "MCP Server 尚未就绪",
                started: started
            )
        }

        do {
            let requestBody = MCPJSONRPCRequest(id: .number(1), method: "server/discover")
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.httpBody = try JSONEncoder().encode(requestBody)
            request.timeoutInterval = 2
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("server/discover", forHTTPHeaderField: "Mcp-Method")
            if let token = try secretStore.string(for: .localMCPAccessToken), !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "X-Harbor-Bridge-Token")
            }
            let (data, response) = try await URLSession.shared.data(for: request)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else {
                return result(id: "mcp", title: "MCP 协议", status: .failed, message: "MCP discovery HTTP 响应异常", started: started)
            }
            let decoded = try JSONDecoder().decode(MCPJSONRPCResponse.self, from: data)
            guard decoded.error == nil,
                  decoded.result?.objectValue?["supportedVersions"]?.arrayValue?.contains(.string(MCPProtocolVersion.modern)) == true else {
                return result(id: "mcp", title: "MCP 协议", status: .failed, message: "MCP discovery 返回内容不兼容", started: started)
            }
            return result(id: "mcp", title: "MCP 协议", status: .passed, message: "MCP \(MCPProtocolVersion.modern) discovery 正常", started: started)
        } catch {
            return result(id: "mcp", title: "MCP 协议", status: .failed, message: error.localizedDescription, started: started)
        }
    }

    private func measure(
        id: String,
        title: String,
        operation: () -> (BridgeDiagnosticStatus, String)
    ) -> BridgeDiagnosticResult {
        let started = Date()
        let value = operation()
        return result(id: id, title: title, status: value.0, message: value.1, started: started)
    }

    private func result(
        id: String,
        title: String,
        status: BridgeDiagnosticStatus,
        message: String,
        started: Date
    ) -> BridgeDiagnosticResult {
        BridgeDiagnosticResult(
            id: id,
            title: title,
            status: status,
            message: message,
            durationMilliseconds: max(0, Int(Date().timeIntervalSince(started) * 1_000))
        )
    }

    private static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
