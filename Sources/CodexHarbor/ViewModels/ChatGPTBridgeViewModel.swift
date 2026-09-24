import AppKit
import ChatGPTBridgeCore
import Darwin
import Foundation
import Network
import SwiftUI

@MainActor
final class ChatGPTBridgeViewModel: ObservableObject {
    @Published private(set) var configuration = BridgeConfiguration()
    @Published private(set) var runtime = BridgeRuntimeState()
    @Published private(set) var tunnelClientAvailable = false
    @Published private(set) var cloudflaredAvailable = false
    @Published private(set) var cloudflaredExecutablePath: String?
    @Published private(set) var hasTunnelRuntimeKey = false
    @Published private(set) var hasPublicHTTPSAccessToken = false
    @Published private(set) var cloudflareAuthorized = false
    @Published private(set) var cloudflareHostnameSuffixes: [String] = []
    @Published private(set) var cloudflareZones: [String] = []
    @Published private(set) var hasCloudflareZoneAPIToken = false
    @Published private(set) var isFetchingCloudflareZones = false
    @Published private(set) var chatGPTPublicHTTPSConfigured = false
    @Published private(set) var discoveredToolCatalogVersion: String?
    @Published private(set) var discoveredToolCount: Int?
    @Published private(set) var catalogDiscoveredAt: Date?
    @Published private(set) var mcpHealthy = false
    @Published private(set) var launchAgentStatus: BridgeLaunchAgentStatus?
    @Published private(set) var diagnosticResults: [BridgeDiagnosticResult] = []
    @Published private(set) var recentAuditEntries: [AuditEntry] = []
    @Published private(set) var pendingApprovalRequests: [BridgeApprovalRequest] = []
    @Published private(set) var tunnelMigrationMessage: String?
    @Published private(set) var statusMessage: String?
    @Published private(set) var isWorking = false
    @Published private(set) var isDiagnosing = false
    @Published private(set) var isCloudflareAuthorizing = false
    @Published private(set) var isExportingDiagnostics = false
    @Published private(set) var isSwitchingTransport = false
    @Published private(set) var transportSwitchMessage: String?

    private let paths: BridgePaths?
    private let secretStore: BridgeSecretStore
    private let launchAgentManager = BridgeLaunchAgentManager()
    private let transportController: BridgeTransportController?
    private let binaryManager: BridgeBinaryManager?
    private let cloudflareZoneService = CloudflareZoneService()
    private let networkMonitor = NWPathMonitor()
    private let networkMonitorQueue = DispatchQueue(label: "com.codexharbor.bridge.network-recovery")
    private var lastNetworkStatus: NWPath.Status?

    init() {
        var resolvedPaths: BridgePaths?
        var resolvedTransportController: BridgeTransportController?
        var resolvedBinaryManager: BridgeBinaryManager?
        var resolvedConfiguration = BridgeConfiguration()
        var initializationMessage: String?
        let resolvedSecretStore = BridgeSecretStore()

        do {
            let paths = try BridgePaths.live()
            let store = BridgeConfigurationStore(paths: paths)
            try paths.ensureDirectories()
            resolvedPaths = paths
            let controller = BridgeTransportController(
                paths: paths,
                store: store,
                secretStore: resolvedSecretStore
            )
            resolvedTransportController = controller
            resolvedBinaryManager = BridgeBinaryManager(paths: paths)
            resolvedConfiguration = try controller.load()
        } catch {
            initializationMessage = error.localizedDescription
        }

        self.paths = resolvedPaths
        self.secretStore = resolvedSecretStore
        self.transportController = resolvedTransportController
        self.binaryManager = resolvedBinaryManager
        self.configuration = resolvedConfiguration
        self.statusMessage = initializationMessage
        refreshTunnelAvailability()
        refreshCloudflaredAvailability()
        refreshSecretAvailability()
        refreshCloudflareAuthorization()
        refreshCloudflareHostnameSuffixes()
        refreshChatGPTIntegration()
        startNetworkRecoveryMonitoring()
    }

    var localReady: Bool {
        runtime.agent == .running && runtime.mcp == .ready && mcpHealthy
    }

    var overallReady: Bool {
        localReady && runtime.tunnel == .connected
    }

    var toolCatalogRefreshRequired: Bool {
        guard let current = runtime.toolCatalogVersion,
              let discovered = discoveredToolCatalogVersion else {
            return false
        }
        return current != discovered || runtime.toolCatalogCount != discoveredToolCount
    }

    var toolCatalogWarningText: String? {
        guard let currentVersion = runtime.toolCatalogVersion,
              let currentCount = runtime.toolCatalogCount else { return nil }

        if let discoveredVersion = discoveredToolCatalogVersion {
            guard currentVersion != discoveredVersion || currentCount != discoveredToolCount else {
                return nil
            }
            let chatGPTCount = discoveredToolCount.map { "\($0) 个工具" } ?? "工具数量未知"
            return "服务端 \(currentCount) 个工具 / ChatGPT 当前会话 \(chatGPTCount)，工具目录版本不一致；重新连接或新建会话后会刷新。"
        }

        guard runtime.chatGPT != .notConfigured else { return nil }
        return "服务端 \(currentCount) 个工具 / ChatGPT 当前会话尚未确认工具目录；首次完成 tools/list 后会自动确认。"
    }

