import CryptoKit
import Foundation

public struct CloudflaredLocator: Sendable {
    public init() {}

    public func locate(preferredPath: String? = nil, paths: BridgePaths? = nil) -> URL? {
        let managedPath = paths?
            .root
            .appendingPathComponent("bin/cloudflared/cloudflared")
            .path
        let candidates: [String] = [
            preferredPath,
            managedPath,
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/cloudflared").path,
            "/opt/homebrew/bin/cloudflared",
            "/usr/local/bin/cloudflared",
            "/usr/bin/cloudflared"
        ].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
        return candidates
            .filter { !$0.isEmpty }
            .map { URL(fileURLWithPath: $0) }
            .first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }
}

public struct HTTPSCompatibilityConfigurator: Sendable {
    private let locator: CloudflaredLocator

    public init(locator: CloudflaredLocator = CloudflaredLocator()) {
        self.locator = locator
    }

    public func prepare(
        paths: BridgePaths,
        localMCPAccessToken: String,
        cloudflaredPath: String? = nil,
        hostnameSuffix: String? = nil,
        localPort: UInt16 = 19_473
    ) throws -> HTTPSCompatibilityConfiguration {
        guard let cloudflared = locator.locate(preferredPath: cloudflaredPath, paths: paths) else {
            throw BridgeError.invalidPath("配置存在，但 cloudflared 不可用；公网 HTTPS 模式会尝试自动安装，若仍失败请检查网络或安装路径")
        }
        guard !localMCPAccessToken.isEmpty else {
            throw BridgeError.permissionDenied("缺少本地 MCP 访问令牌")
        }
        let requestedSuffix = hostnameSuffix?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        let suffix = try requestedSuffix?.isEmpty == false ? requestedSuffix : detectedHostnameSuffix()
        guard let suffix, Self.isValidHostnameSuffix(suffix) else {
            throw BridgeError.invalidPath("请填写 Cloudflare 已托管的域名，例如 example.com")
        }

        let stableID = Self.stableIdentifier(from: localMCPAccessToken)
        let tunnelName = "codex-harbor-\(stableID)"
        let hostname = "\(tunnelName).\(suffix)"

        var tunnels = try listTunnels(cloudflared: cloudflared)
        if !tunnels.contains(where: { $0.name == tunnelName }) {
            _ = try run(
                cloudflared,
                arguments: ["tunnel", "create", tunnelName]
            )
            tunnels = try listTunnels(cloudflared: cloudflared)
        }
        guard let tunnel = tunnels.first(where: { $0.name == tunnelName }) else {
            throw BridgeError.writeFailed("Cloudflare Tunnel 创建后未出现在 tunnel list 中")
        }

        let credentials = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared", isDirectory: true)
            .appendingPathComponent("\(tunnel.id).json")
        guard FileManager.default.fileExists(atPath: credentials.path) else {
            throw BridgeError.invalidPath("Cloudflare Tunnel credentials 不存在：\(credentials.path)")
        }

        do {
            _ = try run(
                cloudflared,
                arguments: ["tunnel", "route", "dns", tunnel.id, hostname]
            )
        } catch {
            let message = error.localizedDescription.lowercased()
            guard message.contains("already exists") || message.contains("already has") else {
                throw error
            }
        }

        let configuration = HTTPSCompatibilityConfiguration(
            tunnelName: tunnelName,
            tunnelID: tunnel.id,
            hostname: hostname,
            credentialsFilePath: credentials.path,
            cloudflaredPath: cloudflared.path,
            localPort: localPort
        )
        try Self.writeCloudflaredConfiguration(configuration, paths: paths)
        return configuration
    }

    public func detectedHostnameSuffix() throws -> String? {
        try detectedHostnameSuffixes().first
    }

