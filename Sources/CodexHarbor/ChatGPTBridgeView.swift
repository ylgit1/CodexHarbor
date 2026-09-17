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

struct ChatGPTBridgeView: View {
    @StateObject private var bridge = ChatGPTBridgeViewModel()
    @State private var showingAdvanced = false
    @State private var tunnelIDInput = ""
    @State private var runtimeAPIKeyInput = ""
    @State private var tunnelClientPathInput = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header
                pipeline
                accessSection
                tunnelSection
                lifecycleSection
                permissionsSection
                diagnosticsSection
                activitySection
                if showingAdvanced {
                    technicalSection
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .task {
            await bridge.reconcileRuntime()
            if tunnelIDInput.isEmpty {
                tunnelIDInput = bridge.configuration.secureTunnel?.tunnelID ?? ""
            }
            if tunnelClientPathInput.isEmpty {
                tunnelClientPathInput = bridge.configuration.secureTunnel?.executablePath ?? ""
            }
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await bridge.refresh()
            }
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ChatGPT 本地访问")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text("配置一次后，继续在 ChatGPT 官方 Chat 中读取、修改和构建本机项目。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            statusBadge(
                title: chatGPTActivityText,
                color: chatGPTActivityColor
            )
            Button("打开 ChatGPT") { openChatGPT() }
                .buttonStyle(.bordered)
            Button(bridge.agentRunning ? "停止" : "启动") {
                Task {
                    if bridge.agentRunning { await bridge.setEnabled(false) }
                    else { await bridge.setEnabled(true) }
                }
            }
            .buttonStyle(.borderedProminent)
            .disabled(bridge.isWorking || bridge.configuration.allowedRoots.isEmpty)
        }
    }

    private var pipeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("连接链路")
                .font(.callout.weight(.semibold))
            HStack(spacing: 0) {
                pipelineNode(title: "Local Agent", detail: bridge.agentRunning ? "运行中" : "未启动", icon: "desktopcomputer", color: bridge.agentRunning ? .green : .secondary)
                pipelineConnector(active: bridge.agentRunning)
                pipelineNode(title: "MCP", detail: bridge.mcpHealthy ? "可用" : "未就绪", icon: "point.3.connected.trianglepath.dotted", color: bridge.mcpHealthy ? .green : .secondary)
                pipelineConnector(active: bridge.mcpHealthy)
                pipelineNode(title: "安全通道", detail: tunnelStateText, icon: "lock.shield", color: tunnelStateColor)
                pipelineConnector(active: bridge.runtime.tunnel == .connected)
                pipelineNode(title: "ChatGPT", detail: chatGPTNodeText, icon: "bubble.left.and.bubble.right", color: chatGPTActivityColor)
            }
            .padding(14)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.68), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))

            if let message = bridge.statusMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var accessSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("允许访问目录")
                    .font(.callout.weight(.semibold))
                Spacer()
                Button("添加目录") { chooseDirectory() }
                    .buttonStyle(.bordered)
            }

            if bridge.configuration.allowedRoots.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "folder.badge.plus")
                        .font(.system(size: 24))
                        .foregroundStyle(.secondary)
                    Text("先选择 ChatGPT 可以访问的开发目录")
                        .font(.caption.weight(.semibold))
                    Text("仅该目录及其子目录会被 Local Agent 接受。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 112)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.45), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(bridge.configuration.allowedRoots.enumerated()), id: \.element) { index, path in
                        HStack(spacing: 10) {
                            Image(systemName: "folder.fill")
                                .foregroundStyle(.blue)
                            Text(path)
                                .font(.system(size: 11, design: .monospaced))
                                .lineLimit(1)
                                .truncationMode(.middle)
                            Spacer()
                            Button {
                                Task { await bridge.removeAllowedRoot(path) }
                            } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.plain)
                            .help("移除允许目录")
                        }
                        .frame(minHeight: 38)
                        if index < bridge.configuration.allowedRoots.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }
        }
    }

    private var tunnelSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Secure MCP Tunnel")
                        .font(.callout.weight(.semibold))
                    Text("用于把本机 MCP 安全接入 ChatGPT；仅建立出站连接，不开放本机公网端口。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                statusBadge(title: tunnelStateText, color: tunnelStateColor)
            }

            VStack(alignment: .leading, spacing: 9) {
                HStack(alignment: .center, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("首次配置快捷入口")
                            .font(.caption.weight(.semibold))
                        Text("按顺序创建 Tunnel ID 和 Runtime API Key，再回到这里保存连接。")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 12)
                    Button {
                        openTunnelManagement()
                    } label: {
                        Label("1  新建 Tunnel ID", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.bordered)
                    .help("打开 OpenAI Platform Tunnels 页面")

                    Button {
                        openRuntimeKeyManagement()
                    } label: {
                        Label("2  新建 Runtime API Key", systemImage: "key.fill")
                    }
                    .buttonStyle(.bordered)
                    .help("创建 Restricted Runtime API Key，并授予 Tunnels Read + Use")

                    Button {
                        openChatGPTConnectorSettings()
                    } label: {
                        Label("3  ChatGPT 连接设置", systemImage: "bubble.left.and.bubble.right")
                    }
                    .buttonStyle(.borderedProminent)
                    .help("打开 ChatGPT Connectors，在 Connection 中选择 Tunnel")
                }
                .padding(11)
                .background(Color.blue.opacity(0.045), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous).stroke(Color.blue.opacity(0.12)))

                Text("Runtime API Key 建议创建为 Restricted，并仅授予 Tunnels Read + Use。不要把 Admin API Key 用作长期运行密钥。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Tunnel ID")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    TextField("tunnel_0123456789abcdef0123456789abcdef", text: $tunnelIDInput)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 5) {
                    Text("Runtime API Key")
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.secondary)
                    SecureField(bridge.hasTunnelRuntimeKey ? "已安全保存，留空表示不修改" : "粘贴 runtime API key", text: $runtimeAPIKeyInput)
                        .textFieldStyle(.roundedBorder)
                }
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("tunnel-client")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    TextField("选择 OpenAI 官方 tunnel-client 可执行文件", text: $tunnelClientPathInput)
                        .textFieldStyle(.roundedBorder)
                    Button("选择…") { chooseTunnelClient() }
                        .buttonStyle(.bordered)
                    if !bridge.tunnelClientAvailable {
                        Button("自动安装") {
                            Task {
                                if let installedPath = await bridge.installTunnelClient() {
                                    tunnelClientPathInput = installedPath
                                }
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(bridge.isWorking)
                        Button("官方下载") { openTunnelClientDownload() }
                            .buttonStyle(.bordered)
                    }
                }
            }

            HStack(spacing: 8) {
                Button("保存并连接") {
                    Task {
                        await bridge.configureTunnel(
                            tunnelID: tunnelIDInput,
                            runtimeAPIKey: runtimeAPIKeyInput,
                            executablePath: tunnelClientPathInput
                        )
                        runtimeAPIKeyInput = ""
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(bridge.isWorking || tunnelIDInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                Button("打开 ChatGPT 连接设置") { openChatGPTConnectorSettings() }
                    .buttonStyle(.bordered)

                if bridge.configuration.secureTunnel != nil {
                    Spacer(minLength: 8)
                    Button("移除配置", role: .destructive) {
                        Task {
                            await bridge.removeTunnelConfiguration()
                            tunnelIDInput = ""
                            runtimeAPIKeyInput = ""
                        }
                    }
                    .buttonStyle(.bordered)
                }
            }

            if bridge.configuration.secureTunnel != nil {
                Text("首次需要在 ChatGPT 的自定义 MCP/Connector 设置中选择这个 Tunnel。之后 Harbor 负责保持本地 Agent、MCP 和安全通道运行。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private var lifecycleSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center, spacing: 12) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("后台运行")
                        .font(.callout.weight(.semibold))
                    Text("关闭 Codex Harbor 后，ChatGPT 本地访问仍可继续运行。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Toggle(
                    "登录后自动保持本地访问",
                    isOn: Binding(
                        get: { bridge.configuration.launchAtLogin },
                        set: { enabled in
                            Task { await bridge.setLaunchAtLogin(enabled) }
                        }
                    )
                )
                .toggleStyle(.switch)
                .disabled(bridge.isWorking)
            }

            HStack(spacing: 8) {
                Image(systemName: bridge.launchAgentStatus?.loaded == true ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(bridge.launchAgentStatus?.loaded == true ? Color.green : Color.secondary)
                Text(bridge.configuration.launchAtLogin
                     ? (bridge.launchAgentStatus?.loaded == true ? "launchd 正在托管 HarborChatGPTAgent" : "等待 launchd 托管")
                     : "由 Codex Harbor 当前会话临时启动 Agent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("本地工具权限")
                    .font(.callout.weight(.semibold))
                Text("高风险命令始终由 Harbor 本地策略阻止；写操作仍受 ChatGPT 应用权限与确认机制约束。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                Text("文件修改")
                    .font(.caption.weight(.medium))
                    .frame(width: 86, alignment: .leading)
                Text("edit / write")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("文件修改", selection: Binding(
                    get: { bridge.configuration.modificationPermission },
                    set: { value in Task { await bridge.updatePermissions(modification: value) } }
                )) {
                    Text("允许").tag(ModificationPermission.allow)
                    Text("由 ChatGPT 确认").tag(ModificationPermission.ask)
                    Text("拒绝").tag(ModificationPermission.deny)
                }
                .labelsHidden()
                .frame(width: 150)
            }
            Divider().opacity(0.55)
            HStack(spacing: 12) {
                Text("Shell")
                    .font(.caption.weight(.medium))
                    .frame(width: 86, alignment: .leading)
                Text("构建、测试和受控命令")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("Shell", selection: Binding(
                    get: { bridge.configuration.shellPermission },
                    set: { value in Task { await bridge.updatePermissions(shell: value) } }
                )) {
                    Text("仅安全命令").tag(ShellPermission.safeOnly)
                    Text("由 ChatGPT 确认").tag(ShellPermission.ask)
                    Text("拒绝").tag(ShellPermission.deny)
                }
                .labelsHidden()
                .frame(width: 150)
            }
            Divider().opacity(0.55)
            HStack(spacing: 12) {
                Text("Git Push")
                    .font(.caption.weight(.medium))
                    .frame(width: 86, alignment: .leading)
                Text("仅控制远程推送；force push 始终禁止")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 12)
                Picker("Git Push", selection: Binding(
                    get: { bridge.configuration.gitPushPermission },
                    set: { value in Task { await bridge.updatePermissions(gitPush: value) } }
                )) {
                    Text("允许").tag(GitPermission.allow)
                    Text("由 ChatGPT 确认").tag(GitPermission.ask)
                    Text("拒绝").tag(GitPermission.deny)
                }
                .labelsHidden()
                .frame(width: 150)
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private var diagnosticsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    Text("连接诊断")
                        .font(.callout.weight(.semibold))
                    Text("实际检查 Agent、MCP、Tunnel、Keychain、自动启动和 Codex 隔离。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 12)
                Button(bridge.isDiagnosing ? "诊断中…" : "运行完整诊断") {
                    Task { await bridge.runDiagnostics() }
                }
                .buttonStyle(.bordered)
                .disabled(bridge.isDiagnosing || bridge.isWorking)
            }

            if bridge.diagnosticResults.isEmpty {
                Text("尚未运行诊断。连接异常时可以先在这里确认问题发生在哪一层。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(bridge.diagnosticResults.enumerated()), id: \.element.id) { index, result in
                        HStack(spacing: 10) {
                            Image(systemName: diagnosticIcon(result.status))
                                .foregroundStyle(diagnosticColor(result.status))
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(result.title)
                                    .font(.caption.weight(.semibold))
                                Text(result.message)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Spacer(minLength: 8)
                            Text("\(result.durationMilliseconds) ms")
                                .font(.system(size: 9.5, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        .frame(minHeight: 42)
                        if index < bridge.diagnosticResults.count - 1 { Divider() }
                    }
                }
                .padding(.horizontal, 10)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            }
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(Color.primary.opacity(0.08)))
    }

    private var activitySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                infoPanel(title: "本地 Agent", value: bridge.agentRunning ? "运行中" : "未运行", detail: bridge.runtime.processIdentifier.map { "PID \($0)" } ?? "独立于 Codex Runtime", icon: "cpu", color: bridge.agentRunning ? .green : .secondary)
                infoPanel(title: "MCP 服务", value: bridge.mcpHealthy ? "正常" : "未就绪", detail: bridge.mcpURLText, icon: "server.rack", color: bridge.mcpHealthy ? .green : .secondary)
                infoPanel(title: "Secure Tunnel", value: tunnelStateText, detail: "仅出站连接，不占用 Codex Relay", icon: "lock.shield", color: tunnelStateColor)
            }

            VStack(alignment: .leading, spacing: 7) {
                Text("最近本地调用")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                if bridge.recentAuditEntries.isEmpty {
                    Text("暂无工具调用。ChatGPT 开始读取或修改本地项目后会在这里实时出现。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
                } else {
                    VStack(spacing: 0) {
                        ForEach(Array(bridge.recentAuditEntries.prefix(6).enumerated()), id: \.element.id) { index, entry in
                            HStack(spacing: 9) {
                                Circle()
                                    .fill(entry.status == .success ? Color.green : Color.red)
                                    .frame(width: 6, height: 6)
                                Text(entry.timestamp.formatted(date: .omitted, time: .standard))
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                                    .frame(width: 74, alignment: .leading)
                                Text(entry.tool)
                                    .font(.caption.weight(.semibold))
                                    .frame(width: 52, alignment: .leading)
                                Text(entry.target ?? entry.summary)
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Spacer(minLength: 8)
                                Text("\(entry.durationMilliseconds) ms")
                                    .font(.system(size: 9.5, design: .monospaced))
                                    .foregroundStyle(.tertiary)
                            }
                            .frame(minHeight: 30)
                            if index < min(bridge.recentAuditEntries.count, 6) - 1 { Divider() }
                        }
                    }
                    .padding(.horizontal, 10)
                    .background(Color(nsColor: .controlBackgroundColor).opacity(0.42), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            Button(showingAdvanced ? "收起技术信息" : "查看技术信息") {
                withAnimation(.easeOut(duration: 0.16)) { showingAdvanced.toggle() }
            }
            .buttonStyle(.plain)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    private var technicalSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("技术信息")
                .font(.callout.weight(.semibold))
            technicalRow("数据目录", value: "~/Library/Application Support/CodexHarbor/ChatGPTBridge")
            technicalRow("MCP", value: bridge.mcpURLText)
            technicalRow("Codex Relay", value: "完全隔离，不使用 127.0.0.1:18473")
            technicalRow("Tunnel Client", value: bridge.tunnelClientAvailable ? "已检测" : "未检测到")
        }
        .padding(14)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private func pipelineNode(title: String, detail: String, icon: String, color: Color) -> some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(color)
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 70)
    }

    private func pipelineConnector(active: Bool) -> some View {
        Rectangle()
            .fill(active ? Color.green.opacity(0.55) : Color.primary.opacity(0.12))
            .frame(width: 28, height: 1)
    }

    private func infoPanel(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(color)
                .frame(width: 28, height: 28)
                .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                Text(value).font(.system(size: 13, weight: .semibold, design: .rounded))
                Text(detail).font(.caption2).foregroundStyle(.tertiary).lineLimit(2)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 92, alignment: .topLeading)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }

    private func technicalRow(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).font(.caption).foregroundStyle(.secondary).frame(width: 92, alignment: .leading)
            Text(value).font(.system(size: 10.5, design: .monospaced)).textSelection(.enabled)
        }
    }

    private func diagnosticIcon(_ status: BridgeDiagnosticStatus) -> String {
        switch status {
        case .passed: "checkmark.circle.fill"
        case .warning: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle.fill"
        }
    }

    private func diagnosticColor(_ status: BridgeDiagnosticStatus) -> Color {
        switch status {
        case .passed: .green
        case .warning: .orange
        case .failed: .red
        }
    }

    private func statusBadge(title: String, color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 7, height: 7)
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(color)
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(color.opacity(0.08), in: Capsule())
    }

    private var chatGPTRecentlyActive: Bool {
        guard let latest = bridge.recentAuditEntries.first?.timestamp else { return false }
        return Date().timeIntervalSince(latest) < 60
    }

    private var chatGPTActivityText: String {
        if chatGPTRecentlyActive { return "ChatGPT 正在使用本地工具" }
        if bridge.runtime.tunnel == .connected { return "ChatGPT 通道已连接" }
        if bridge.localReady { return "本地就绪，等待通道" }
        if bridge.agentRunning { return "正在检查 MCP" }
        return "未运行"
    }

    private var chatGPTNodeText: String {
        if chatGPTRecentlyActive { return "刚刚调用" }
        if bridge.runtime.tunnel == .connected { return "可接入" }
        return bridge.configuration.secureTunnel == nil ? "待配置" : "等待 Tunnel"
    }

    private var chatGPTActivityColor: Color {
        if chatGPTRecentlyActive || bridge.runtime.tunnel == .connected { return .green }
        if bridge.agentRunning { return .orange }
        return .secondary
    }

    private var tunnelStateText: String {
        switch bridge.runtime.tunnel {
        case .connected:
            return "已连接"
        case .connecting:
            return "连接中"
        case .failed:
            return "连接失败"
        case .disabled:
            if bridge.configuration.secureTunnel == nil { return "未配置" }
            return bridge.tunnelClientAvailable ? "待启动" : "缺少客户端"
        }
    }

    private var tunnelStateColor: Color {
        switch bridge.runtime.tunnel {
        case .connected: .green
        case .connecting: .orange
        case .failed: .red
        case .disabled: bridge.configuration.secureTunnel == nil ? .secondary : .blue
        }
    }

    private func chooseDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "允许访问"
        panel.message = "选择 ChatGPT 可以通过 Codex Harbor Local 访问的开发目录。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await bridge.addAllowedRoot(url) }
    }

    private func chooseTunnelClient() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        panel.message = "选择 OpenAI 官方 tunnel-client 可执行文件。"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        tunnelClientPathInput = url.path
    }

    private func openChatGPT() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://chatgpt.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openChatGPTConnectorSettings() {
        guard let url = URL(string: "https://chatgpt.com/#settings/Connectors") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTunnelClientDownload() {
        guard let url = URL(string: "https://github.com/openai/tunnel-client/releases/latest") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTunnelManagement() {
        guard let url = URL(string: "https://platform.openai.com/settings/organization/tunnels") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRuntimeKeyManagement() {
        guard let url = URL(string: "https://platform.openai.com/settings/organization/api-keys") else { return }
        NSWorkspace.shared.open(url)
    }
}