    var isPublicHTTPSMode: Bool {
        configuration.transportMode == .httpsCompatibility
    }

    var unrestrictedDevelopmentAccessEnabled: Bool {
        configuration.modificationPermission == .allow
            && configuration.shellPermission == .allow
            && configuration.gitPushPermission == .allow
    }

    func tunnelRuntimeKeyForCopy() -> String? {
        let value = (try? secretStore.string(for: .tunnelRuntimeAPIKey)) ?? nil
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    var publicHTTPSMCPURL: URL? {
        guard let hostname = configuration.httpsCompatibility?.hostname,
              let token = try? secretStore.string(for: .httpsCompatibilityAccessToken),
              !token.isEmpty else { return nil }
        return URL(string: "https://\(hostname)/mcp/\(token)")
    }

    /// 生成当前模式对应的 ChatGPT MCP 配置，避免 Tunnel 或公网地址变化后手工维护。
    func chatGPTMCPConfigurationText() -> String? {
        let endpoint: String
        let token: String

        switch configuration.transportMode {
        case .secureTunnel:
            guard let tunnel = configuration.secureTunnel,
                  let key = try? secretStore.string(for: .tunnelRuntimeAPIKey),
                  !key.isEmpty else { return nil }
            endpoint = tunnel.controlPlaneBaseURL + "/mcp"
            token = key
        case .httpsCompatibility:
            guard let url = publicHTTPSMCPURL,
                  let key = try? secretStore.string(for: .httpsCompatibilityAccessToken),
                  !key.isEmpty else { return nil }
            endpoint = url.absoluteString
            token = key
        }

        return "{\n  \"name\": \"Codex Harbor\",\n  \"url\": \"\(endpoint)\",\n  \"authorization\": \"Bearer \(token)\"\n}"
    }

    var agentRunning: Bool {
        runtime.agent == .running && runtime.processIdentifier.map(Self.processExists) == true
    }

    var mcpURLText: String {
        guard let value = runtime.mcpURL, let url = URL(string: value), let host = url.host else {
            return runtime.mcpURL ?? "尚未启动"
        }
        if let port = url.port {
            return "\(url.scheme ?? "http")://\(host):\(String(port))/mcp"
        }
        return value
    }

    func refresh() async {
        guard let paths else { return }
        // 手动链路检测期间冻结当前链路图，只刷新后台事实数据。
        // 避免 healthCheck 的瞬时中间态（例如 initialize HTTP 400）先发布到 UI，
        // 最终诊断完成后再由 applyManualDiagnostics 一次性提交节点状态。
        let preservedPipeline = isDiagnosing ? runtime.pipelineDiagnostics : nil

        refreshTunnelAvailability()
        refreshCloudflaredAvailability()
        refreshSecretAvailability()
        refreshCloudflareAuthorization()
        refreshCloudflareHostnameSuffixes()
        refreshChatGPTIntegration()
        if let transportController {
            apply(
                await transportController.healthCheck(configuration: configuration),
                preservingPipelineDiagnostics: preservedPipeline
            )
        } else {
            refreshLaunchAgentStatus()
            var refreshedRuntime = BridgeRuntimeState()
            if let preservedPipeline {
                refreshedRuntime.pipelineDiagnostics = preservedPipeline
            }
            runtime = refreshedRuntime
            mcpHealthy = false
        }
        if overallReady,
           statusMessage?.hasSuffix("远端链路仍在连接。") == true {
            statusMessage = "\(configuration.transportMode.displayName)已连接 · 本地 MCP 127.0.0.1:\(configuration.localMCPPort)"
        }
        if let entries = try? await AuditLogger(paths: paths).entries() {
            recentAuditEntries = Array(entries.suffix(12).reversed())
        }
        pendingApprovalRequests = BridgeApprovalStore(paths: paths).pendingRequests()
    }

    private func repairRuntimeState(_ state: BridgeRuntimeState) -> BridgeRuntimeState {
        var repaired = state

        // runtime.json 是 Agent 写出的缓存状态，不作为最终事实来源。
        // 例如电脑睡眠、网络切换、Agent 崩溃后，文件可能仍显示 running。
        if let pid = state.processIdentifier, !Self.processExists(pid) {
            repaired = BridgeRuntimeState()
        }

        // Agent 存活但传输进程已退出时，修正为降级状态，避免 UI 显示假连接。
        if repaired.agent == .running,
           repaired.transportProcessRunning == false,
           repaired.tunnel == .connected {
            repaired.tunnel = .connecting
            repaired.remoteEndpointReady = false
            repaired.transportMessage = "传输进程已停止，等待自动恢复。"
        }

        return repaired
    }

    private func startNetworkRecoveryMonitoring() {
        networkMonitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor [weak self] in
                guard let self else { return }
                let previous = self.lastNetworkStatus
                self.lastNetworkStatus = path.status
                guard previous != nil,
                      previous != .satisfied,
                      path.status == .satisfied,
                      self.configuration.enabled else { return }
                await self.reconcileRuntime()
            }
        }
        networkMonitor.start(queue: networkMonitorQueue)
    }

    @discardableResult
    func exportDiagnosticBundle(to destinationURL: URL) async -> Bool {
        guard !isExportingDiagnostics else { return false }
        isExportingDiagnostics = true
        defer { isExportingDiagnostics = false }

        let configuration = self.configuration
        let runtime = self.runtime
        let diagnostics = diagnosticResults
        let auditEntries = recentAuditEntries
        let integrationMarker = paths.map { ChatGPTIntegrationMarkerStore(paths: $0).load() } ?? nil

        do {
            let generated = try await Task.detached(priority: .utility) {
                try BridgeDiagnosticBundleExporter().export(
                    configuration: configuration,
                    runtime: runtime,
                    destinationDirectory: destinationURL.deletingLastPathComponent(),
                    integrationMarker: integrationMarker,
                    diagnostics: diagnostics,
                    auditEntries: auditEntries
                )
            }.value

            if generated.standardizedFileURL != destinationURL.standardizedFileURL {
                let fileManager = FileManager.default
                if fileManager.fileExists(atPath: destinationURL.path) {
                    try fileManager.removeItem(at: destinationURL)
                }
                try fileManager.moveItem(at: generated, to: destinationURL)
            }
            statusMessage = "诊断包已导出：\(destinationURL.lastPathComponent)"
            return true
        } catch {
            statusMessage = "诊断包导出失败：\(error.localizedDescription)"
            return false
        }
    }

    func decideApproval(_ request: BridgeApprovalRequest, allow: Bool) async {
        guard let paths else { return }
        BridgeApprovalStore(paths: paths).decide(id: request.id, allow: allow)
        pendingApprovalRequests = BridgeApprovalStore(paths: paths).pendingRequests()
        statusMessage = allow
            ? "已允许该操作，正在继续执行。"
            : "已拒绝该操作。"
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
        guard await save(updated) else { return }
        if enabled {
            await startAgent()
        } else {
            await stopAgent()
        }
    }

    func setLaunchAtLogin(_ enabled: Bool) async {
        var updated = configuration
        updated.launchAtLogin = enabled
        guard await save(updated) else { return }

        do {
            if enabled {
                guard updated.enabled else {
                    statusMessage = "登录自动启动偏好已保存；启用 ChatGPT 接入后生效。"
                    refreshLaunchAgentStatus()
                    return
                }
                guard agentExecutableURL() != nil else {
                    statusMessage = "未找到 HarborChatGPTAgent，无法配置登录自动启动。"
                    return
                }
                await startAgent()
                if agentRunning {
                    statusMessage = "登录自动启动已启用，Agent 由 launchd 独立托管。"
                }
            } else {
                if updated.enabled,
                   let executable = agentExecutableURL(),
                   let transportController {
                    let snapshot = try await transportController.restart(
                        configuration: updated,
                        agentExecutableURL: executable
                    )
                    apply(snapshot)
                } else {
                    await stopAgent()
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
        guard let executable = agentExecutableURL(), let transportController else {
            await refresh()
            return
        }
        do {
            let snapshot = try await transportController.recover(
                configuration: configuration,
                agentExecutableURL: executable
            )
            apply(snapshot)
            if configuration.enabled && snapshot.localReady && !snapshot.overallReady {
                statusMessage = "本地 MCP 已恢复，远端链路正在自动重连。"
            }
        } catch {
            statusMessage = error.localizedDescription
            await refresh()
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
        applyManualDiagnostics(diagnosticResults)
        let failures = diagnosticResults.filter { $0.status == .failed }.count
        statusMessage = failures == 0
            ? "完整诊断完成：未发现阻断问题。"
            : "完整诊断完成：发现 \(failures) 个需要处理的问题。"
    }

    func runPipelineDiagnostics() async {
        guard let paths else { return }
        isDiagnosing = true
        defer { isDiagnosing = false }
        await refresh()
        diagnosticResults = await BridgeDiagnosticsRunner().runPipeline(
            paths: paths,
            configuration: configuration,
            runtime: runtime
        )
        applyManualDiagnostics(diagnosticResults)
        let failures = diagnosticResults.filter { $0.status == .failed }.count
        let recovering = diagnosticResults.filter { $0.status == .warning }.count
        if failures > 0 {
            statusMessage = "链路检测完成：发现 \(failures) 个阻断问题。"
        } else if recovering > 0 {
            statusMessage = "链路检测完成：\(recovering) 个节点正在恢复。"
        } else {
            statusMessage = "链路检测完成：Agent、MCP、网络代理、Tunnel 与端点均正常。"
        }
    }

    private func applyManualDiagnostics(_ results: [BridgeDiagnosticResult]) {
        guard !runtime.pipelineDiagnostics.nodes.isEmpty else { return }
        let now = Date()
        let resultGroups: [String: [BridgeDiagnosticResult]] = [
            "agent": results.filter { $0.id == "agent" },
            // 检测期间链路图已被冻结，因此这里可以一次性提交完整 MCP 结果。
            // discovery / initialize / tools/list 任一步最终失败，都应反映为 MCP 节点异常。
            "mcp": results.filter { ["mcp", "mcp-initialize", "mcp-tools"].contains($0.id) },
            "tunnel-client": results.filter { $0.id == "transport-process" },
            "openai-tunnel": results.filter {
                ["network-proxy", "proxy", "tunnel", "tunnel-key", "public-mcp"].contains($0.id)
            }
        ]

        runtime.pipelineDiagnostics.nodes = runtime.pipelineDiagnostics.nodes.map { node in
            guard let matching = resultGroups[node.id], !matching.isEmpty else { return node }
            let failed = matching.first { $0.status == .failed }
            let warning = matching.first { $0.status == .warning }
            let measured = failed ?? warning ?? matching.max { $0.durationMilliseconds < $1.durationMilliseconds }
            let state: BridgeNodeState
            if failed != nil {
                state = .failed
            } else if warning != nil {
                state = node.state == .recovering ? .recovering : .waiting
            } else {
                state = .ready
            }
            return BridgeNodeDiagnostic(
                id: node.id,
                title: node.title,
                state: state,
                message: measured?.message ?? node.message,
                lastCheckAt: now,
                latency: measured?.durationMilliseconds,
                details: node.details
            )
        }
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
        guard await save(updated) else { return }

        if updated.enabled {
            await startAgent()
        }
        statusMessage = "本地工具权限已更新。"
    }

    func setUnrestrictedDevelopmentAccess(_ enabled: Bool) async {
        var updated = configuration
        if enabled {
            updated.modificationPermission = .allow
            updated.shellPermission = .allow
            updated.gitPushPermission = .allow
        } else {
            updated.modificationPermission = .ask
            updated.shellPermission = .safeOnly
            updated.gitPushPermission = .ask
        }

        guard await save(updated) else { return }
        if let paths {
            BridgeApprovalStore(paths: paths).clear()
            pendingApprovalRequests = []
        }

        if updated.enabled {
            await startAgent()
        }
        statusMessage = enabled
            ? "开发模式已开启：文件修改、Shell 与 Git Push 均直接允许。"
            : "已恢复安全模式：高风险操作会询问确认。"
    }

    func preparePublicHTTPS(
        cloudflaredPath: String,
        hostnameSuffix: String,
        localPort: UInt16
    ) async {
        guard let paths else { return }
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "先选择一个本地项目目录。"
            return
        }

        isWorking = true
        statusMessage = "正在配置公网 HTTPS 连接…"
        defer { isWorking = false }

        do {
            guard let executable = await ensureCloudflared(preferredPath: cloudflaredPath) else { return }
            let token = try secretStore.httpsCompatibilityAccessToken()
            let compatibility = try HTTPSCompatibilityConfigurator().prepare(
                paths: paths,
                localMCPAccessToken: token,
                cloudflaredPath: executable.path,
                hostnameSuffix: hostnameSuffix,
                localPort: localPort
            )

            var updated = configuration
            updated.transportMode = .httpsCompatibility
            updated.httpsCompatibility = compatibility
            updated.enabled = true
            updated.launchAtLogin = true
            guard await save(updated) else { return }

            await startAgent()
            try? await Task.sleep(for: .milliseconds(600))
            await refresh()

            if runtime.tunnel == .connected {
                statusMessage = "公网 HTTPS 已连接。"
            } else {
                statusMessage = "cloudflared 已启动，正在等待公网 HTTPS 端点就绪。"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func loginToCloudflare(cloudflaredPath: String) async {
        guard !isCloudflareAuthorizing else { return }
        isCloudflareAuthorizing = true
        defer { isCloudflareAuthorizing = false }

        guard let executable = await ensureCloudflared(preferredPath: cloudflaredPath) else { return }

        statusMessage = "浏览器已打开，请完成 Cloudflare 授权。"
        let failure = await Task.detached(priority: .userInitiated) {
            Self.runCloudflareLogin(executable: executable)
        }.value
        refreshCloudflareAuthorization()
        refreshCloudflareHostnameSuffixes()

        if let failure {
            statusMessage = failure
        } else if cloudflareAuthorized {
            statusMessage = "Cloudflare 授权完成。"
        } else {
            statusMessage = "Cloudflare 未生成授权凭据，请重试。"
        }
    }

    func fetchCloudflareZones(apiToken: String) async {
        guard !isFetchingCloudflareZones else { return }

        let trimmed = apiToken.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            if !trimmed.isEmpty {
                try secretStore.set(trimmed, for: .cloudflareZoneAPIToken)
            }

            guard let token = try secretStore.string(for: .cloudflareZoneAPIToken),
                  !token.isEmpty else {
                statusMessage = "请先填写 Cloudflare Zone 只读 API Token。"
                return
            }

            isFetchingCloudflareZones = true
            defer { isFetchingCloudflareZones = false }

            cloudflareZones = try await cloudflareZoneService.activeZones(apiToken: token)
            hasCloudflareZoneAPIToken = true
            statusMessage = cloudflareZones.isEmpty
                ? "Cloudflare 账号下未发现可用域名。"
                : "已从 Cloudflare 获取 \(cloudflareZones.count) 个根域名。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func deleteTransportConfiguration(_ mode: BridgeTransportMode) async {
        let deletingActiveMode = configuration.enabled && configuration.transportMode == mode
        if deletingActiveMode {
            await stopAgent()
        }

        let previousConfiguration = configuration
        var updated = configuration
        switch mode {
        case .secureTunnel:
            updated.secureTunnel = nil
        case .httpsCompatibility:
            updated.httpsCompatibility = nil
        }
        if deletingActiveMode {
            updated.enabled = false
            updated.launchAtLogin = false
        }

        // Persist the non-destructive configuration change first. If this
        // fails, keep credentials and artifacts intact and restore the service.
        guard await save(updated) else {
            let saveError = statusMessage ?? "配置保存失败"
            if deletingActiveMode {
                await startAgent()
            }
            statusMessage = "删除\(mode.displayName)失败，原配置未清理：\(saveError)"
            return
        }

        do {
            switch mode {
            case .secureTunnel:
                try secretStore.remove(.tunnelRuntimeAPIKey)
            case .httpsCompatibility:
                try secretStore.remove(.httpsCompatibilityAccessToken)
                try? secretStore.remove(.cloudflareZoneAPIToken)
                cloudflareZones = []
                hasCloudflareZoneAPIToken = false
                if let paths {
                    try? FileManager.default.removeItem(at: paths.chatGPTIntegrationURL)
                }
            }

            if let paths {
                try BridgeTransportArtifactCleaner().removeArtifacts(
                    for: mode,
                    configuration: previousConfiguration,
                    paths: paths
                )
            }

            refreshSecretAvailability()
            refreshTunnelAvailability()
            refreshCloudflaredAvailability()
            refreshCloudflareAuthorization()
            refreshCloudflareHostnameSuffixes()
            refreshChatGPTIntegration()
            await refresh()
            statusMessage = "\(mode.displayName)的本地配置、专用凭据与 Harbor 下载组件已清理；共享登录授权和云端资源未删除。"
        } catch {
            await refresh()
            statusMessage = "\(mode.displayName)配置已删除，但部分本地清理失败：\(error.localizedDescription)"
        }
    }

    func activateTransportMode(_ mode: BridgeTransportMode) async {
        await startTransportMode(mode)
    }

    func selectTransportMode(_ mode: BridgeTransportMode) async {
        guard transportModeIsConfigured(mode) else {
            statusMessage = "\(mode.displayName)尚未完整配置。"
            return
        }
        guard configuration.transportMode != mode else {
            statusMessage = "当前已经选择\(mode.displayName)。"
            return
        }
        guard !isSwitchingTransport else {
            statusMessage = "正在切换连接方式，请稍候。"
            return
        }

        let shouldRestart = configuration.enabled
        isSwitchingTransport = true
        transportSwitchMessage = "正在切换到\(mode.displayName)…"
        defer {
            isSwitchingTransport = false
            transportSwitchMessage = nil
        }

        guard let executable = agentExecutableURL(), let transportController else {
            statusMessage = "未找到 HarborChatGPTAgent，无法切换连接方式。"
            return
        }
        do {
            let snapshot = try await transportController.switchTransport(
                to: mode,
                configuration: configuration,
                agentExecutableURL: executable
            )
            apply(snapshot)
            statusMessage = shouldRestart
                ? "已切换到\(mode.displayName)。"
                : "已选择\(mode.displayName)，启动服务后会自动连接。"
        } catch {
            // Manager 已同时恢复配置和旧进程，这里只刷新可见状态。
            configuration = (try? transportController.load()) ?? configuration
            await refresh()
            statusMessage = "切换失败，已恢复原连接：\(error.localizedDescription)"
        }
    }

    func testTransportMode(_ mode: BridgeTransportMode) async {
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "请先添加至少一个允许访问目录，再测试连接。"
            return
        }

        guard transportModeIsConfigured(mode) else {
            statusMessage = "\(mode.displayName)尚未完整配置，保存配置后再测试。"
            return
        }

        if configuration.enabled && configuration.transportMode != mode {
            statusMessage = "\(mode.displayName)当前处于待使用状态；为避免中断正在使用的连接，请先切换到该方式后再测试。"
            return
        }

        if !configuration.enabled {
            await startTransportMode(mode)
        }

        await runDiagnostics()
    }

    func startTransportMode(_ mode: BridgeTransportMode) async {
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "请先添加至少一个允许访问目录，再启动服务。"
            return
        }

        guard transportModeIsConfigured(mode) else {
            statusMessage = "\(mode.displayName)尚未完整配置。"
            return
        }

        // 切换连接方式前清理旧运行态，避免旧 transport / MCP 健康状态污染新链路判断。
        // 配置仍然保留，仅清理本次运行产生的状态。
        if configuration.enabled && configuration.transportMode != mode {
            runtime = BridgeRuntimeState()
            mcpHealthy = false
            statusMessage = "正在切换到\(mode.displayName)，重新建立连接…"
        }

        var updated = configuration
        updated.transportMode = mode
        updated.enabled = true
        updated.launchAtLogin = true
        guard await save(updated) else { return }
        await startAgent()
        await refresh()
        if overallReady {
            statusMessage = "\(mode.displayName)已连接 · 本地 MCP 127.0.0.1:\(updated.localMCPPort)"
        } else if agentRunning {
            statusMessage = "\(mode.displayName)已在 127.0.0.1:\(updated.localMCPPort) 启动，远端链路仍在连接。"
        } else if statusMessage?.isEmpty != false {
            statusMessage = "\(mode.displayName)未能启动，请查看连接监控中的失败阶段。"
        }
    }

    private func transportModeIsConfigured(_ mode: BridgeTransportMode) -> Bool {
        guard let transportController else { return false }
        return (try? transportController.isConfigured(mode, configuration: configuration)) ?? false
    }

    func savePublicHTTPSConfiguration(
        cloudflaredPath: String,
        hostnameSuffix: String,
        localPort: UInt16
    ) async {
        guard let paths else { return }

        isWorking = true
        statusMessage = "正在保存公网 HTTPS 配置…"
        defer { isWorking = false }

        do {
            guard let executable = await ensureCloudflared(preferredPath: cloudflaredPath) else { return }
            let token = try secretStore.httpsCompatibilityAccessToken()
            let compatibility = try HTTPSCompatibilityConfigurator().prepare(
                paths: paths,
                localMCPAccessToken: token,
                cloudflaredPath: executable.path,
                hostnameSuffix: hostnameSuffix,
                localPort: localPort
            )

            var updated = configuration
            updated.httpsCompatibility = compatibility
            guard await save(updated) else { return }
            refreshSecretAvailability()
            statusMessage = "公网 HTTPS 配置已保存；启动服务后会自动连接。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func saveSecureTunnelConfiguration(
        tunnelID: String,
        runtimeAPIKey: String,
        executablePath: String? = nil,
        controlPlaneBaseURL: String = "https://api.openai.com",
        proxyStrategy: TunnelProxyStrategy? = nil
    ) async {
        var resolvedExecutablePath = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedExecutablePath?.isEmpty != false {
            resolvedExecutablePath = configuration.secureTunnel?.executablePath
        }
        if resolvedExecutablePath?.isEmpty != false {
            resolvedExecutablePath = binaryManager?.locateTunnelClient(preferredPath: nil)?.path
        }
        if !tunnelClientAvailable && resolvedExecutablePath?.isEmpty != false {
            guard let installedPath = await installTunnelClient() else { return }
            resolvedExecutablePath = installedPath
        }

        await configureTunnel(
            tunnelID: tunnelID,
            runtimeAPIKey: runtimeAPIKey,
            executablePath: resolvedExecutablePath,
            controlPlaneBaseURL: controlPlaneBaseURL,
            proxyStrategy: proxyStrategy,
            activateTransport: false
        )
    }

    func prepareInitialConnection(
        tunnelID: String,
        runtimeAPIKey: String,
        executablePath: String? = nil,
        controlPlaneBaseURL: String = "https://api.openai.com"
    ) async {
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "先选择一个本地项目目录。"
            return
        }

        var resolvedExecutablePath = executablePath?.trimmingCharacters(in: .whitespacesAndNewlines)
        if resolvedExecutablePath?.isEmpty != false {
            resolvedExecutablePath = configuration.secureTunnel?.executablePath
        }
        if resolvedExecutablePath?.isEmpty != false {
            resolvedExecutablePath = binaryManager?.locateTunnelClient(preferredPath: nil)?.path
        }
        if !tunnelClientAvailable && resolvedExecutablePath?.isEmpty != false {
            guard let installedPath = await installTunnelClient() else { return }
            resolvedExecutablePath = installedPath
        }

        var updated = configuration
        updated.transportMode = .secureTunnel
        updated.launchAtLogin = true
        guard await save(updated) else { return }

        await configureTunnel(
            tunnelID: tunnelID,
            runtimeAPIKey: runtimeAPIKey,
            executablePath: resolvedExecutablePath,
            controlPlaneBaseURL: controlPlaneBaseURL
        )

        guard configuration.secureTunnel != nil, hasTunnelRuntimeKey else { return }
        if !configuration.enabled {
            await setEnabled(true)
        } else if configuration.launchAtLogin, launchAgentStatus?.loaded != true {
            await setLaunchAtLogin(true)
        }
        await refresh()
    }

    func configureTunnel(
        tunnelID: String,
        runtimeAPIKey: String,
        executablePath: String? = nil,
        controlPlaneBaseURL: String = "https://api.openai.com",
        proxyStrategy: TunnelProxyStrategy? = nil,
        activateTransport: Bool = true
    ) async {
        let trimmedID = tunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard Self.isValidTunnelID(trimmedID) else {
            statusMessage = "Tunnel ID 格式无效，应为 tunnel_ 加 32 位小写十六进制字符。"
            return
        }

        let trimmedControlPlane = controlPlaneBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let controlPlaneURL = URL(string: trimmedControlPlane),
              controlPlaneURL.scheme == "https",
              controlPlaneURL.host?.isEmpty == false else {
            statusMessage = "Control Plane 地址必须是有效的 HTTPS URL。"
            return
        }

        do {
            let trimmedKey = runtimeAPIKey.trimmingCharacters(in: .whitespacesAndNewlines)
            let replacedRuntimeKey = !trimmedKey.isEmpty
            if !trimmedKey.isEmpty {
                guard let transportController else {
                    statusMessage = "连接控制器不可用，Runtime Key 未保存。"
                    return
                }
                _ = try await transportController.refreshRuntimeKey(
                    trimmedKey,
                    configuration: configuration,
                    agentExecutableURL: agentExecutableURL(),
                    restartIfActive: false
                )
            } else if try secretStore.string(for: .tunnelRuntimeAPIKey) == nil {
                statusMessage = "请填写 Secure MCP Tunnel runtime API key。"
                return
            }

            let wasActiveSecureTunnel = configuration.enabled
                && configuration.transportMode == .secureTunnel
            let previousTunnelID = configuration.secureTunnel?.tunnelID
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
            if activateTransport {
                updated.transportMode = .secureTunnel
            }
            updated.secureTunnel = SecureTunnelConfiguration(
                tunnelID: trimmedID,
                executablePath: resolvedExecutablePath,
                controlPlaneBaseURL: trimmedControlPlane,
                proxyStrategy: proxyStrategy
                    ?? updated.secureTunnel?.proxyStrategy
                    ?? .automatic
            )
            guard await save(updated) else { return }
            refreshSecretAvailability()
            if let previousTunnelID,
               !previousTunnelID.isEmpty,
               previousTunnelID != trimmedID {
                tunnelMigrationMessage = "Tunnel ID 已从 …\(previousTunnelID.suffix(8)) 变更为 …\(trimmedID.suffix(8))。ChatGPT 中旧的本地管道插件不会自动迁移，请删除旧插件并使用新 Tunnel ID 重新添加。"
            } else if previousTunnelID == nil {
                tunnelMigrationMessage = nil
            }

            let shouldRestartSecureTunnel = updated.enabled
                && updated.transportMode == .secureTunnel
                && (activateTransport || wasActiveSecureTunnel)
            if shouldRestartSecureTunnel {
                await startAgent()
                if agentRunning && replacedRuntimeKey {
                    statusMessage = "Runtime Key 已覆盖保存，新 Agent 已使用新凭据启动。"
                }
            } else {
                statusMessage = replacedRuntimeKey
                    ? "OpenAI 本地管道配置与新 Runtime Key 已覆盖保存。"
                    : "OpenAI 本地管道配置已保存。启动服务后会自动建立连接。"
            }
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func installTunnelClient() async -> String? {
        guard let binaryManager else { return nil }
        isWorking = true
        statusMessage = "正在下载并校验 OpenAI 官方 tunnel-client…"
        defer { isWorking = false }
        do {
            let result = try await binaryManager.installTunnelClient()
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

    private func ensureCloudflared(preferredPath: String? = nil) async -> URL? {
        guard let binaryManager else { return nil }
        if binaryManager.locateCloudflared(preferredPath: preferredPath) == nil {
            statusMessage = "正在下载并校验 Cloudflare 官方 cloudflared…"
        }

        do {
            let result = try await binaryManager.ensureCloudflared(preferredPath: preferredPath)
            cloudflaredAvailable = true
            cloudflaredExecutablePath = result.executableURL.path
            if let version = result.installedVersion {
                statusMessage = "cloudflared \(version) 已自动安装并通过 SHA-256 校验。"
            }
            return result.executableURL
        } catch {
            cloudflaredAvailable = false
            cloudflaredExecutablePath = nil
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
            }
            statusMessage = "OpenAI 本地管道配置已移除。Local Agent 和 Codex 配置互不受影响。"
        } catch {
            statusMessage = error.localizedDescription
        }
    }

    func startAgent() async {
        guard !configuration.allowedRoots.isEmpty else {
            statusMessage = "请先添加至少一个允许访问的开发目录。"
            return
        }
        guard let executable = agentExecutableURL(), let transportController else {
            statusMessage = "未找到 HarborChatGPTAgent。请先重新构建安装包。"
            return
        }
        isWorking = true
        statusMessage = "正在停止旧的本地 Agent…"
        defer { isWorking = false }

        statusMessage = "正在 127.0.0.1:\(configuration.localMCPPort) 启动本地 Agent…"
        do {
            let snapshot = try await transportController.start(
                configuration: configuration,
                agentExecutableURL: executable
            )
            apply(snapshot)
            if overallReady {
                statusMessage = "已连接 · 本地 MCP 127.0.0.1:\(configuration.localMCPPort)"
            } else if agentRunning {
                statusMessage = "本地 Agent 已在 127.0.0.1:\(configuration.localMCPPort) 启动，远端链路仍在连接。"
            } else {
                statusMessage = "Agent 未能监听固定端口 127.0.0.1:\(configuration.localMCPPort)，请查看连接监控中的失败阶段。"
            }
        } catch {
            statusMessage = error.localizedDescription
            await refresh()
        }
    }

    func stopAgent() async {
        isWorking = true
        defer { isWorking = false }
        if let transportController {
            let snapshot = await transportController.stop(
                configuration: configuration,
                agentExecutableURL: agentExecutableURL()
            )
            apply(snapshot)
        } else {
            runtime = BridgeRuntimeState()
            mcpHealthy = false
            refreshLaunchAgentStatus()
        }
        statusMessage = "ChatGPT 接入已停止。"
    }

    private func apply(
        _ snapshot: BridgeLifecycleSnapshot,
        preservingPipelineDiagnostics preservedPipeline: BridgePipelineDiagnostics? = nil
    ) {
        configuration = snapshot.configuration
        var updatedRuntime = repairRuntimeState(snapshot.runtime)
        if let preservedPipeline {
            updatedRuntime.pipelineDiagnostics = preservedPipeline
        }
        runtime = updatedRuntime
        launchAgentStatus = snapshot.launchAgentStatus
        mcpHealthy = snapshot.mcpHealthy
    }

    private func refreshLaunchAgentStatus() {
        launchAgentStatus = launchAgentManager.status()
    }

    @discardableResult
    private func save(_ configuration: BridgeConfiguration) async -> Bool {
        guard let transportController else {
            statusMessage = "连接控制器不可用，未执行后续操作。"
            return false
        }
        do {
            try transportController.save(configuration)
            self.configuration = configuration
            statusMessage = nil
            return true
        } catch {
            statusMessage = error.localizedDescription
            return false
        }
    }

    private func refreshTunnelAvailability() {
        tunnelClientAvailable = binaryManager?.locateTunnelClient(
            preferredPath: configuration.secureTunnel?.executablePath
        ) != nil
    }

    private func refreshCloudflaredAvailability() {
        let executable = binaryManager?.locateCloudflared(
            preferredPath: configuration.httpsCompatibility?.cloudflaredPath
        )
        cloudflaredAvailable = executable != nil
        cloudflaredExecutablePath = executable?.path
    }



    private func refreshSecretAvailability() {
        hasTunnelRuntimeKey = ((try? secretStore.string(for: .tunnelRuntimeAPIKey)) ?? nil)?.isEmpty == false
        hasPublicHTTPSAccessToken = ((try? secretStore.string(for: .httpsCompatibilityAccessToken)) ?? nil)?.isEmpty == false
        hasCloudflareZoneAPIToken = ((try? secretStore.string(for: .cloudflareZoneAPIToken)) ?? nil)?.isEmpty == false
    }

    private func refreshCloudflareAuthorization() {
        let certificate = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".cloudflared", isDirectory: true)
            .appendingPathComponent("cert.pem")
        cloudflareAuthorized = FileManager.default.isReadableFile(atPath: certificate.path)
    }

    private func refreshCloudflareHostnameSuffixes() {
        var suffixes = (try? HTTPSCompatibilityConfigurator().detectedHostnameSuffixes()) ?? []
        if let hostname = configuration.httpsCompatibility?.hostname {
            let labels = hostname.split(separator: ".")
            if labels.count >= 3 {
                let suffix = labels.dropFirst().joined(separator: ".")
                if !suffixes.contains(suffix) {
                    suffixes.append(suffix)
                }
            }
        }
        cloudflareHostnameSuffixes = Array(Set(suffixes)).sorted()
    }

    private func refreshChatGPTIntegration() {
        guard let paths else {
            chatGPTPublicHTTPSConfigured = false
            discoveredToolCatalogVersion = nil
            discoveredToolCount = nil
            catalogDiscoveredAt = nil
            return
        }
        let markerStore = ChatGPTIntegrationMarkerStore(paths: paths)
        let marker = markerStore.load()
        discoveredToolCatalogVersion = marker?.discoveredToolCatalogVersion
        discoveredToolCount = marker?.discoveredToolCount
        catalogDiscoveredAt = marker?.catalogDiscoveredAt
        chatGPTPublicHTTPSConfigured = markerStore
            .matchesPublicHTTPS(hostname: configuration.httpsCompatibility?.hostname)
    }

    nonisolated private static func runCloudflareLogin(executable: URL) -> String? {
        let process = Process()
        let stderr = Pipe()
        process.executableURL = executable
        process.arguments = ["tunnel", "login"]
        process.standardError = stderr
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return "无法启动 Cloudflare 授权：\(error.localizedDescription)"
        }
        guard process.terminationStatus == 0 else {
            let detail = String(
                decoding: stderr.fileHandleForReading.readDataToEndOfFile(),
                as: UTF8.self
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            return detail.isEmpty ? "Cloudflare 授权未完成。" : "Cloudflare 授权失败：\(detail)"
        }
        return nil
    }

    private static func isValidTunnelID(_ value: String) -> Bool {
        guard value.hasPrefix("tunnel_"), value.count == 39 else { return false }
        return value.dropFirst(7).allSatisfy { $0.isNumber || ("a"..."f").contains(String($0)) }
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
