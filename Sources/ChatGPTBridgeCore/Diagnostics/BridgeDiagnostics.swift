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

    public func runPipeline(
        paths: BridgePaths,
        configuration: BridgeConfiguration,
        runtime: BridgeRuntimeState
    ) async -> [BridgeDiagnosticResult] {
        var results: [BridgeDiagnosticResult] = []
        results.append(measure(id: "agent", title: "Harbor Agent") {
            guard let pid = runtime.processIdentifier,
                  Self.processExists(pid),
                  runtime.agent == .running else {
                return (.failed, "Agent 未运行")
            }
            return (.passed, "PID \(pid)")
        })
        results.append(await checkMCP(runtime: runtime))
        results.append(await checkMCPInitialize(runtime: runtime))
        results.append(await checkMCPTools(runtime: runtime))
        results.append(measure(id: "transport-process", title: "Tunnel Client") {
            guard runtime.transportProcessRunning,
                  let pid = runtime.transportProcessIdentifier,
                  Self.processExists(pid) else {
                return runtime.tunnel == .connecting
                    ? (.warning, "Tunnel 进程正在恢复")
                    : (.failed, "Tunnel 进程未运行")
            }
            return (.passed, "PID \(pid)")
        })

        switch configuration.transportMode {
        case .secureTunnel:
            results.append(measure(id: "tunnel-key", title: "Runtime Key") {
                switch runtime.health.tunnel.runtimeKey {
                case .valid: return (.passed, "Runtime Key 有效")
                case .checking: return (.warning, "Runtime Key 刷新中")
                case .invalid: return (.failed, "Runtime Key 无效或鉴权失败")
                case .notRequired: return (.failed, "Runtime Key 状态缺失")
                }
            })
            results.append(await checkSecureTunnelEndpoint(paths: paths, runtime: runtime))
        case .httpsCompatibility:
            results.append(await checkCompatibilityEndpoint(configuration: configuration))
        }
        return results
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
        results.append(await checkMCPInitialize(runtime: runtime))
        results.append(await checkMCPTools(runtime: runtime))
        switch configuration.transportMode {
        case .secureTunnel:
            results.append(measure(id: "tunnel-client", title: "OpenAI 管道客户端") {
                switch TunnelClientLocator().locate(preferredPath: configuration.secureTunnel?.executablePath) {
                case .available(let url): return (.passed, url.path)
                case .unavailable:
                    return configuration.secureTunnel == nil
                        ? (.warning, "尚未配置 OpenAI 本地管道")
                        : (.failed, "配置存在，但 tunnel-client 不可用，需要重新安装或检查路径")
                }
            })
            results.append(measure(id: "tunnel-key", title: "Tunnel Runtime Key") {
                guard configuration.secureTunnel != nil else {
                    return (.warning, "尚未配置 OpenAI 本地管道")
                }
                do {
                    let value = try secretStore.string(for: .tunnelRuntimeAPIKey)
                    return value?.isEmpty == false
                        ? (.passed, "已保存在 Harbor 本地凭据")
                        : (.failed, "配置存在，但 Runtime Key 已丢失，需要重新保存凭据")
                } catch {
                    return (.failed, error.localizedDescription)
                }
            })
            results.append(measure(id: "tunnel", title: "OpenAI 本地管道") {
                guard configuration.secureTunnel != nil else {
                    return (.warning, "尚未配置")
                }
                switch runtime.tunnel {
                case .connected: return (.passed, "OpenAI Tunnel 已连接")
                case .connecting: return (.warning, "本地管道正在连接")
                case .failed: return (.failed, runtime.transportMessage ?? "本地管道连接失败")
                case .disabled: return (.failed, "已配置但当前未运行")
                }
            })

        case .httpsCompatibility:
            results.append(measure(id: "cloudflared", title: "公网 HTTPS 进程") {
                guard let compatibility = configuration.httpsCompatibility else {
                    return (.failed, "公网 HTTPS 尚未完成配置")
                }
                guard FileManager.default.isExecutableFile(atPath: compatibility.cloudflaredPath) else {
                    return (.failed, "配置存在，但 cloudflared 不可用，需要重新安装或检查路径")
                }
                switch runtime.tunnel {
                case .connected: return (.passed, compatibility.hostname)
                case .connecting: return (.warning, "公网 HTTPS 端点正在建立")
                case .failed: return (.failed, runtime.transportMessage ?? "公网 HTTPS 连接失败")
                case .disabled: return (.failed, "公网 HTTPS 已配置但当前未运行")
                }
            })
            results.append(await checkCompatibilityEndpoint(configuration: configuration))
        }
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

    private func checkCompatibilityEndpoint(configuration: BridgeConfiguration) async -> BridgeDiagnosticResult {
        let started = Date()
        guard let compatibility = configuration.httpsCompatibility else {
            return result(id: "public-mcp", title: "公网 MCP", status: .failed, message: "公网 HTTPS 配置缺失", started: started)
        }
        do {
            guard let token = try secretStore.string(for: .httpsCompatibilityAccessToken), !token.isEmpty,
                  let url = URL(string: "https://\(compatibility.hostname)/mcp/\(token)") else {
                return result(id: "public-mcp", title: "公网 MCP", status: .failed, message: "公网 MCP 访问令牌缺失", started: started)
            }
            var request = URLRequest(url: url)
            request.httpMethod = "GET"
            request.timeoutInterval = 3
            request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            guard status == 200 else {
                return result(
                    id: "public-mcp",
                    title: "公网 MCP",
                    status: .failed,
                    message: "HTTPS MCP 返回 HTTP \(status ?? 0)",
                    started: started
                )
            }

            // GET 200 只能证明公网入口存在，不能证明 ChatGPT 可以调用 MCP。
            // 后续 MCP 调用仍通过本地 Agent 的协议校验完成；这里明确区分入口可达和服务可用。
            return result(
                id: "public-mcp",
                title: "公网 MCP",
                status: .passed,
                message: "HTTPS MCP 公网入口可访问；MCP 协议可用性请结合本地 MCP 检测结果确认",
                started: started
            )
        } catch {
            return result(id: "public-mcp", title: "公网 MCP", status: .failed, message: error.localizedDescription, started: started)
        }
    }

    private func checkSecureTunnelEndpoint(
        paths: BridgePaths,
        runtime: BridgeRuntimeState
    ) async -> BridgeDiagnosticResult {
        let started = Date()
        let healthURLFile = paths.root.appendingPathComponent("tunnel-health.url")
        guard let text = try? String(contentsOf: healthURLFile, encoding: .utf8),
              let baseURL = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            let status: BridgeDiagnosticStatus = runtime.health.tunnel.runtimeKey == .invalid ? .failed : .warning
            return result(
                id: "tunnel",
                title: "OpenAI Tunnel",
                status: status,
                message: status == .failed ? "鉴权失败，Tunnel 健康端点不可用" : "Tunnel 健康端点正在恢复",
                started: started
            )
        }

        var request = URLRequest(url: baseURL.appendingPathComponent("readyz"))
        request.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200 {
                return result(
                    id: "tunnel",
                    title: "OpenAI Tunnel",
                    status: .passed,
                    message: "OpenAI Tunnel 已连接",
                    started: started
                )
            }
            let status: BridgeDiagnosticStatus = runtime.health.tunnel.runtimeKey == .invalid ? .failed : .warning
            return result(
                id: "tunnel",
                title: "OpenAI Tunnel",
                status: status,
                message: "readyz 返回 HTTP \(code)",
                started: started
            )
        } catch {
            let status: BridgeDiagnosticStatus = runtime.health.tunnel.runtimeKey == .invalid ? .failed : .warning
            return result(
                id: "tunnel",
                title: "OpenAI Tunnel",
                status: status,
                message: status == .failed ? error.localizedDescription : "正在恢复：\(error.localizedDescription)",
                started: started
            )
        }
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
            return result(
                id: "mcp",
                title: "MCP 协议",
                status: .passed,
                message: "127.0.0.1:\(port) · MCP \(MCPProtocolVersion.modern) discovery 正常",
                started: started
            )
        } catch {
            return result(id: "mcp", title: "MCP 协议", status: .failed, message: error.localizedDescription, started: started)
        }
    }

    private func checkMCPInitialize(runtime: BridgeRuntimeState) async -> BridgeDiagnosticResult {
        let started = Date()
        guard let port = runtime.mcpPort,
              let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return result(id: "mcp-initialize", title: "MCP initialize", status: .failed, message: "本地 MCP 地址不存在", started: started)
        }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.httpBody = try JSONEncoder().encode(MCPJSONRPCRequest(id: .number(10), method: "initialize", params: [
                "protocolVersion": .string(MCPProtocolVersion.modern),
                "capabilities": .object([:]),
                "clientInfo": .object([
                    "name": .string("CodexHarbor Diagnostics"),
                    "version": .string("1")
                ])
            ]))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("initialize", forHTTPHeaderField: "Mcp-Method")
            if let token = try secretStore.string(for: .localMCPAccessToken), !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "X-Harbor-Bridge-Token")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200
                ? result(id: "mcp-initialize", title: "MCP initialize", status: .passed, message: "MCP 初始化握手正常", started: started)
                : result(id: "mcp-initialize", title: "MCP initialize", status: .failed, message: "initialize HTTP \(code)", started: started)
        } catch {
            return result(id: "mcp-initialize", title: "MCP initialize", status: .failed, message: error.localizedDescription, started: started)
        }
    }

    private func checkMCPTools(runtime: BridgeRuntimeState) async -> BridgeDiagnosticResult {
        let started = Date()
        guard let port = runtime.mcpPort,
              let endpoint = URL(string: "http://127.0.0.1:\(port)/mcp") else {
            return result(id: "mcp-tools", title: "MCP tools/list", status: .failed, message: "本地 MCP 地址不存在", started: started)
        }

        do {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 3
            request.httpBody = try JSONEncoder().encode(MCPJSONRPCRequest(id: .number(11), method: "tools/list"))
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue("tools/list", forHTTPHeaderField: "Mcp-Method")
            request.setValue(MCPProtocolVersion.modern, forHTTPHeaderField: "MCP-Protocol-Version")
            if let token = try secretStore.string(for: .localMCPAccessToken), !token.isEmpty {
                request.setValue(token, forHTTPHeaderField: "X-Harbor-Bridge-Token")
            }
            let (_, response) = try await URLSession.shared.data(for: request)
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            return code == 200
                ? result(id: "mcp-tools", title: "MCP tools/list", status: .passed, message: "工具发现正常", started: started)
                : result(id: "mcp-tools", title: "MCP tools/list", status: .failed, message: "tools/list HTTP \(code)", started: started)
        } catch {
            return result(id: "mcp-tools", title: "MCP tools/list", status: .failed, message: error.localizedDescription, started: started)
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