    public func detectedHostnameSuffixes() throws -> [String] {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared", isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return [] }

        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let configs = names
            .filter { $0 == "config.yml" || $0 == "config.yaml" || $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
            .map { directory.appendingPathComponent($0) }

        var suffixes = Set<String>()
        for url in configs {
            guard let text = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for rawLine in text.components(separatedBy: .newlines) {
                let line = rawLine.trimmingCharacters(in: .whitespaces)
                guard line.hasPrefix("- hostname:") || line.hasPrefix("hostname:") else { continue }
                guard let colon = line.firstIndex(of: ":") else { continue }
                let hostname = line[line.index(after: colon)...]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                let labels = hostname.split(separator: ".")
                guard labels.count >= 3 else { continue }
                suffixes.insert(labels.dropFirst().joined(separator: "."))
            }
        }
        return suffixes.sorted()
    }

    private func listTunnels(cloudflared: URL) throws -> [CloudflareTunnelListItem] {
        let output = try run(
            cloudflared,
            arguments: ["tunnel", "list", "--output", "json"]
        )
        do {
            return try Self.decodeTunnelList(Data(output.utf8))
        } catch {
            throw BridgeError.writeFailed("cloudflared tunnel list JSON 无法解析：\(error.localizedDescription)")
        }
    }

    static func decodeTunnelList(_ data: Data) throws -> [CloudflareTunnelListItem] {
        // cloudflared emits JSON null, not [], when the account has no tunnels.
        try JSONDecoder().decode([CloudflareTunnelListItem]?.self, from: data) ?? []
    }

    private func run(_ executable: URL, arguments: [String]) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let output = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let errorOutput = String(decoding: stderr.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        guard process.terminationStatus == 0 else {
            let detail = errorOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.writeFailed("cloudflared \(arguments.prefix(3).joined(separator: " ")) 失败：\(detail)")
        }
        return output
    }

    public static func writeCloudflaredConfiguration(
        _ configuration: HTTPSCompatibilityConfiguration,
        paths: BridgePaths
    ) throws {
        let directory = paths.root.appendingPathComponent("https-compat", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("cloudflared.yml")
        let yaml = """
        tunnel: \(configuration.tunnelID)
        credentials-file: \(configuration.credentialsFilePath)

        ingress:
          - hostname: \(configuration.hostname)
            service: http://127.0.0.1:\(configuration.localPort)
          - service: http_status:404
        """
        try Data(yaml.utf8).write(to: url, options: .atomic)
    }

    public static func configurationURL(paths: BridgePaths) -> URL {
        paths.root
            .appendingPathComponent("https-compat", isDirectory: true)
            .appendingPathComponent("cloudflared.yml")
    }

    private static func stableIdentifier(from token: String) -> String {
        let digest = SHA256.hash(data: Data(token.utf8))
        return digest.prefix(4).map { String(format: "%02x", $0) }.joined()
    }

    private static func isValidHostnameSuffix(_ value: String) -> Bool {
        guard !value.contains("://"), !value.contains("/"), !value.hasPrefix("."), !value.hasSuffix(".") else {
            return false
        }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            guard let first = label.first, let last = label.last else { return false }
            return label.count <= 63
                && (first.isLetter || first.isNumber)
                && (last.isLetter || last.isNumber)
                && label.allSatisfy { $0.isLetter || $0.isNumber || $0 == "-" }
        }
    }
}

public actor HTTPSCompatibilityManager {
    private let paths: BridgePaths
    private var process: Process?
    private var state: TunnelRuntimeState = .disabled
    private var readinessIssue: String?

    public init(paths: BridgePaths) {
        self.paths = paths
    }

    public func currentState() -> TunnelRuntimeState { state }

    public func isProcessRunning() -> Bool {
        process?.isRunning == true
    }

    public func processIdentifier() -> Int32? {
        guard process?.isRunning == true else { return nil }
        return process?.processIdentifier
    }

    public func latestReadinessIssue() -> String? { readinessIssue }

    public func start(
        configuration: HTTPSCompatibilityConfiguration,
        localMCPAccessToken: String
    ) async throws -> TunnelRuntimeState {
        if process?.isRunning == true { return state }
        state = .connecting
        try HTTPSCompatibilityConfigurator.writeCloudflaredConfiguration(configuration, paths: paths)

        let configURL = HTTPSCompatibilityConfigurator.configurationURL(paths: paths)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: configuration.cloudflaredPath)
        process.arguments = [
            "tunnel",
            "--config", configURL.path,
            "--no-autoupdate",
            "run",
            configuration.tunnelID
        ]

        let logURL = paths.logsDirectory.appendingPathComponent("https-compat-cloudflared.log")
        BridgeLogRotator.rotateIfNeeded(logURL)
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try FileHandle(forWritingTo: logURL)
        try logHandle.seekToEnd()
        process.standardOutput = logHandle
        process.standardError = logHandle

        do {
            try process.run()
            self.process = process
            // Process readiness and public endpoint readiness are different
            // stages. Report cloudflared as running immediately, then let the
            // lifecycle monitor probe the public endpoint without blocking UI.
            let deadline = Date().addingTimeInterval(0.8)
            while Date() < deadline {
                if !process.isRunning {
                    state = .failed
                    throw BridgeError.writeFailed("公网 HTTPS 的 cloudflared 启动后立即退出")
                }
                try await Task.sleep(for: .milliseconds(100))
            }
            state = .connecting
            return state
        } catch {
            if process.isRunning { process.terminate() }
            self.process = nil
            state = .failed
            throw error
        }
    }

    public func stop() async {
        guard let process else {
            state = .disabled
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
        state = .disabled
    }

    public func readiness(
        configuration: HTTPSCompatibilityConfiguration,
        localMCPAccessToken: String
    ) async -> Bool {
        guard let url = URL(string: "https://\(configuration.hostname)/mcp/\(localMCPAccessToken)") else {
            readinessIssue = "公网 HTTPS 地址无效"
            return false
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 3
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                readinessIssue = "公网 HTTPS 未返回 HTTP 响应"
                return false
            }
            readinessIssue = http.statusCode == 200 ? nil : "公网 HTTPS 返回 HTTP \(http.statusCode)"
            return http.statusCode == 200
        } catch let error as URLError {
            if error.code == .secureConnectionFailed || error.code == .serverCertificateUntrusted {
                readinessIssue = "公网 TLS 握手失败：请检查 Cloudflare 证书是否覆盖当前域名"
            } else {
                readinessIssue = "公网 HTTPS 无法访问：\(error.localizedDescription)"
            }
            return false
        } catch {
            readinessIssue = "公网 HTTPS 检查失败：\(error.localizedDescription)"
            return false
        }
    }
}

struct CloudflareTunnelListItem: Decodable, Sendable {
    let id: String
    let name: String
}
