import AppKit
import ChatGPTBridgeCore
import Darwin
import Foundation
import SwiftUI

@MainActor
final class ChatGPTBridgeViewModel: ObservableObject {
    @Published private(set) var configuration = BridgeConfiguration()
    @Published private(set) var runtime = BridgeRuntimeState()
    @Published private(set) var tunnelClientAvailable = false
    @Published private(set) var hasTunnelRuntimeKey = false
    @Published private(set) var mcpHealthy = false
    @Published private(set) var launchAgentStatus: BridgeLaunchAgentStatus?
    @Published private(set) var diagnosticResults: [BridgeDiagnosticResult] = []
    @Published private(set) var recentAuditEntries: [AuditEntry] = []
    @Published private(set) var statusMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isDiagnosing = false

    private let paths: BridgePaths?
    private let store: BridgeConfigurationStore?
    private let secretStore = BridgeSecretStore()
    private let launchAgentManager = BridgeLaunchAgentManager()

    init() {
        var resolvedPaths: BridgePaths?
        var resolvedStore: BridgeConfigurationStore?
        var resolvedConfiguration = BridgeConfiguration()
        var initializationMessage: String?

        do {
            let paths = try BridgePaths.live()
            let store = BridgeConfigurationStore(paths: paths)
            try paths.ensureDirectories()
            resolvedPaths = paths
            resolvedStore = store
            resolvedConfiguration = try store.load()
        } catch {
            initializationMessage = error.localizedDescription
        }

        self.paths = resolvedPaths
        self.store = resolvedStore
        self.configuration = resolvedConfiguration
        self.statusMessage = initializationMessage
        refreshTunnelAvailability()
        refreshSecretAvailability()
        refreshLaunchAgentStatus()
    }

    var localReady: Bool {
        runtime.agent == .running && runtime.mcp == .ready && mcpHealthy
    }

    var overallReady: Bool {
        localReady && runtime.tunnel == .connected
    }

    var agentRunning: Bool {
        runtime.agent == .running && runtime.processIdentifier.map(Self.processExists) == true
    }

    var mcpURLText: String {
        runtime.mcpURL ?? "尚未启动"
    }

    func refresh() async {
        guard let paths else { return }
        refreshTunnelAvailability()
        refreshSecretAvailability()
        refreshLaunchAgentStatus()
        if let data = try? Data(contentsOf: paths.runtimeURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode(BridgeRuntimeState.self, from: data),
               decoded.processIdentifier.map(Self.processExists) == true {
                runtime = decoded
            } else {
                runtime = BridgeRuntimeState()
            }
        } else {
            runtime = BridgeRuntimeState()
        }
        mcpHealthy = await checkMCPHealth()
        if let entries = try? await AuditLogger(paths: paths).entries() {
            recentAuditEntries = Array(entries.suffix(12).reversed())
        }
    }

    func addAllowedRoot(_ url: URL) async {
        var updated = configuration
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        guard !updated.allowedRoots.contains(canonical) else { return }
        updated.allowedRoots.append(canonical)
        await save(updated)
    }

    func setPrimaryAllowedRoot(_ url: URL) async {
        var updated = configuration
        let canonical = url.standardizedFileURL.resolvingSymlinksInPath().path
        updated.allowedRoots = [canonical]
        await save(updated)
    }

    func removeAllowedRoot(_ path: String) async {
        var updated = configuration
        updated.allowedRoots.removeAll { $0 == path }
        await save(updated)
    }

    func setEnabled(_ enabled: Bool) async {
        var updated = configuration
        updated.enabled = enabled
        await save(updated)
        if enabled {
            await startAgent()
        } else {
            await stopAgent()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        guard let paths else { return }
        var updated = configuration
        updated.launchAtLogin = enabled
        await save(updated)

        do {
            if enabled {
                guard updated.enabled else {
                    statusMessage = "登录自动启动偏好已保存；启用 ChatGPT 本地访问后生效。"
                    refreshLaunchAgentStatus()
                    return
                }
                guard let executable = agentExecutableURL() else {
                    statusMessage = "未找到 HarborChatGPTAgent，无法配置登录自动启动。"
                    return
                }
                await terminateCurrentAgentIfNeeded()
                _ = try launchAgentManager.install(agentExecutableURL: executable, paths: paths)
                try await Task.sleep(for: .milliseconds(450))
                statusMessage = "登录自动启动已启用，Agent 由 launchd 独立托管。"
            } else {
                try launchAgentManager.uninstall()
                if updated.enabled {
                    await startAgentManually()
                }
                statusMessage = "登录自动启动已关闭；当前会话仍可继续使用本地 Agent。"
            }
            await refresh()
        } catch {
            statusMessage = error.localizedDescription
            await refresh()
        }
    }

    func reconcileRuntime() async {
        await refresh()
        guard configuration.enabled else { return }
        if configuration.launchAtLogin {
            guard launchAgentStatus?.loaded != true else { return }
            await setLaunchAtLogin(true)
        } else if !agentRunning {
            await startAgent()
        }
    }

    func runDiagnostics() async {
        guard let paths else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }
        await refresh()
        let launchStatus = launchAgentStatus ?? launchAgentManager.status()
        diagnosticResults = await BridgeDiagnosticsRunner().run(
            paths: paths,
            configuration: configuration,
            runtime: runtime,
            launchAgentStatus: launchStatus
        )
        let failures = diagnosticResults.filter { $0.status == .failed }.count
        statusMessage = failures == 0
            ? "完整诊断完成：未发现阻断问题。"
            : "完整诊断完成：发现 \(failures) 个需要处理的问题。"
    }

    func updatePermissions(
        modification: ModificationPermission? = nil,
        shell: ShellPermission? = nil,
        gitPush: GitPermission? = nil
    ) async {
        var updated = configuration
        if let modification { updated.modificationPermission = modification }
        if let shell { updated.shellPermission = shell }
        if let gitPush { updated.gitPushPermission = gitPush }
        await save(updated)

        if updated.enabled {
            await stopAgent()
            await startAgent()
        }
        statusMessage = "本地工具权限已更新。"
    }

    func prepareInitialConnection(tunnelID: String, runtimeAPIKey: String) async {
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "先选择一个本地项目目录。"
            return
        }

        var executablePath = configuration.secureTunnel?.executablePath
        if !tunnelClientAvailable {
            guard let installedPath = await installTunnelClient() else { return }
            executablePath = installedPath
        }

        var updated = configuration
        updated.launchAtLogin = true
        await save(updated)

        await configureTunnel(
            tunnelID: tunnelID,
            runtimeAPIKey: runtimeAPIKey,
            executablePath: executablePath
        )

        guard configuration.secureTunnel != nil, hasTunnelRuntimeKey else { return }
        if !configuration.enabled {
            await setEnabled(true)
        } else if configuration.launchAtLogin, launchAgentStatus?.loaded != true {
            await setLaunchAtLogin(true)
        }
        await refresh()
    }

    func configureTunnel(tunnelID: String, runtimeAPIKey: String, executablePath: String? = nil) async {
        let trimmedID = tunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTunnelID(trimmedID) else {
            statusMessage = "Tunnel ID 格式无效，应为 tunnel_ 加 32 位小写十六进制字符。"
            return
        }

        do {
            let trimmedKey = runtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmedKey.isEmpty {
                try secretStore.set(trimmedKey, for: .tunnelRuntimeAPIKey)
            } else if try secretStore.string(for: .tunnelRuntimeAPIKey) == nil {
                statusMessage = "请填写 Secure MCP Tunnel runtime API key。"
                return
            }

            var updated = configuration
            let requestedExecutable = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
            let preferredExecutable = requestedExecutable?.isEmpty == false
                ? requestedExecutable
                : updated.secureTunnel?.executablePath
            let resolvedExecutablePath: String?
            switch TunnelClientLocator().locate(preferredPath: preferredExecutable) {
            case .available(let url):
                resolvedExecutablePath = url.path
            case .unavailable:
                if let preferredExecutable, !preferredExecutable.isEmpty {
                    statusMessage = "指定的 tunnel-client 不存在或不可执行。"
                    return
                }
                resolvedExecutablePath = nil
            }
            updated.secureTunnel = SecureTunnelConfiguration(
                tunnelID: trimmedID,
                executablePath: resolvedExecutablePath
            )
            await save(updated)
            refreshSecretAvailability()

            if updated.enabled {
                await stopAgent()
                await startAgent()
            } else {
                statusMessage = "Tunnel 配置已保存。启动本地访问后会自动建立安全通道。"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installTunnelClient() async -> String? {
        guard let paths else { return nil }
        isWorking = true
        statusMessage = "正在下载并校验 OpenAI 官方 tunnel-client…"
        defer { isWorking = false }
        do {
            let result = try await TunnelClientInstaller().installLatest(paths: paths)
            tunnelClientAvailable = true
            statusMessage = "tunnel-client \(result.version) 已安装并通过 SHA-256 校验。"

            if var secureTunnel = configuration.secureTunnel {
                secureTunnel.executablePath = result.executableURL.path
                var updated = configuration
                updated.secureTunnel = secureTunnel
                await save(updated)
            }
            return result.executableURL.path
        } catch {
            statusMessage = error.localizedDescription
            return nil
        }
    }

    func removeTunnelConfiguration() async {
        do {
            try secretStore.remove(.tunnelRuntimeAPIKey)
            var updated = configuration
            updated.secureTunnel = nil
            await save(updated)
            refreshSecretAvailability()
            if updated.enabled {
                await stopAgent()
                await startAgent()
            }
            statusMessage = "Secure Tunnel 配置已移除。Local Agent 和 Codex 配置互不受影响。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startAgent() async {
        guard !agentRunning else {
            await refresh()
            return
        }
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "请先添加至少一个允许访问的开发目录。"
            return
        }
        guard let executable = agentExecutableURL() else {
            statusMessage = "未找到 HarborChatGPTAgent。请先重新构建安装包。"
            return
        }
        isWorking = true
        statusMessage = "正在启动本地 Agent…"
        defer { isWorking = false }
        do {
            if configuration.launchAtLogin {
                guard let paths else { return }
                _ = try launchAgentManager.install(agentExecutableURL: executable, paths: paths)
            } else {
                await startAgentManually()
            }
            try await Task.sleep(for: .milliseconds(450))
            await refresh()
            statusMessage = agentRunning ? "本地 Agent 已启动。" : "Agent 启动后未进入运行状态。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func stopAgent() async {
        isWorking = true
        defer { isWorking = false }
        do {
            if launchAgentStatus?.installed == true || launchAgentStatus?.loaded == true {
                try launchAgentManager.uninstall()
            }
        } catch {
            statusMessage = error.localizedDescription
        }
        await terminateCurrentAgentIfNeeded()
        runtime = BridgeRuntimeState()
        mcpHealthy = false
        refreshLaunchAgentStatus()
        statusMessage = "ChatGPT 本地访问已停止。"
    }

    private func startAgentManually() async {
        guard let executable = agentExecutableURL() else { return }
        do {
            let process = Process()
            process.executableURL = executable
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            var environment = ProcessInfo.processInfo.environment
            if let runtimeKey = try secretStore.string(for: .tunnelRuntimeAPIKey), !runtimeKey.isEmpty {
                environment["HARBOR_BRIDGE_TUNNEL_API_KEY"] = runtimeKey
            }
            process.environment = environment
            try process.run()
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func terminateCurrentAgentIfNeeded() async {
        if let pid = runtime.processIdentifier, Self.processExists(pid) {
            _ = Darwin.kill(pid, SIGTERM)
            for _ in 0..<20 {
                if !Self.processExists(pid) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func refreshLaunchAgentStatus() {
        launchAgentStatus = launchAgentManager.status()
    }

    private func save(_ configuration: BridgeConfiguration) async {
        guard let store else { return }
        do {
            try store.save(configuration)
            self.configuration = configuration
            statusMessage = nil
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    private func refreshTunnelAvailability() {
        let preferred = configuration.secureTunnel?.executablePath
        switch TunnelClientLocator().locate(preferredPath: preferred) {
        case .available:
            tunnelClientAvailable = true
        case .unavailable:
            tunnelClientAvailable = false
        }
    }

    private func refreshSecretAvailability() {
        hasTunnelRuntimeKey = ((try? secretStore.string(for: .tunnelRuntimeAPIKey)) ?? nil)?.isEmpty == false
    }

    private static func isValidTunnelID(_ value: String) -> Bool {
        guard value.hasPrefix("tunnel_"), value.count == 39 else { return false }
        return value.dropFirst(7).allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
    }

    private func checkMCPHealth() async -> Bool {
        guard let port = runtime.mcpPort,
              let url = URL(string: "http://127.0.0.1:\(port)/health") else { return false }
        var request = URLRequest(url: url)
        request.timeoutInterval = 1.5
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }

    private func agentExecutableURL() -> URL? {
        let candidates: [URL] = [
            Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HarborChatGPTAgent"),
            Bundle.main.executableURL?.deletingLastPathComponent().appendingPathComponent("HarborChatGPTAgent")
        ].compactMap { $0 }
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }

    private nonisolated static func processExists(_ pid: Int32) -> Bool {
        guard pid > 0 else { return false }
        if Darwin.kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }
}
