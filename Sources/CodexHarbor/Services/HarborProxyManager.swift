import AppKit
import CodexHarborCore
import CryptoKit
import Foundation
import Darwin
import Security
import SystemConfiguration

private struct HarborProxyState: Codable, Equatable, Sendable {
    var nodes: [HarborProxyNode] = []
    var subscriptions: [HarborProxySubscription] = []
    var selectedID: String?
    // Optional so existing encrypted configurations continue to decode.
    var vpnGateUnderlayNodeID: String?
    var routingRules = true
    // Optional so existing Keychain JSON decodes without losing saved subscriptions.
    var forcedProxyDomains: [String]?
    // Optional to preserve existing Keychain configurations on upgrade.
    var httpListenPort: Int?
    var autoManageSystemProxy: Bool?
    // Optional for backwards-compatible decoding of encrypted existing state.
    var nodeServerLocations: [String: HarborProxyIPLocation]?
    var nodeServerResolvedAt: [String: Date]?
    var nodeNetworkEvidence: [String: HarborProxyNetworkEvidence]?
    // Per-node observed exit, never indexed by shared server IP.
    var nodeExitLocations: [String: HarborProxyExitLocation]?
    // Optional so older encrypted state remains decodable after latency
    // results become durable.
    var probeResults: [String: HarborProxyProbeResult]?
    // A probe made with the former HTTPS/curl method cannot be compared with
    // v2rayN-style SOCKS real-ping results.
    var realPingMethodVersion: Int?
}
@MainActor
private struct HarborProxyProcessRecord: Codable {
    var pid: Int32
    var configPath: String
    var executablePath: String
    var underlay: HarborProxyUnderlayRecord?
}

private struct HarborProxyUnderlayRecord: Codable {
    var pid: Int32
    var configPath: String
    var executablePath: String
    var httpPort: Int
    var nodeID: String
}

private actor HarborProxyPersistence {
    private static let legacyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.codexharbor.v2rayn-replacement",
        kSecAttrAccount as String: "settings"
    ]
    private static let keyQuery: [String: Any] = [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.codexharbor.proxy-state-key",
        kSecAttrAccount as String: "v2"
    ]

    private let stateURL: URL
    private var newestGeneration = 0

    init(root: URL) {
        stateURL = root.appendingPathComponent("proxy-settings-v2.enc")
    }

    /// Load away from the main actor. Existing users migrate once from the
    /// legacy large Keychain item to an encrypted file protected by a small
    /// Keychain-held AES key.
    func load() throws -> HarborProxyState {
        if FileManager.default.fileExists(atPath: stateURL.path) {
            return try decrypt(Data(contentsOf: stateURL))
        }
        guard let legacy = loadLegacy() else { return HarborProxyState() }
        try write(legacy)
        // Delete only after the encrypted replacement was written and decoded.
        _ = SecItemDelete(Self.legacyQuery as CFDictionary)
        return legacy
    }

    func save(_ value: HarborProxyState, generation: Int) throws {
        guard generation >= newestGeneration else { return }
        newestGeneration = generation
        try write(value)
    }

    private func loadLegacy() -> HarborProxyState? {
        var q = Self.legacyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data,
              let state = try? JSONDecoder().decode(HarborProxyState.self, from: data) else {
            return nil
        }
        return state
    }

    private func encryptionKey(create: Bool) throws -> SymmetricKey {
        var q = Self.keyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create, status == errSecItemNotFound else {
            throw HarborProxyError.invalid("无法读取代理配置加密密钥")
        }

        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HarborProxyError.invalid("无法生成代理配置加密密钥")
        }
        let data = Data(bytes)
        var insert = Self.keyQuery
        insert[kSecValueData as String] = data
        insert[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(insert as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw HarborProxyError.invalid("无法保存代理配置加密密钥")
        }
        return SymmetricKey(data: data)
    }

    private func decrypt(_ encrypted: Data) throws -> HarborProxyState {
        let key = try encryptionKey(create: false)
        let box = try AES.GCM.SealedBox(combined: encrypted)
        let data = try AES.GCM.open(box, using: key)
        return try JSONDecoder().decode(HarborProxyState.self, from: data)
    }

    private func write(_ value: HarborProxyState) throws {
        let key = try encryptionKey(create: true)
        let encoded = try JSONEncoder().encode(value)
        guard let encrypted = try AES.GCM.seal(encoded, using: key).combined else {
            throw HarborProxyError.invalid("无法加密代理配置")
        }
        let parent = stateURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try encrypted.write(to: stateURL, options: [.atomic, .completeFileProtection])
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600], ofItemAtPath: stateURL.path
        )
        // Verify the committed ciphertext before allowing legacy removal.
        _ = try decrypt(Data(contentsOf: stateURL))
    }
}

/// Event-driven SystemConfiguration observer. It keeps the cached ownership
/// snapshot current even when another proxy app changes macOS settings while
/// Codex Harbor remains frontmost.
private final class HarborSystemProxyChangeMonitor: @unchecked Sendable {
    private var store: SCDynamicStore?
    private var source: CFRunLoopSource?
    private let onChange: @Sendable () -> Void

    init(onChange: @escaping @Sendable () -> Void) {
        self.onChange = onChange
    }

    func start() {
        guard store == nil else { return }
        var context = SCDynamicStoreContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        let callback: SCDynamicStoreCallBack = { _, _, info in
            guard let info else { return }
            let monitor = Unmanaged<HarborSystemProxyChangeMonitor>
                .fromOpaque(info).takeUnretainedValue()
            monitor.onChange()
        }
        guard let store = SCDynamicStoreCreate(
            nil,
            "com.codexharbor.proxy-state-monitor" as CFString,
            callback,
            &context
        ) else { return }
        let patterns = [
            "Setup:/Network/Service/.*/Proxies",
            "State:/Network/Global/Proxies",
            "State:/Network/Global/IPv4"
        ] as CFArray
        guard SCDynamicStoreSetNotificationKeys(store, nil, patterns),
              let source = SCDynamicStoreCreateRunLoopSource(nil, store, 0) else { return }
        self.store = store
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    deinit {
        if let source {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        }
    }
}

@MainActor
final class HarborProxyManager: ObservableObject {
    static let shared = HarborProxyManager()
    @Published private(set) var nodes: [HarborProxyNode] = []
    @Published private(set) var subscriptions: [HarborProxySubscription] = []
    @Published private(set) var selectedID: String?
    /// Runtime identity is separate from the desired/saved profile; the UI
    /// must never call a merely selected node "connected".
    @Published private(set) var activeNodeID: String?
    @Published private(set) var running = false
    @Published private(set) var healthy = false
    @Published private(set) var checkingConnectivity = false
    @Published private(set) var websiteChecking = false
    @Published private(set) var busy = false
    @Published private(set) var systemManaged = false
    @Published private(set) var status = "已关闭"
    @Published private(set) var detail = ""
    @Published private(set) var localPort: Int?
    @Published private(set) var configuredHTTPPort = HarborProxyPortPolicy.defaultHTTPPort
    @Published private(set) var switchingNodeID: String?
    private var pendingActivation = HarborProxyActivationQueue()
    private var activationInProgress = false
    /// Cancels only the isolated preconnection check; it never stops the
    /// currently active proxy or changes macOS network settings.
    private var activationPreflightCancellation: HarborLatencyCancellation?
    private var autoManageSystemProxy = true
    @Published private(set) var probeResults: [String: HarborProxyProbeResult] = [:]
    @Published private(set) var nodeServerLocations: [String: HarborProxyIPLocation] = [:]
    @Published private(set) var nodeNetworkEvidence: [String: HarborProxyNetworkEvidence] = [:]
    @Published private(set) var nodeExitLocations: [String: HarborProxyExitLocation] = [:]
    @Published private(set) var exitGeoUpdating = false
    @Published private(set) var exitGeoCompleted = 0
    @Published private(set) var exitGeoTotal = 0
    @Published private(set) var latencyTesting = false
    @Published private(set) var latencyBatchIDs: Set<String> = []
    @Published private(set) var installingCore = false
    @Published private(set) var latencyCurrentID: String?
    @Published private(set) var latencyTestingIDs: Set<String> = []
    @Published private(set) var latencyCompleted = 0
    @Published private(set) var latencyTotal = 0
    private var latencyCancellationRequested = false
    private var latencyCancellation: HarborLatencyCancellation?
    @Published private(set) var subscriptionUpdatedAt: [String: Date] = [:]
    @Published var routingRules = true {
        didSet {
            guard configurationLoaded else { return }
            store.routingRules = routingRules
            persist()
        }
    }
    @Published private(set) var forcedProxyDomains = HarborProxyDomainRules.defaults
    @Published private(set) var requiresRecovery = false
    @Published private(set) var systemProxyDescription = "未启用"
    private var store = HarborProxyState()
    private let persistence: HarborProxyPersistence
    private var persistenceGeneration = 0
    private var persistenceTask: Task<Void, Never>?
    private var geoRefreshTask: Task<Void, Never>?
    private var exitGeoTask: Task<Void, Never>?
    private var exitGeoPendingIDs = Set<String>()
    private var exitGeoForcedIDs = Set<String>()
    private var exitGeoManualIDs = Set<String>()
    private var exitGeoManualSucceeded = 0
    private var exitGeoAttemptedAt: [String: Date] = [:]
    private var exitGeoFailureCounts: [String: Int] = [:]
    private var exitGeoRetryTask: Task<Void, Never>?
    private var nodeServerResolvedAt: [String: Date] = [:]
    private var lastActiveHealthCheckAt: Date?
    private var configurationLoaded = false
    private var child: Process?
    private var adoptedPID: Int32?
    private var configPath: URL?
    private var underlayChild: Process?
    private var adoptedUnderlayPID: Int32?
    private var underlayConfigPath: URL?
    private var underlayPort: Int?
    private var vpnGateUnderlayNodeID: String?
    private var bootstrapped = false
    private var bootstrapping = false
    /// Bounded, non-sensitive startup tracing for diagnosing fixed-port recovery.
    private func startupTrace(_ stage: String) {
        let note = [
            "stage": stage,
            "time": ISO8601DateFormatter().string(from: .now),
            "selectedNodeAvailable": selectedNode != nil ? "yes" : "no",
            "nodeCount": String(nodes.count),
            "hasRecoveryRecord": HarborSystemProxy.hasBackup ? "yes" : "no",
            "ownsSystemProxy": HarborSystemProxy.isOwned() ? "yes" : "no",
            "hasProcessRecord": FileManager.default.fileExists(atPath: runtimeRecordURL.path) ? "yes" : "no",
            "configuredPort": String(configuredHTTPPort)
        ]
        let value = note.sorted { $0.key < $1.key }
            .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
        try? Data((value + "\n").utf8).write(
            to: root.appendingPathComponent("startup-diagnostics.txt"), options: .atomic
        )
    }
    /// Used to prevent a delayed health probe from updating a newer node.
    private var connectionGeneration: UInt64 = 0
    private var healthTask: Task<Void, Never>?
    /// Cheap process-only check, started only while Xray runs. Handles adoption
    /// of a previous process, where Process.terminationHandler is unavailable.
    private var livenessTask: Task<Void, Never>?
    private var intentionallyStoppingCore = false
    private var runtimeRecordURL: URL { root.appendingPathComponent("active-process.json") }
    /// Private, local-only Xray warnings. Refreshed for each new Xray process;
    /// never included in the public app logs or remote MCP payloads.
    private var runtimeErrorLogURL: URL { root.appendingPathComponent("xray-runtime-warnings.log") }
    private let maxRuntimeErrorLogBytes: UInt64 = 512 * 1024
    private let retainedRuntimeErrorTailBytes: UInt64 = 64 * 1024
    private let root: URL
    private var appActivationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var systemProxyMonitor: HarborSystemProxyChangeMonitor?
    var selectedNode: HarborProxyNode? { nodes.first { $0.id == selectedID } }
    var activeNode: HarborProxyNode? { nodes.first { $0.id == activeNodeID } }
    private var workingUnderlaySocksPort: Int? {
        guard running, healthy else { return nil }
        if activeNode?.protocolName == "openvpn" { return underlayPort.map { $0 + 1 } }
        return localPort.map { $0 + 1 }
    }

    /// A relay's validity is scoped to its network path. Changing from
    /// direct access to VLESS (or switching VLESS nodes) requires new evidence.
    private var vpnGateProbeRouteID: String {
        guard workingUnderlaySocksPort != nil else { return "direct" }
        let baseID = activeNode?.protocolName == "openvpn"
            ? vpnGateUnderlayNodeID : activeNodeID
        return "underlay:" + (baseID ?? "unknown")
    }

    private func runningConfigMatches(_ id: String, path: URL?) -> Bool {
        guard let node = nodes.first(where: { $0.id == id }),
              let path, let data = try? Data(contentsOf: path) else { return false }
        return node.protocolName == "openvpn"
            ? HarborMihomoConfig.matches(configuration: data, node: node,
                                         underlaySocksPort: underlayPort.map { $0 + 1 })
            : HarborProxyRuntimeIdentity.matches(configuration: data, node: node)
    }

    private func underlayRecord(nodeID: String?) -> HarborProxyUnderlayRecord? {
        guard let nodeID, let underlayPort, let underlayConfigPath,
              let pid = underlayChild?.processIdentifier ?? adoptedUnderlayPID else { return nil }
        return HarborProxyUnderlayRecord(
            pid: pid, configPath: underlayConfigPath.path,
            executablePath: root.appendingPathComponent("xray").path,
            httpPort: underlayPort, nodeID: nodeID)
    }

    /// A second isolated Xray carries the VPN relay after the former active
    /// listener is stopped. It does not change macOS proxy settings.
    private func startUnderlay(_ node: HarborProxyNode) async throws {
        guard let port = HarborNodeLatencyTester.reservePortPair() else {
            throw HarborProxyError.invalid("底座代理本地端口不可用")
        }
        let file = root.appendingPathComponent("underlay-\(UUID().uuidString).json")
        var process: Process?
        do {
            let config = try HarborXrayConfig.make(
                node: node, httpPort: port, ruleMode: false, routeAllViaProxy: true)
            try config.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            let engine = Process()
            engine.executableURL = root.appendingPathComponent("xray")
            engine.currentDirectoryURL = root
            engine.arguments = ["run", "-config", file.path]
            engine.standardOutput = FileHandle.nullDevice
            engine.standardError = FileHandle.nullDevice
            try engine.run()
            process = engine
            var ready = false
            for _ in 0..<25 where engine.isRunning {
                if portListening(port) && portListening(port + 1) { ready = true; break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard ready else { throw HarborProxyError.invalid("底座代理无法启动，请先检查普通节点") }
            underlayChild = engine
            underlayConfigPath = file
            underlayPort = port
        } catch {
            if let process, process.isRunning { process.terminate(); process.waitUntilExit() }
            try? FileManager.default.removeItem(at: file)
            HarborNodeLatencyTester.releasePortPair(port)
            throw error
        }
    }

    /// Minimal, bounded, append-only, permission-restricted switch journal.
    /// Node IDs are hashed, never record IP, hostname, SNI, credentials or URLs.
    private func proxyAudit(_ event: String, nodeID: String? = nil, note: String = "") {
        let marker = nodeID.map { id in
            SHA256.hash(data: Data(id.utf8)).prefix(6).map { String(format: "%02x", $0) }.joined()
        } ?? "none"
        let destination = root.appendingPathComponent("proxy-switch-diagnostics.log")
        let fd = destination.path.withCString {
            Darwin.open($0, O_WRONLY | O_CREAT | O_APPEND, mode_t(0o600))
        }
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        _ = Darwin.fchmod(fd, mode_t(0o600))
        let time = ISO8601DateFormatter().string(from: .now)
        let line = "\(time) event=\(event) node=\(marker) pid=\(child?.processIdentifier ?? adoptedPID ?? 0) port=\(localPort ?? 0) \(note)\n"
        let bytes = Array(line.utf8)
        bytes.withUnsafeBytes { ptr in
            if let base = ptr.baseAddress { _ = Darwin.write(fd, base, ptr.count) }
        }
        if (try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.intValue ?? 0 > 128 * 1024 {
            // No unbounded growth; resume with a fresh audit on the next event.
            _ = Darwin.ftruncate(fd, 0)
        }
    }
    var coreInstalled: Bool {
        let files = ["xray", "geoip.dat", "geosite.dat"]
        return files.allSatisfy {
            let path = root.appendingPathComponent($0).path
            return $0 == "xray"
                ? FileManager.default.isExecutableFile(atPath: path)
                : FileManager.default.fileExists(atPath: path)
        }
    }
    var mihomoInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("mihomo").path)
    }

    func supportsCore(for node: HarborProxyNode) -> Bool {
        node.protocolName == "openvpn" ? mihomoInstalled : coreInstalled
    }

    /// Restores the packaged runtime without downloading or changing system proxy.
    func installBundledXray() async {
        guard !busy, !latencyTesting, !installingCore, !running, child == nil,
              !HarborSystemProxy.hasBackup,
              !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
            detail = "当前代理运行中或存在待恢复配置，请先安全清理代理后再安装 Xray"
            return
        }
        busy = true
        installingCore = true
        status = "准备内置内核"
        detail = "正在从 Codex Harbor 安装包恢复 Xray、GeoIP、GeoSite"
        defer {
            busy = false
            installingCore = false
        }
        do {
            let result = try HarborXrayInstaller.installBundled(into: root)
            guard coreInstalled else { throw HarborProxyError.invalid("Xray 安装后文件不完整") }
            detail = "内置 \(result.version) 已就绪，全程无需联网下载"
            status = "内核已就绪"
        } catch {
            detail = "Xray 安装失败：" + error.localizedDescription
            status = "内核待安装"
        }
    }
    /// Reconcile the persisted ownership snapshot immediately before a node
    /// operation. If another client (for example v2rayN) has replaced every
    /// Harbor listener, discard only Harbor's marker and leave that proxy
    /// untouched. If macOS still points to Harbor, preserve the listener while
    /// the core reloads so network access is never cut mid-switch.
    private func prepareSystemProxyForActivation() -> Bool? {
        guard HarborSystemProxy.hasBackup else {
            systemManaged = false
            refreshSystemProxyState()
            return false
        }
        if HarborSystemProxy.isOwned() {
            systemManaged = true
            refreshSystemProxyState()
            return true
        }
        guard !HarborSystemProxy.currentUsesManagedListener else {
            systemManaged = false
            refreshSystemProxyState()
            detail = "系统代理仍有项目指向 Harbor，请先清理代理后再切换节点"
            return nil
        }
        do {
            // restore() only removes Harbor's stale marker in this branch; it
            // does not overwrite the other client's active proxy settings.
            try HarborSystemProxy.restore(interactive: false)
            systemManaged = false
            refreshSystemProxyState()
            return false
        } catch {
            systemManaged = false
            refreshSystemProxyState()
            detail = "无法核对系统代理状态：" + error.localizedDescription
            return nil
        }
    }

    private func startSystemProxyMonitoring() {
        guard appActivationObserver == nil, wakeObserver == nil, systemProxyMonitor == nil else { return }
        let monitor = HarborSystemProxyChangeMonitor { [weak self] in
            Task { @MainActor [weak self] in self?.refreshSystemProxyState(synchronizeOwnership: true) }
        }
        monitor.start()
        systemProxyMonitor = monitor
        appActivationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshSystemProxyState(synchronizeOwnership: true)
                if let activeNode = self.activeNode {
                    self.enqueueExitGeoRefresh(for: [activeNode])
                }
                await self.retryDueFailedNodes()
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                self.refreshSystemProxyState(synchronizeOwnership: true)
                await self.reconcileXrayLiveness()
                if let activeNode = self.activeNode {
                    self.enqueueExitGeoRefresh(for: [activeNode])
                }
                await self.retryDueFailedNodes()
            }
        }
    }

    /// SystemConfiguration reads are intentionally centralized here instead
    /// of being repeated from SwiftUI computed properties during every render.
    private func refreshSystemProxyState(synchronizeOwnership: Bool = false) {
        let hasBackup = HarborSystemProxy.hasBackup
        let owned = hasBackup && HarborSystemProxy.isOwned()
        let usesManagedListener = hasBackup && HarborSystemProxy.currentUsesManagedListener
        if synchronizeOwnership {
            systemManaged = owned
        }
        requiresRecovery = HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: hasBackup,
            isRunning: running,
            isSystemManaged: systemManaged,
            ownsSystemProxy: owned,
            currentUsesManagedListener: usesManagedListener
        )
        systemProxyDescription = HarborSystemProxy.activeProxyDescription()
    }

    private init() {
        NSLog("HarborProxy lifecycle: manager init")
        let root = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/NetworkProxy", isDirectory: true)
        self.root = root
        persistence = HarborProxyPersistence(root: root)
    }

    func bootstrap() async {
        guard !bootstrapped, !bootstrapping else { return }
        NSLog("HarborProxy lifecycle: bootstrap entered")
        bootstrapping = true
        defer { bootstrapping = false }
        if !configurationLoaded {
            do {
                let state = try await persistence.load()
                store = state
                nodes = state.nodes
                nodeServerLocations = state.nodeServerLocations ?? [:]
                nodeNetworkEvidence = state.nodeNetworkEvidence ?? [:]
                nodeServerResolvedAt = state.nodeServerResolvedAt ?? [:]
                nodeExitLocations = state.nodeExitLocations ?? [:]
                probeResults = state.probeResults ?? [:]
                subscriptions = state.subscriptions
                selectedID = state.selectedID
                vpnGateUnderlayNodeID = state.vpnGateUnderlayNodeID
                routingRules = state.routingRules
                autoManageSystemProxy = state.autoManageSystemProxy ?? true
                configuredHTTPPort = (try? HarborProxyPortPolicy.validate(
                    httpPort: state.httpListenPort ?? HarborProxyPortPolicy.defaultHTTPPort
                )) ?? HarborProxyPortPolicy.defaultHTTPPort
                forcedProxyDomains = (try? HarborProxyDomainRules.normalized(
                    state.forcedProxyDomains ?? HarborProxyDomainRules.defaults
                )) ?? HarborProxyDomainRules.defaults
                configurationLoaded = true
                var namesChanged = false
                for subscription in subscriptions {
                    namesChanged = refreshAutomaticNames(for: subscription.id) || namesChanged
                }
                if namesChanged { persist() }
            } catch {
                detail = "代理配置载入失败：" + error.localizedDescription
                configurationLoaded = true
                return
            }
        }
        startSystemProxyMonitoring()
        refreshSystemProxyState(synchronizeOwnership: true)
        startupTrace("bootstrap-entered")
        if !coreInstalled {
            do {
                let result = try HarborXrayInstaller.installBundled(into: root)
                detail = "已从安装包准备 \(result.version)"
            } catch {
                detail = "内置 Xray 准备失败：" + error.localizedDescription
            }
        }
        if !mihomoInstalled {
            do { try HarborMihomoInstaller.installBundled(into: root) }
            catch { detail = "内置 Mihomo 准备失败：" + error.localizedDescription }
        }
        // Prefer adopting an unchanged Harbor-owned proxy from the previous
        // session. Recovery does not need macOS authorization and leaves the
        // fixed listener ports intact while Xray is safely re-started.
        if HarborSystemProxy.hasBackup {
            NSLog("HarborProxy lifecycle: backup exists, checking macOS ownership")
            // Network service selection may lag the app launch. Recheck before
            // deciding that the original proxy snapshot is no longer owned.
            var ownedPort = HarborSystemProxy.ownedHTTPPort
            if ownedPort == nil {
                for _ in 0..<3 where ownedPort == nil {
                    try? await Task.sleep(for: .milliseconds(250))
                    ownedPort = HarborSystemProxy.ownedHTTPPort
                }
            }
            if let ownedPort,
               (try? HarborProxyPortPolicy.validate(httpPort: ownedPort)) != nil {
                configuredHTTPPort = ownedPort
                systemManaged = true
                autoManageSystemProxy = true
                persist()
                detail = "正在恢复上次使用的代理节点和系统代理"
            } else {
                do {
                    try HarborSystemProxy.restore(interactive: false)
                    systemManaged = false
                    refreshSystemProxyState()
                    detail = "上次退出的系统代理已恢复"
                } catch {
                    refreshSystemProxyState()
                    detail = "系统代理无法自动恢复（不会弹出授权）：" + error.localizedDescription
                    startupTrace("postponed-proxy-recovery")
                    NSLog("HarborProxy bootstrap postponed: system proxy restore unavailable")
                    return
                }
            }
        }
        startupTrace("trying-adoption")
        NSLog("HarborProxy lifecycle: checking existing Xray")
        if adoptExistingXray() {
            refreshSystemProxyState()
            startupTrace("adopted-existing-xray")
            bootstrapped = true
            scheduleGeoIPRefresh()
            if let activeNode { enqueueExitGeoRefresh(for: [activeNode]) }
            scheduleLegacyRealPingRetest()
            Task { [weak self] in await self?.retryDueFailedNodes() }
            return
        }
        await cleanupOrphan()
        startupTrace("after-orphan-cleanup")
        guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
            detail = "旧 Xray 未清理，稍后可重试恢复代理"
            startupTrace("postponed-xray-cleanup")
            NSLog("HarborProxy bootstrap postponed: previous Xray still recorded")
            return
        }
        bootstrapped = true
        startupTrace("starting-selected-node")
        NSLog("HarborProxy lifecycle: cleanup complete, resuming selected node")
        // Restore the user's last active node *and* prior system-proxy intent.
        // Automatic system changes are always noninteractive and never take
        // over a proxy managed by another app.
        if let lastID = selectedNode?.id, coreInstalled {
            await queueActivation(lastID, restart: false, userInitiated: false)
        }
        scheduleGeoIPRefresh()
        scheduleLegacyRealPingRetest()
        Task { [weak self] in await self?.retryDueFailedNodes() }
    }

    /// Legacy OpenVPN failures lacked a record of whether the relay was
    /// tested directly or through a working underlay. Clear those verdicts
    /// once on upgrade; do not launch an unrequested network sweep.
    private func scheduleLegacyRealPingRetest() {
        guard store.realPingMethodVersion != 4 else { return }
        for node in nodes where !node.subscriptionID.isEmpty {
            if store.realPingMethodVersion == 3 {
                guard node.protocolName == "openvpn",
                      probeResults[node.id]?.succeeded != true else { continue }
            } else if store.realPingMethodVersion == 2 && node.protocolName != "openvpn" {
                continue
            }
            guard let previous = probeResults[node.id] else { continue }
            probeResults[node.id] = HarborProxyProbeResult(
                milliseconds: nil, checkedAt: previous.checkedAt, realTested: false
            )
        }
        store.realPingMethodVersion = 4
        persist()
    }

    /// Prefer the last exit IP observed through this exact node's isolated
    /// SOCKS outbound. Stale data remains visible while it refreshes in the
    /// background; changed endpoints and server IPs invalidate it immediately.
    func exitLocation(for node: HarborProxyNode) -> HarborProxyIPLocation? {
        nodeExitLocations[node.id]?.verifiedLocation(
            for: node, resolvedServerIP: nodeServerLocations[node.host.lowercased()]?.ip
        )
    }

    func serverLocation(for node: HarborProxyNode) -> HarborProxyIPLocation? {
        exitLocation(for: node) ?? nodeServerLocations[node.host.lowercased()]
    }

    func networkEvidence(for node: HarborProxyNode) -> HarborProxyNetworkEvidence? {
        guard node.protocolName == "openvpn" else { return nil }
        return nodeNetworkEvidence[node.host]
    }

    /// Resolve DNS once at startup and whenever subscription contents change.
    /// Only a new resolved IP triggers an HTTPS GeoIP lookup. Results are
    /// stored with the already-encrypted proxy state, and there is no timer.
    private func scheduleGeoIPRefresh() {
        geoRefreshTask?.cancel()
        guard configurationLoaded else { return }
        // VPN Gate already supplies an origin country. Its large, short-lived
        // IP list should not consume the separate GeoIP provider's quota.
        let hosts = Array(Set(nodes.filter { $0.protocolName != "openvpn" }
            .map { $0.host.lowercased() }.filter { !$0.isEmpty })).sorted()
        geoRefreshTask = Task(priority: .utility) { [weak self] in
            // Multiple subscription aliases can resolve to one IP. Never
            // repeat an unsuccessful provider lookup within the same refresh.
            var failedIPs = Set<String>()
            var resolvedTimestampChanged = false
            for host in hosts {
                guard !Task.isCancelled, let self else { return }
                if let checked = self.nodeServerResolvedAt[host],
                   Date().timeIntervalSince(checked) < HarborProxyGeoIPPolicy.serverDNSCacheInterval {
                    continue
                }
                guard let resolvedIP = await HarborNodeGeoIPResolver.resolvedIP(for: host),
                      !Task.isCancelled else { continue }
                self.nodeServerResolvedAt[host] = .now
                resolvedTimestampChanged = true
                if let existing = self.nodeServerLocations[host],
                   existing.matches(resolvedIP), existing.countryIsFresh() { continue }
                // A changed IP makes the old country invalid even if the
                // geolocation service is temporarily unreachable.
                if let existing = self.nodeServerLocations[host],
                   !existing.matches(resolvedIP) {
                    self.nodeServerLocations.removeValue(forKey: host)
                    for id in Set(self.nodes.filter { $0.host.lowercased() == host }
                        .map(\.subscriptionID)).filter({ !$0.isEmpty }) {
                        self.refreshAutomaticNames(for: id)
                    }
                    self.persist()
                }
                // resolveServerIPs stores "ZZ" until a GeoIP request succeeds.
                // Reusing that placeholder here would permanently skip the
                // provider for every node sharing the same server IP.
                let reused = self.nodeServerLocations.values.first {
                    $0.matches(resolvedIP) && $0.countryIsFresh()
                }?.verifiedCountryCode
                let countryCode: String?
                if let reused {
                    countryCode = reused
                } else {
                    // One failed address must not prevent later IPv6/IPv4
                    // servers from being resolved. A failed shared IP is
                    // attempted only once per pass, without caching "ZZ".
                    if failedIPs.contains(resolvedIP) { continue }
                    countryCode = await HarborNodeGeoIPResolver.countryCode(
                        for: resolvedIP,
                        proxyPort: self.running && self.healthy ? self.localPort : nil
                    )
                    if countryCode == nil { failedIPs.insert(resolvedIP) }
                    // Respect free-provider request limits; no fan-out or timer.
                    try? await Task.sleep(for: .milliseconds(1100))
                }
                guard !Task.isCancelled,
                      self.nodes.contains(where: { $0.host.lowercased() == host }),
                      let countryCode else { continue }
                self.nodeServerLocations[host] = HarborProxyIPLocation(
                    ip: resolvedIP, countryCode: countryCode
                )
                for id in Set(self.nodes.filter { $0.host.lowercased() == host }
                    .map(\.subscriptionID)).filter({ !$0.isEmpty }) {
                    self.refreshAutomaticNames(for: id)
                }
                self.persist()
            }
            if resolvedTimestampChanged { self?.persist() }
        }
    }

    private func persist() {
        guard configurationLoaded else { return }
        store.nodes = nodes
        store.nodeServerLocations = nodeServerLocations
        store.nodeNetworkEvidence = nodeNetworkEvidence
        store.nodeServerResolvedAt = nodeServerResolvedAt
        store.nodeExitLocations = nodeExitLocations
        store.probeResults = probeResults
        store.subscriptions = subscriptions
        store.selectedID = selectedID
        store.vpnGateUnderlayNodeID = vpnGateUnderlayNodeID
        store.routingRules = routingRules
        store.forcedProxyDomains = forcedProxyDomains
        store.httpListenPort = configuredHTTPPort
        store.autoManageSystemProxy = autoManageSystemProxy
        persistenceGeneration += 1
        let generation = persistenceGeneration
        let snapshot = store
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            do {
                try await persistence.save(snapshot, generation: generation)
            } catch {
                detail = error.localizedDescription
            }
        }
    }

    /// Explicit listener-port change. Never switch to a free fallback port.
    /// When macOS proxy was managed, restore it before stopping the old Xray,
    /// then enable it only after the new listener passes the proxy health probe.
    func updateHTTPPort(_ requestedPort: Int) async throws {
        let port = try HarborProxyPortPolicy.validate(httpPort: requestedPort)
        guard !busy, !latencyTesting, !installingCore, !requiresRecovery else {
            throw HarborProxyError.invalid("当前有其他代理操作或系统代理待恢复，请完成后再更改端口")
        }
        guard port != configuredHTTPPort else { return }
        guard !portListening(port), !portListening(port + 1) else {
            throw HarborProxyError.invalid("端口 \(port) 或 \(port + 1) 已被占用，请选择其他端口；原有连接不会中断")
        }

        let previous = configuredHTTPPort
        let wasRunning = running
        let wasManaged = systemManaged
        if wasRunning {
            guard await stop() else {
                throw HarborProxyError.invalid("原系统代理恢复失败，已取消端口修改：" + detail)
            }
        }
        configuredHTTPPort = port
        persist()
        guard wasRunning else {
            detail = "监听端口已设为 HTTP \(port) / SOCKS5 \(port + 1)，下次连接生效"
            return
        }

        await start(waitForHealth: true)
        if running && healthy && wasManaged { enableSystemProxy() }
        if running && healthy && (!wasManaged || systemManaged) {
            detail = "端口切换成功：HTTP \(port) / SOCKS5 \(port + 1)"
            return
        }

        let reason = detail
        if running {
            guard await stop() else {
                throw HarborProxyError.invalid("新端口未能接管系统代理且清理失败，请先安全清理代理：" + detail)
            }
        }
        configuredHTTPPort = previous
        persist()
        await start(waitForHealth: true)
        if running && healthy && wasManaged { enableSystemProxy() }
        throw HarborProxyError.invalid(
            "新端口切换失败（\(reason)）；已回退至 HTTP \(previous) / SOCKS5 \(previous + 1)" +
            (wasManaged && !systemManaged ? "，但系统代理未恢复，请检查网络代理设置" : "")
        )
    }

    func updateForcedProxyDomains(_ domains: [String]) throws {
        guard !busy, !latencyTesting else {
            throw HarborProxyError.invalid("代理正在执行其他操作，请稍后修改规则")
        }
        forcedProxyDomains = try HarborProxyDomainRules.normalized(domains)
        persist()
        detail = running ? "站点规则已保存；重新连接当前节点后生效" : "站点规则已保存，下次连接生效"
    }

    /// Read-only import. Copy Xray and geo assets into a Harbor-owned folder so
    /// Harbor no longer depends on the v2rayN process or app afterwards.
    func migrateV2rayN() {
        guard !busy, !running, !latencyTesting, child == nil,
              !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
            detail = "检测到正在运行或待清理的 Xray，请先关闭代理再导入"
            return
        }
        busy = true
        defer { busy = false }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN")
        do {
            let imported = try HarborV2rayNReader.read(at: source)
            guard !imported.nodes.isEmpty else { throw HarborProxyError.invalid("没有可迁移的受支持节点") }
            try installCore(from: source)
            // Subscription providers can rotate IndexId on each refresh. Replace
            // the imported subscription groups atomically instead of appending duplicates.
            let merged = HarborProxyImportMerger.merge(
                currentNodes: nodes, currentSubscriptions: subscriptions,
                selectedID: selectedID, imported: imported
            )
            nodes = merged.nodes
            subscriptions = merged.subscriptions
            scheduleGeoIPRefresh()
            selectedID = merged.selectedID
            persist()
            detail = "迁移成功：\(imported.nodes.count) 个节点、\(imported.subscriptions.count) 条订阅；\(imported.unsupportedCount) 条非支持类型未导入。原 v2rayN 配置未修改。"
        } catch { detail = "迁移失败：" + error.localizedDescription }
    }

    private func installCore(from source: URL) throws {
        // Prefer the previously downloaded official arm64 core when present,
        // rather than shipping the Intel/Rosetta binary bundled with v2rayN.
        let native = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/Proxy/xray/xray")
        let binary = nativeArm64(native) ? native : source.appendingPathComponent("bin/xray/xray")
        let files = [
            (binary, root.appendingPathComponent("xray")),
            (source.appendingPathComponent("bin/geosite.dat"), root.appendingPathComponent("geosite.dat")),
            (source.appendingPathComponent("bin/geoip.dat"), root.appendingPathComponent("geoip.dat"))
        ]
        guard files.allSatisfy({ FileManager.default.fileExists(atPath: $0.0.path) }) else {
            throw HarborProxyError.invalid("v2rayN 缺少 Xray 内核或规则数据")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (from, to) in files {
            let tmp = root.appendingPathComponent(UUID().uuidString)
            try FileManager.default.copyItem(at: from, to: tmp)
            if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
            try FileManager.default.moveItem(at: tmp, to: to)
        }
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.appendingPathComponent("xray").path)
    }

    private func nativeArm64(_ binary: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: binary) else { return false }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 8), header.count == 8 else { return false }
        let bytes = [UInt8](header)
        // Thin little-endian Mach-O 64-bit with CPU_TYPE_ARM64.
        return bytes[0...3].elementsEqual([0xcf, 0xfa, 0xed, 0xfe])
            && bytes[4...7].elementsEqual([0x0c, 0x00, 0x00, 0x01])
    }

    func addLinks(_ value: String) {
        let items = HarborProxyLinks.parse(value)
        guard !items.isEmpty else { detail = "未找到有效节点链接"; return }
        nodes += items
        scheduleGeoIPRefresh()
        if selectedID == nil { selectedID = items[0].id }
        persist(); detail = "已导入 \(items.count) 个节点"
    }

    @discardableResult
    func addSubscription(name: String, url: String) -> Bool {
        do {
            let subscription = try HarborProxySubscription(name: name, url: url)
                .updated(name: name, url: url)
            subscriptions.append(subscription)
            persist()
            detail = "已添加订阅「\(subscription.name)」"
            return true
        } catch {
            detail = error.localizedDescription
            return false
        }
    }

    /// Rename-only saves immediately. A changed HTTPS address is fetched and
    /// validated before committing either the URL or its new node collection.
    /// On failure the previous subscription, nodes and active Xray stay intact.
    @discardableResult
    func updateSubscription(_ id: String, name: String, url: String) async -> Bool {
        guard !busy, !latencyTesting else {
            detail = "请等待当前代理操作结束后编辑订阅"
            return false
        }
        guard let index = subscriptions.firstIndex(where: { $0.id == id }) else {
            detail = "订阅已不存在"
            return false
        }
        do {
            let updated = try subscriptions[index].updated(name: name, url: url)
            guard updated.url != subscriptions[index].url else {
                subscriptions[index] = updated
                persist()
                detail = "订阅「\(updated.name)」名称已保存，节点无需更新"
                return true
            }
            guard let sourceURL = URL(string: updated.url) else {
                throw HarborProxyError.invalid("订阅地址无效")
            }
            busy = true
            detail = "正在获取新订阅并校验节点…"
            do {
                let previousIPs = Dictionary(uniqueKeysWithValues: nodes
                    .filter { $0.subscriptionID == id }
                    .compactMap { node in
                        nodeServerLocations[node.host.lowercased()].map {
                            (node.host.lowercased(), $0.ip)
                        }
                    })
                let incoming = try await downloadSubscriptionNodes(from: sourceURL, id: id)
                let update = applySubscriptionNodes(incoming, id: id)
                let currentIPs = HarborProxyCommunitySource.matching(updated.url) == .vpnGate
                    ? [:] : await resolveServerIPs(for: id)
                refreshAutomaticNames(for: id)
                let refreshed = nodes.filter { $0.subscriptionID == id }
                let changedIDs = HarborProxySubscriptionRefreshPolicy.nodesRequiringProbe(
                    previousNodeIDs: update.previousNodeIDs,
                    refreshedNodes: refreshed,
                    previousResolvedIPs: previousIPs,
                    currentResolvedIPs: currentIPs
                )
                let retryIDs = Set(refreshed.compactMap { node in
                    self.probeResults[node.id]?.shouldRetryFailure() == true ? node.id : nil
                })
                let testIDs = changedIDs.union(retryIDs)
                for nodeID in changedIDs { probeResults.removeValue(forKey: nodeID) }
                // Both values are committed only after a successful download.
                subscriptions[index] = updated
                scheduleGeoIPRefresh()
                persist()
                busy = false
                // Import and refresh never start an unrequested batch probe.
                // New or changed nodes are shown as 未测速 until the user tests.
                detail = "订阅「\(updated.name)」已保存并更新 \(update.count) 个节点；待测速 \(testIDs.count) 个" +
                    (update.retainedActive
                        ? "；原连接保持运行，请手动选择新节点"
                        : "；不会自动切换当前连接")
                return true
            } catch {
                busy = false
                detail = "新链接更新失败，原链接和节点均已保留：" + error.localizedDescription
                return false
            }
        } catch {
            detail = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func renameNode(_ id: String, to rawName: String) -> Bool {
        guard let index = nodes.firstIndex(where: { $0.id == id }) else {
            detail = "节点已不存在，请刷新订阅"
            return false
        }
        do {
            nodes[index].customName = try HarborProxyNodeNaming.customName(
                rawName, sourceName: nodes[index].name
            )
            persist()
            detail = "节点已重命名为「\(nodes[index].displayName)」"
            return true
        } catch {
            detail = error.localizedDescription
            return false
        }
    }

    func restoreNodeName(_ id: String) {
        guard let index = nodes.firstIndex(where: { $0.id == id }),
              nodes[index].customName != nil else { return }
        nodes[index].customName = nil
        persist()
        detail = nodes[index].automaticName == nil
            ? "已恢复订阅名称「\(nodes[index].name)」"
            : "已恢复自动名称「\(nodes[index].displayName)」"
    }
    @discardableResult
    func removeSubscription(_ id: String) -> Bool {
        guard !busy, !latencyTesting else {
            detail = "请等待当前操作结束后再删除订阅"
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return false }
        let matching = nodes.filter { $0.subscriptionID == id }
        if running && matching.contains(where: { $0.id == activeNodeID }) {
            detail = "正在使用此订阅节点，请先清理代理再删除订阅"
            return false
        }
        subscriptions.removeAll { $0.id == id }
        let removedIDs = Set(matching.map(\.id))
        nodes.removeAll { removedIDs.contains($0.id) }
        scheduleGeoIPRefresh()
        for nodeID in removedIDs {
            probeResults.removeValue(forKey: nodeID)
            nodeExitLocations.removeValue(forKey: nodeID)
            exitGeoFailureCounts.removeValue(forKey: nodeID)
            exitGeoAttemptedAt.removeValue(forKey: nodeID)
            exitGeoPendingIDs.remove(nodeID)
        }
        subscriptionUpdatedAt.removeValue(forKey: id)
        if let selectedID, removedIDs.contains(selectedID) {
            self.selectedID = nodes.first?.id
        }
        persist()
        detail = "已删除订阅「\(subscription.name)」及其 \(matching.count) 个节点"
        return true
    }

    func refreshSubscription(_ id: String) async {
        guard !busy, !latencyTesting,
              let subscription = subscriptions.first(where: { $0.id == id }),
              let url = URL(string: subscription.url) else { return }
        busy = true
        do {
            let previousIPs = Dictionary(uniqueKeysWithValues: nodes
                .filter { $0.subscriptionID == id }
                .compactMap { node in
                    nodeServerLocations[node.host.lowercased()].map { (node.host.lowercased(), $0.ip) }
                })
            let incoming = try await downloadSubscriptionNodes(from: url, id: id)
            let update = applySubscriptionNodes(incoming, id: id)
            let currentIPs = HarborProxyCommunitySource.matching(subscription.url) == .vpnGate
                ? [:] : await resolveServerIPs(for: id)
            refreshAutomaticNames(for: id)
            let changedIDs = HarborProxySubscriptionRefreshPolicy.nodesRequiringProbe(
                previousNodeIDs: update.previousNodeIDs,
                refreshedNodes: nodes.filter { $0.subscriptionID == id },
                previousResolvedIPs: previousIPs,
                currentResolvedIPs: currentIPs
            )
            let retryIDs = Set(nodes.compactMap { node in
                node.subscriptionID == id && probeResults[node.id]?.shouldRetryFailure() == true
                    ? node.id : nil
            })
            let testIDs = changedIDs.union(retryIDs)
            for nodeID in changedIDs { probeResults.removeValue(forKey: nodeID) }
            scheduleGeoIPRefresh()
            persist()
            busy = false
            // Don't silently test the full subscription after refresh.
            detail = "订阅更新完成：\(update.count) 个节点；待测速 \(testIDs.count) 个" +
                (update.retainedActive ? "；原连接仍在运行，请手动选择最新节点" : "")
        } catch {
            busy = false
            detail = "更新失败，已保留原节点：" + error.localizedDescription
        }
    }

    /// Refresh publisher-provided feeds on opening the proxy workspace, never
    /// switching the active node or silently testing an unlimited feed.
    func refreshCommunitySourcesIfNeeded() async {
        while bootstrapping && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard configurationLoaded, !Task.isCancelled else { return }
        // Remove only the untouched built-in feed. Renamed/user-added sources
        // and any currently active node remain under the user's control.
        for subscription in subscriptions where subscription.name == HarborProxyCommunitySource.residential.name
            && subscription.url == HarborProxyCommunitySource.residential.url {
            _ = removeSubscription(subscription.id)
        }
        for subscription in subscriptions {
            guard HarborProxyCommunitySource.matching(subscription.url) == .vpnGate else { continue }
            if let updated = subscriptionUpdatedAt[subscription.id],
               Date.now.timeIntervalSince(updated) < 6 * 60 * 60 { continue }
            guard !busy, !latencyTesting else { return }
            await refreshCommunitySubscription(subscription.id)
        }
    }

    func refreshCommunitySubscription(_ id: String) async {
        guard !busy, !latencyTesting else { return }
        guard let subscription = subscriptions.first(where: { $0.id == id }),
              let source = HarborProxyCommunitySource.matching(subscription.url) else {
            await refreshSubscription(id)
            return
        }
        let previousUpdate = subscriptionUpdatedAt[id]
        await refreshSubscription(id)
        guard (source == .residential || source == .vpnGate), !busy, !latencyTesting,
              subscriptionUpdatedAt[id] != previousUpdate else { return }
        let eligible = nodes.filter {
            $0.subscriptionID == id && supportsCore(for: $0)
        }
        let candidates = source == .vpnGate
            ? HarborVPNGateProbePolicy.select(
                nodes: eligible, evidence: nodeNetworkEvidence,
                results: probeResults, limit: 24,
                probeRouteID: vpnGateProbeRouteID)
            : Array(eligible.prefix(20))
        guard !candidates.isEmpty else { return }
        await testRealLatency(candidates.map(\.id))
        refreshExitLocations(for: candidates.compactMap { node in
            probeResults[node.id]?.milliseconds != nil ? node.id : nil
        })
    }

    /// One visible action can rebuild the public candidate pool. It never
    /// activates a node or changes macOS proxy settings.
    func rescanResidentialPool() async {
        guard !busy, !latencyTesting else { return }
        if !subscriptions.contains(where: {
            HarborProxyCommunitySource.matching($0.url) == .vpnGate
        }) {
            _ = addSubscription(name: HarborProxyCommunitySource.vpnGate.name,
                                url: HarborProxyCommunitySource.vpnGate.url)
        }
        let sources = subscriptions.filter {
            HarborProxyCommunitySource.matching($0.url) == .vpnGate
        }
        guard !sources.isEmpty else {
            detail = "暂时无法添加公开候选来源"
            return
        }
        var failedSources = 0
        for subscription in sources {
            guard !Task.isCancelled else { return }
            let previousUpdate = subscriptionUpdatedAt[subscription.id]
            await refreshCommunitySubscription(subscription.id)
            if subscriptionUpdatedAt[subscription.id] == previousUpdate { failedSources += 1 }
        }
        let gateIDs = Set(subscriptions.filter {
            HarborProxyCommunitySource.matching($0.url) == .vpnGate
        }.map(\.id))
        let gateNodes = nodes.filter { gateIDs.contains($0.subscriptionID) }
        let home = gateNodes.filter { nodeNetworkEvidence[$0.host]?.kind == .residential }
        let usableHome = home.filter { probeResults[$0.id]?.succeeded == true }.count
        detail = "筛选完成：\(home.count) 个家宽入口候选，\(usableHome) 个真实测速通过" +
            (usableHome == 0 ? "；当前没有已验证可用的家宽节点" :
                "；入口类型不保证实际出口纯净度") +
            (failedSources > 0 ? "；\(failedSources) 个来源获取失败，旧列表已保留" : "")
    }

    /// Both refresh and changed-URL edits use the same validation and parsing.
    private func downloadSubscriptionNodes(from url: URL, id: String) async throws -> [HarborProxyNode] {
        do {
            return try await downloadSubscriptionNodesOnce(from: url, id: id)
        } catch {
            guard let source = HarborProxyCommunitySource.matching(url.absoluteString),
                  source == .residential,
                  let api = URL(string: source.apiURL),
                  let backup = URL(string: url.absoluteString == source.url
                    ? source.fallbackURL : source.url) else { throw error }
            if let result = try? await downloadSubscriptionNodesOnce(from: api, id: id) {
                return result
            }
            return try await downloadSubscriptionNodesOnce(from: backup, id: id)
        }
    }

    private func downloadSubscriptionNodesOnce(from url: URL, id: String) async throws -> [HarborProxyNode] {
        var request = URLRequest(url: url)
        request.timeoutInterval = url.host == "api.github.com" ? 8 : 20
        if url.host == "api.github.com" { request.setValue("CodexHarbor", forHTTPHeaderField: "User-Agent") }
        let gateFeed = url.host == "www.vpngate.net"
        let activeProxyPort = running && healthy
            ? (gateFeed && activeNode?.protocolName == "openvpn" ? underlayPort : localPort)
            : nil
        let attempts: [Int?] = gateFeed && activeProxyPort != nil
            ? [activeProxyPort, nil] : [activeProxyPort]
        var downloaded: Data?
        var usedProxyPort: Int?
        var lastError: Error = HarborProxyError.invalid("订阅响应不是有效的 HTTP 200 文本（最大 2 MB）")
        for proxyPort in attempts {
            let config = URLSessionConfiguration.ephemeral
            if let proxyPort {
                config.connectionProxyDictionary = [
                    "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
                    "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort
                ]
            } else if gateFeed {
                config.connectionProxyDictionary = [
                    "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0
                ]
            }
            let session = URLSession(configuration: config)
            defer { session.invalidateAndCancel() }
            do {
                let (data, response) = try await session.data(for: request)
                guard (response as? HTTPURLResponse)?.statusCode == 200,
                      data.count <= 2_000_000 else { continue }
                downloaded = data
                usedProxyPort = proxyPort
                break
            } catch { lastError = error }
        }
        guard let data = downloaded else { throw lastError }
        let text = url.host == "api.github.com"
            ? HarborProxyCommunitySource.decodedAPIContents(data)
            : String(data: data, encoding: .utf8)
        guard let text else { throw HarborProxyError.invalid("订阅内容无法解码") }
        let incoming: [HarborProxyNode]
        if HarborProxyCommunitySource.matching(url.absoluteString) == .vpnGate {
            let candidates = HarborVPNGate.parse(text, subscriptionID: id)
            detail = "已获取 \(candidates.count) 个志愿候选，正在预筛入口（入口连通不代表节点可用）"
            let ranked = await HarborVPNGatePortScanner.rank(
                candidates, socksPort: usedProxyPort.map { $0 + 1 })
            detail = "正在识别家宽入口类型；只有真实测速通过才算可用"
            let evidence = await HarborVPNGateNetworkClassifier.classify(
                ranked, cached: nodeNetworkEvidence,
                proxyPort: usedProxyPort
            )
            nodeNetworkEvidence.merge(evidence) { _, latest in latest }
            incoming = ranked
        } else {
            incoming = HarborProxyLinks.parse(text).map { original -> HarborProxyNode in
                var node = original
                node.subscriptionID = id
                return node
            }
        }
        guard !incoming.isEmpty else {
            throw HarborProxyError.invalid("订阅没有可识别的节点，已拒绝清空旧列表")
        }
        return incoming
    }

    /// No Xray restart is performed. Preserve matching profile IDs, aliases
    /// and favorites; retain an active endpoint removed by the provider until
    /// the user explicitly connects to a new profile.
    private struct SubscriptionNodeUpdate {
        let count: Int
        let retainedActive: Bool
        let previousNodeIDs: Set<String>
    }

    private func applySubscriptionNodes(_ incoming: [HarborProxyNode], id: String)
        -> SubscriptionNodeUpdate {
        let previousNodeIDs = Set(nodes.filter { $0.subscriptionID == id }.map(\.id))
        let merged = HarborProxySubscriptionReconciler.replace(
            current: nodes, incoming: incoming, subscriptionID: id,
            selectedID: selectedID, keepActiveConnection: running
        )
        let validIDs = Set(merged.nodes.map(\.id))
        nodes = merged.nodes
        selectedID = merged.selectedID
        scheduleGeoIPRefresh()
        probeResults = probeResults.filter { validIDs.contains($0.key) }
        exitGeoFailureCounts = exitGeoFailureCounts.filter { validIDs.contains($0.key) }
        exitGeoAttemptedAt = exitGeoAttemptedAt.filter { validIDs.contains($0.key) }
        exitGeoPendingIDs = exitGeoPendingIDs.filter { validIDs.contains($0) }
        nodeExitLocations = nodeExitLocations.filter { id, observation in
            validIDs.contains(id) && merged.nodes.contains { node in
                node.id == id && observation.verifiedLocation(
                    for: node, resolvedServerIP: nodeServerLocations[node.host.lowercased()]?.ip
                ) != nil
            }
        }
        subscriptionUpdatedAt[id] = .now
        return SubscriptionNodeUpdate(
            count: incoming.count,
            retainedActive: merged.retainedActiveNode,
            previousNodeIDs: previousNodeIDs
        )
    }

    private func resolveServerIPs(for subscriptionID: String) async -> [String: String] {
        let hosts = Array(Set(nodes.filter { $0.subscriptionID == subscriptionID }
            .map { $0.host.lowercased() })).filter { !$0.isEmpty }
        var resolved: [String: String] = [:]
        await withTaskGroup(of: (String, String?).self) { group in
            for host in hosts {
                group.addTask { (host, await HarborNodeGeoIPResolver.resolvedIP(for: host)) }
            }
            for await (host, ip) in group {
                guard let ip else { continue }
                resolved[host] = ip
                nodeServerResolvedAt[host] = .now
                let previous = nodeServerLocations[host]
                let sameIP = previous?.matches(ip) == true
                let countryCode = (sameIP ? previous?.verifiedCountryCode : nil)
                    ?? nodeServerLocations.values.first(where: {
                        $0.matches(ip) && $0.countryIsFresh()
                    })?.verifiedCountryCode
                nodeServerLocations[host] = HarborProxyIPLocation(
                    ip: ip, countryCode: countryCode ?? "ZZ",
                    locatedAt: sameIP ? previous?.locatedAt : .now
                )
            }
        }
        return resolved
    }

    /// Explicit refresh of the selected node (also used when routing changes).
    func select(_ id: String) async {
        await queueActivation(id, restart: true, userInitiated: true)
    }

    /// All rows are selectable, including while a previous node is starting.
    /// The most recent click wins; no click is silently discarded due to busy.
    func activate(_ id: String) async {
        await queueActivation(id, restart: false, userInitiated: true)
    }

    private func queueActivation(_ id: String, restart: Bool, userInitiated: Bool) async {
        guard nodes.contains(where: { $0.id == id }) else {
            detail = "所选节点已不存在，请刷新订阅"
            return
        }
        pendingActivation.enqueue(id, restart: restart, userInitiated: userInitiated)
        switchingNodeID = id
        // The previous candidate may still be completing a 30-second OpenVPN
        // handshake. The latest user click should supersede that test now,
        // rather than remain visually stuck as "switching".
        activationPreflightCancellation?.cancel()
        guard !activationInProgress else { return }
        activationInProgress = true
        defer {
            activationInProgress = false
            switchingNodeID = nil
        }

        while let request = pendingActivation.takeNext() {
            // Startup, subscription refresh, and another switch can be in progress.
            // Keep the request queued instead of disabling every node button.
            while busy || installingCore {
                try? await Task.sleep(for: .milliseconds(100))
            }
            // A newer click arrived while waiting for another operation.
            // Do not start an obsolete preflight or stop the active core.
            if pendingActivation.hasPending { continue }
            await activateOne(
                request.nodeID,
                restart: request.restart,
                userInitiated: request.userInitiated
            )
        }
    }

    private func activateOne(_ id: String, restart: Bool, userInitiated: Bool) async {
        guard let requestedNode = nodes.first(where: { $0.id == id }) else {
            detail = "所选节点已不存在"
            return
        }
        let underlayID = requestedNode.protocolName == "openvpn" && healthy
            ? (activeNode?.protocolName == "openvpn"
                ? (underlayPort == nil ? nil : vpnGateUnderlayNodeID)
                : activeNodeID) : nil
        let previousUnderlayID = activeNode?.protocolName == "openvpn" && underlayPort != nil
            ? vpnGateUnderlayNodeID : nil
        guard let preserveSystemProxy = prepareSystemProxyForActivation() else { return }
        let previousID = activeNodeID ?? selectedID
        let wasRunning = running
        let wasManaged = preserveSystemProxy

        autoManageSystemProxy = HarborProxyConnectionIntent.shouldManageSystemProxy(
            persistedPreference: autoManageSystemProxy,
            userInitiated: userInitiated
        )

        // The requested profile is only committed after its Xray listeners
        // and actual outbound identity have been verified.
        proxyAudit("switch_requested", nodeID: id, note: "running=\(wasRunning)")

        if wasRunning && previousID == id && !restart {
            if checkingConnectivity {
                detail = "当前节点已启动，正在完成网络检测"
                return
            }
            if healthy {
                if !systemManaged && autoManageSystemProxy {
                    enableSystemProxy(interactive: userInitiated)
                }
                return
            }
        }

        if requestedNode.protocolName == "openvpn", !mihomoInstalled {
            detail = "Mihomo 内核未安装，原连接保持不变"
            return
        }

        guard !pendingActivation.hasPending else { return }
        if latencyTesting { cancelLatencyTests() }
        if wasRunning {
            // Keep the macOS proxy settings and ownership snapshot untouched:
            // Xray's fixed ports do not change when only the remote node changes.
            guard await stopCore() else {
                proxyAudit("old_stop_failed", nodeID: id)
                detail = "旧代理内核仍未退出，请稍候重试：" + detail
                return
            }
            proxyAudit("old_stopped", nodeID: previousID)
        }

        await start(
            nodeID: id,
            underlayNodeID: underlayID,
            preservingSystemProxy: wasManaged,
            systemProxyInteractive: userInitiated
        )
        if !running {
            let failure = detail
            // Restore the previous active node if the replacement fails.
            proxyAudit("switch_failed", nodeID: id)
            if wasRunning, let previousID, previousID != id,
               nodes.contains(where: { $0.id == previousID }) {
                await start(
                    underlayNodeID: previousUnderlayID,
                    preservingSystemProxy: wasManaged,
                    systemProxyInteractive: false
                )
                if running {
                    proxyAudit("rollback_restored", nodeID: previousID)
                    detail = "新节点连接失败：\(failure)；已恢复原连接"
                } else {
                    proxyAudit("rollback_failed", nodeID: previousID)
                    detail = "新节点连接失败：\(failure)；原连接恢复失败：" + detail
                }
            }
            return
        }

        proxyAudit("switch_listener_committed", nodeID: id)
        if wasManaged {
            // The unchanged system proxy already targets our fixed listener.
            systemManaged = HarborSystemProxy.isOwned()
            if !systemManaged {
                detail = "Xray 已切换，但系统代理被其他程序更改；未覆盖其配置"
            } else {
                detail = "已切换节点 · 系统代理端口保持不变"
            }
            refreshSystemProxyState()
        }
        // For a previously unmanaged connection the asynchronous health check
        // will take over the system proxy only after a verified outbound success.
    }

    /// The visible 'clear proxy' action never silently deletes another
    /// application's system settings or node/subscription configurations.
    func clearProxy(interactive: Bool = false) async {
        if running || HarborSystemProxy.hasBackup {
            if await stop(interactive: interactive) {
                autoManageSystemProxy = false
                persist()
            }
        } else {
            autoManageSystemProxy = false
            persist()
            detail = "Harbor 当前没有启用代理；其他程序的系统代理设置未修改"
        }
    }

    func remove(_ id: String) {
        guard id != selectedID || !running else { detail = "请先切换或关闭当前节点"; return }
        nodes.removeAll { $0.id == id }
        if selectedID == id { selectedID = nodes.first?.id }
        persist()
    }

    func start(
        nodeID: String? = nil,
        underlayNodeID: String? = nil,
        preservingSystemProxy: Bool = false,
        waitForHealth: Bool = false,
        systemProxyInteractive: Bool = false
    ) async {
        guard !busy, !running else { return }
        // A former Xray can still be alive if its health state was lost.
        // Do not overwrite our process handle and leave an orphan listening.
        if child != nil || underlayChild != nil {
            guard await stopCore() else { return }
        }
        if FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
            await cleanupOrphan()
            guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                detail = "发现上次未清理的 Xray 进程，已阻止重复启动"
                return
            }
        }
        guard let recoveredOwnership = prepareSystemProxyForActivation() else { return }
        let keepSystemProxy = preservingSystemProxy || recoveredOwnership
        guard !HarborSystemProxy.hasBackup ||
                (keepSystemProxy && HarborSystemProxy.isOwned()) else {
            detail = "系统代理状态尚未安全恢复"
            return
        }
        guard let node = nodes.first(where: { $0.id == (nodeID ?? selectedID) }) else {
            detail = "先导入并选择节点"
            return
        }
        guard supportsCore(for: node) else {
            detail = node.protocolName == "openvpn"
                ? "请从安装包恢复内置 Mihomo 内核" : "请从安装包恢复内置 Xray 内核"
            return
        }
        busy = true; defer { busy = false }
        status = "正在连接"; detail = ""
        do {
            let port = try choosePort()
            let isOpenVPN = node.protocolName == "openvpn"
            if isOpenVPN, let underlayNodeID {
                guard coreInstalled,
                      let base = nodes.first(where: {
                          $0.id == underlayNodeID && $0.protocolName != "openvpn"
                      }) else {
                    throw HarborProxyError.invalid("住宅节点的底座订阅节点已不存在")
                }
                try await startUnderlay(base)
            }
            let config = try isOpenVPN
                ? HarborMihomoConfig.make(node: node, httpPort: port,
                                          underlaySocksPort: underlayPort.map { $0 + 1 })
                : HarborXrayConfig.make(node: node, httpPort: port, ruleMode: routingRules,
                                       forcedProxyDomains: forcedProxyDomains,
                                       routeVerificationViaProxy: true,
                                       verificationHost: HarborNodeLatencyTester.realPingURL().host)
            let file = root.appendingPathComponent("runtime-\(UUID().uuidString).json")
            try config.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            configPath = file
            let process = Process()
            process.executableURL = root.appendingPathComponent(isOpenVPN ? "mihomo" : "xray")
            process.currentDirectoryURL = root
            process.arguments = isOpenVPN ? ["-f", file.path] : ["run", "-config", file.path]
            process.standardOutput = FileHandle.nullDevice
            // A private O_APPEND file survives host-app restarts without a pipe
            // SIGPIPE. The low-frequency liveness monitor bounds its size.
            let errorFD = runtimeErrorLogURL.path.withCString {
                Darwin.open($0, O_WRONLY | O_CREAT | O_TRUNC | O_APPEND, mode_t(0o600))
            }
            if errorFD >= 0 {
                _ = Darwin.fchmod(errorFD, mode_t(0o600))
                process.standardError = FileHandle(fileDescriptor: errorFD, closeOnDealloc: true)
            } else {
                process.standardError = FileHandle.nullDevice
            }
            process.terminationHandler = { [weak self] finished in
                let pid = finished.processIdentifier
                Task { @MainActor [weak self] in
                    await self?.handleUnexpectedXrayExit(pid: pid)
                }
            }
            try process.run()
            child = process; localPort = port
            let record = HarborProxyProcessRecord(
                pid: process.processIdentifier, configPath: file.path,
                executablePath: process.executableURL?.path ?? "",
                underlay: underlayRecord(nodeID: underlayNodeID)
            )
            try JSONEncoder().encode(record).write(to: runtimeRecordURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: runtimeRecordURL.path)
            var ready = false
            for _ in 0..<25 {
                guard process.isRunning else { break }
                if portListening(port) && portListening(port + 1) { ready = true; break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            // Opening the two local listeners is the startup condition.
            // External HTTPS probes can take 4s × 3 on a slow/blocked node;
            // they must not hold up the UI or serialize every node switch.
            guard HarborProxyStartupPolicy.canPublishListenerReady(
                xrayRunning: process.isRunning, portsListening: ready
            ) else {
                _ = await stopCore()
                throw HarborProxyError.invalid("代理内核未能监听本地 HTTP/SOCKS5 端口，请检查端口或节点配置")
            }
            guard runningConfigMatches(node.id, path: file) else {
                proxyAudit("runtime_config_mismatch", nodeID: node.id)
                _ = await stopCore()
                throw HarborProxyError.invalid("运行配置与目标节点不一致，未将切换标记为成功")
            }
            // Commit UI identity only after the listener belongs to the new
            // process and its complete outbound configuration matches the node.
            activeNodeID = node.id
            selectedID = node.id
            if isOpenVPN { vpnGateUnderlayNodeID = underlayPort == nil ? nil : underlayNodeID }
            persist()
            running = true
            proxyAudit("listener_ready", nodeID: node.id)
            startLivenessMonitoring()
            healthy = false
            checkingConnectivity = true
            status = "已启动 · 正在检测网络"
            detail = "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
            connectionGeneration &+= 1
            let generation = connectionGeneration
            if waitForHealth {
                // Explicit port migration still requires complete verification
                // before we consider the macOS system proxy switch committed.
                await finishHealthCheck(
                    port: port,
                    generation: generation,
                    systemProxyInteractive: systemProxyInteractive
                )
            } else {
                healthTask?.cancel()
                healthTask = Task { [weak self] in
                    guard let self else { return }
                    await self.finishHealthCheck(
                        port: port,
                        generation: generation,
                        systemProxyInteractive: systemProxyInteractive
                    )
                }
            }
        } catch {
            _ = await stopCore()
            status = "连接失败"
            detail = error.localizedDescription
        }
    }

    /// Same readiness criterion as v2rayN real ping: the running node's SOCKS
    /// inbound successfully requests the configured SpeedPingTestUrl twice.
    /// Do not reject a working node for unrelated Google/Cloudflare failures.
    private func finishHealthCheck(
        port: Int,
        generation: UInt64,
        systemProxyInteractive: Bool
    ) async {
        let reachable = activeNode?.protocolName == "openvpn"
            ? await HarborMihomoLatencyTester.checkActiveSOCKS(
                port: port + 1, failureLog: runtimeErrorLogURL)
            : await HarborNodeLatencyTester.checkActiveSOCKS(port: port + 1)
        lastActiveHealthCheckAt = .now
        guard generation == connectionGeneration,
              running, localPort == port else { return }
        guard coreProcessAlive else {
            _ = await stopCore()
            status = "代理内核已退出"
            detail = "本地监听进程意外退出，请重新连接或检查节点配置"
            return
        }
        guard let activeNodeID, runningConfigMatches(activeNodeID, path: configPath) else {
            checkingConnectivity = false
            healthy = false
            proxyAudit("health_identity_mismatch", nodeID: activeNodeID)
            status = "运行配置与选中节点不一致"
            detail = "Xray 已启动，但无法核对实际运行节点；请重新选择节点"
            return
        }
        checkingConnectivity = false
        healthy = reachable
        proxyAudit(reachable ? "health_success" : "health_failed",
                   nodeID: activeNodeID, note: "method=v2rayn_realping_socks")
        if reachable {
            status = "已连接"
            detail = "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
            if let activeNode { enqueueExitGeoRefresh(for: [activeNode]) }
            if autoManageSystemProxy && !systemManaged {
                enableSystemProxy(interactive: systemProxyInteractive)
            }
        } else {
            // Inbound identity and node selection remain committed; a probe
            // failure does not mean the Xray outbound changed to another node.
            status = "节点已切换 · 真实测速未通过"
            detail = "当前 SOCKS5 节点对 v2rayN 配置测速地址的请求未通过；运行节点未被回退"
        }
    }

    /// Check website compatibility through the currently active outbound.
    /// Deliberately separate from the basic 204 health check: a blocked
    /// website is not equivalent to an unusable tunnel.
    func checkActiveWebsites() async {
        guard running, healthy, !checkingConnectivity, !websiteChecking,
              !busy, let port = localPort else {
            detail = "请先连接并验证当前代理，再测试网站"
            return
        }
        websiteChecking = true
        defer { websiteChecking = false }
        let generation = connectionGeneration
        let activeID = activeNodeID
        let report = await HarborMihomoLatencyTester.websiteReport(socksPort: port + 1)
        guard running, healthy, generation == connectionGeneration,
              activeID == activeNodeID else { return }
        detail = "当前节点网站检测：" + report
    }

    func verify() async {
        guard running, let port = localPort, !busy else { return }
        busy = true; defer { busy = false }
        let reachable = activeNode?.protocolName == "openvpn"
            ? await HarborMihomoLatencyTester.checkActiveSOCKS(port: port + 1)
            : await HarborNodeLatencyTester.checkActiveSOCKS(port: port + 1)
        healthy = reachable && activeNodeID != nil && runningConfigMatches(activeNodeID!, path: configPath)
        proxyAudit(healthy ? "manual_verify_success" : "manual_verify_failed",
                   nodeID: activeNodeID, note: "method=v2rayn_realping_socks")
        status = healthy ? "已连接" : "节点已切换 · 真实测速未通过"
        detail = healthy
            ? "当前节点通过 v2rayN 真实测速地址验证"
            : "内核已启动，当前节点对 v2rayN 真实测速地址的请求未通过"
    }

    func testRealLatency(_ ids: [String]) async {
        let requested = Set(ids)
        let requestedNodes = nodes.filter { requested.contains($0.id) }
        let subscriptionIDs = Set(requestedNodes.map(\.subscriptionID).filter { !$0.isEmpty })
        let finalization: SubscriptionProbeFinalization?
        if subscriptionIDs.count == 1, let subscriptionID = subscriptionIDs.first {
            let group = nodes.filter { $0.subscriptionID == subscriptionID }
            let isFirstCompleteTest = Set(group.map(\.id)) == requested
                && group.allSatisfy { proxyResultIsUntested($0.id) }
            finalization = isFirstCompleteTest
                ? .init(subscriptionID: subscriptionID,
                        newNodeIDs: requested, initialImport: true)
                : nil
        } else {
            finalization = nil
        }
        await testLatency(ids, finalization: finalization)
    }

    private func proxyResultIsUntested(_ id: String) -> Bool {
        probeResults[id]?.realTested != true
    }

    /// Failed results expire quickly and are retried when the app becomes
    /// active or wakes. Successful nodes are never swept on a timer.
    private func retryDueFailedNodes() async {
        guard bootstrapped, !busy, !latencyTesting, coreInstalled else { return }
        // Retest only the currently active node. Waking the laptop or
        // foregrounding the app must not launch a full failed-subscription sweep.
        guard let id = activeNodeID,
              probeResults[id]?.shouldRetryFailure() == true else { return }
        await testRealLatency([id])
    }

    /// Retained for existing callers: latency without an explicit kind means
    /// the stronger end-to-end HTTPS measurement.
    func testLatency(_ ids: [String]) async {
        await testRealLatency(ids)
    }

    private struct SubscriptionProbeFinalization {
        let subscriptionID: String
        let newNodeIDs: Set<String>
        let initialImport: Bool
    }

    private func testLatency(
        _ ids: [String],
        finalization: SubscriptionProbeFinalization? = nil
    ) async {
        guard !latencyTesting, !busy else {
            return
        }
        let uniqueIDs = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
        let targets = uniqueIDs.compactMap { id in nodes.first(where: { $0.id == id }) }
        guard !targets.isEmpty else { return }
        guard targets.allSatisfy({ supportsCore(for: $0) }) else {
            detail = "所选节点的代理内核未安装，暂时无法进行真实测速"
            return
        }
        let containsOpenVPN = targets.contains { $0.protocolName == "openvpn" }
        // Probe the relay over the same healthy base route that will carry it
        // when selected. Without a base, keep the direct path explicit.
        let latencyUnderlayPort = containsOpenVPN ? workingUnderlaySocksPort : nil
        let openVPNRouteID = latencyUnderlayPort == nil ? "direct" : vpnGateProbeRouteID

        latencyTesting = true
        latencyBatchIDs = Set(targets.map(\.id))
        latencyCancellationRequested = false
        let cancellation = HarborLatencyCancellation()
        latencyCancellation = cancellation
        latencyCompleted = 0
        latencyTotal = targets.count
        var succeeded = 0
        defer {
            latencyTesting = false
            latencyBatchIDs = []
            latencyCurrentID = nil
            latencyTestingIDs = []
            latencyCancellationRequested = false
            latencyCancellation = nil
        }
        let latencyRoot = root
        let latencyRuleMode = routingRules
        let latencyForcedDomains = forcedProxyDomains
        let tcpRelays = Array(targets.filter {
            $0.protocolName == "openvpn" && $0.network == "tcp"
        }.prefix(64))
        let reachableRelays = await HarborVPNGatePortScanner.reachableIDs(
            tcpRelays, socksPort: latencyUnderlayPort, cancellation: cancellation)
        let unreachableRelays = Set(tcpRelays.map(\.id)).subtracting(reachableRelays)
        let ordinaryTargets = targets.filter { $0.protocolName != "openvpn" }
        let sharedRealBatch = ordinaryTargets.isEmpty || cancellation.isCancelled ? nil
            : await HarborNodeLatencyTester.startRealBatch(
                nodes: ordinaryTargets, root: latencyRoot, cancellation: cancellation)
        // Keep one Xray for all nodes and bound only the HTTP probes. Refill
        // each free slot immediately, so a slow node cannot block the next wave.
        // Failed nodes are retried by a later user test, not immediately here.
        let measureNode: @Sendable (HarborProxyNode) async -> (String, Int?, String?, String?) = { node in
            let report: HarborNodeDelayReport
            if node.protocolName == "openvpn" {
                report = unreachableRelays.contains(node.id)
                    ? .failed("入口 TCP 连接失败")
                    : await HarborMihomoLatencyTester.measure(
                        node: node, root: latencyRoot, cancellation: cancellation,
                        underlaySocksPort: latencyUnderlayPort)
            } else if let sharedRealBatch {
                report = await sharedRealBatch.measure(node: node)
            } else {
                report = await HarborNodeLatencyTester.measure(
                    node: node, root: latencyRoot,
                    ruleMode: latencyRuleMode,
                    forcedProxyDomains: latencyForcedDomains,
                    cancellation: cancellation
                )
            }
            return (node.id, report.milliseconds, report.failure,
                    node.protocolName == "openvpn" ? openVPNRouteID : nil)
        }
        if !latencyCancellationRequested && !Task.isCancelled {
            let openVPNConcurrency = HarborProxyLatencyPolicy.openVPNParallelCount(
                processors: ProcessInfo.processInfo.activeProcessorCount,
                physicalMemory: ProcessInfo.processInfo.physicalMemory)
            let concurrency = containsOpenVPN
                ? openVPNConcurrency : HarborProxyLatencyPolicy.parallelCount
            // Every OpenVPN task uses an isolated Mihomo with its own reserved
            // HTTP/SOCKS port pair. Refill slots as they finish; never launch
            // all volunteer relays at once or alter the active system proxy.
            var queue = HarborProxyLatencyQueue(count: targets.count, limit: concurrency)
            await withTaskGroup(of: (String, Int?, String?, String?).self) { group in
                for index in queue.initialIndices() {
                    let node = targets[index]
                    latencyTestingIDs.insert(node.id)
                    group.addTask { await measureNode(node) }
                }
                latencyCurrentID = targets.first?.id
                while let (id, result, failure, routeID) = await group.next() {
                    guard !latencyCancellationRequested, !Task.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    let previous = probeResults[id]
                    let checkedAt = Date.now
                    // A relay failing over direct TCP must start at zero when
                    // first tried through a healthy VLESS/other underlay.
                    let priorFailures = previous?.probeRouteID == routeID
                        ? (previous?.consecutiveRealFailures ?? 0) : 0
                    let failures = result == nil ? priorFailures + 1 : 0
                    probeResults[id] = HarborProxyProbeResult(
                        milliseconds: result,
                        checkedAt: checkedAt,
                        realTested: true,
                        realFailureReason: failure,
                        realCheckedAt: checkedAt,
                        consecutiveRealFailures: failures,
                        probeRouteID: routeID
                    )
                    let errorCategory = result == nil ? "failed" : "success"
                    // Fixed categories only: no raw Xray stderr, address or secrets.
                    let category: String
                    switch failure {
                    case nil: category = "ok"
                    case let reason? where reason.contains("超时"): category = "timeout"
                    case let reason? where reason.contains("TLS"): category = "tls"
                    case let reason? where reason.contains("DNS"): category = "dns"
                    case let reason? where reason.contains("连接"): category = "connect"
                    case let reason? where reason.contains("监听"): category = "listener"
                    default: category = "other"
                    }
                    proxyAudit("real_probe_\(errorCategory)", nodeID: id,
                               note: "reason=\(category)")
                    if result != nil { succeeded += 1 }
                    latencyTestingIDs.remove(id)
                    latencyCompleted += 1
                    if let index = queue.nextIndex() {
                        let node = targets[index]
                        latencyTestingIDs.insert(node.id)
                        latencyCurrentID = node.id
                        group.addTask { await measureNode(node) }
                    }
                }
            }
        }
        if let sharedRealBatch {
            await Task.detached(priority: .utility) { sharedRealBatch.close() }.value
        }
        proxyAudit("real_probe_batch_done",
                   note: "tested=\(latencyCompleted) successes=\(succeeded)")
        if !latencyCancellationRequested && !Task.isCancelled {
            if let finalization {
                finalizeSubscriptionProbes(finalization)
            }
            for id in Set(targets.map(\.subscriptionID)).filter({ !$0.isEmpty }) {
                refreshAutomaticNames(for: id)
            }
            // A speed test does not change region data. Users can request an
            // independent exit-region update from the dedicated button.
            persist()
        }
        let confirmedUnavailable = targets.filter { node in
            probeResults[node.id]?.isConfirmedUnavailable == true
        }.count
        detail = latencyCancellationRequested || Task.isCancelled
            ? "已停止测速，完成 \(latencyCompleted)/\(latencyTotal) 个节点"
            : "真实测速完成：可用 \(succeeded)，待复测 \(latencyCompleted - succeeded - confirmedUnavailable)，不可用 \(confirmedUnavailable)"
        if targets.count == 1,
           let reason = probeResults[targets[0].id]?.realFailureReason,
           !latencyCancellationRequested {
            detail += " · " + reason
        }
    }

    /// Explicit region updates do not restart the active node or run a speed
    /// test. Existing observations stay visible until a replacement succeeds.
    func refreshExitLocations(for ids: [String]) {
        guard coreInstalled, !busy, !latencyTesting, !exitGeoUpdating else { return }
        let requested = Set(ids)
        let candidates = nodes.filter { requested.contains($0.id) }
        guard !candidates.isEmpty else { return }
        exitGeoManualIDs = Set(candidates.map(\.id))
        exitGeoForcedIDs.formUnion(exitGeoManualIDs)
        exitGeoUpdating = true
        exitGeoCompleted = 0
        exitGeoTotal = candidates.count
        exitGeoManualSucceeded = 0
        detail = "正在识别普通网站的出口地区：0/\(exitGeoTotal)"
        enqueueExitGeoRefresh(for: candidates)
    }

    /// Exit discovery has its own queue and Xray process.
    private func enqueueExitGeoRefresh(for candidates: [HarborProxyNode]) {
        let now = Date.now
        for candidate in candidates {
            guard let current = nodes.first(where: { $0.id == candidate.id }),
                  current.endpointSignature == candidate.endpointSignature else { continue }
            let serverIP = nodeServerLocations[current.host.lowercased()]?.ip
            if let cached = nodeExitLocations[current.id],
               !cached.needsRefresh(for: current, resolvedServerIP: serverIP),
               !exitGeoForcedIDs.contains(current.id) { continue }
            if let attempted = exitGeoAttemptedAt[current.id],
               now.timeIntervalSince(attempted) < HarborProxyGeoIPPolicy.retryInterval(
                   afterFailures: exitGeoFailureCounts[current.id] ?? 1
               ), !exitGeoForcedIDs.contains(current.id) {
                continue
            }
            exitGeoPendingIDs.insert(current.id)
        }
        guard !exitGeoPendingIDs.isEmpty, exitGeoTask == nil, coreInstalled else { return }
        exitGeoTask = Task(priority: .utility) { [weak self] in
            await self?.runExitGeoQueue()
        }
    }

    private func runExitGeoQueue() async {
        while !Task.isCancelled, !exitGeoPendingIDs.isEmpty {
            let ids = exitGeoPendingIDs
            exitGeoPendingIDs.subtract(ids)
            let candidates = nodes.filter { ids.contains($0.id) }
            let now = Date.now
            let due = candidates.filter { node in
                let serverIP = nodeServerLocations[node.host.lowercased()]?.ip
                let needsRefresh = nodeExitLocations[node.id]?.needsRefresh(
                    for: node, resolvedServerIP: serverIP
                ) ?? true
                let retryAllowed = exitGeoAttemptedAt[node.id].map {
                    now.timeIntervalSince($0) >= HarborProxyGeoIPPolicy.retryInterval(
                        afterFailures: exitGeoFailureCounts[node.id] ?? 1
                    )
                } ?? true
                return (needsRefresh && retryAllowed) || exitGeoForcedIDs.contains(node.id)
            }
            guard !due.isEmpty else { continue }
            for node in due { exitGeoAttemptedAt[node.id] = now }
            let cancellation = HarborLatencyCancellation()
            // A lone automatic refresh can reuse the active listener. Manual
            // batches always use isolated inbounds so node switches cannot
            // attribute an exit IP to the wrong profile.
            let livePort = due.count == 1 && due[0].id == activeNodeID
                && !exitGeoManualIDs.contains(due[0].id) && running && healthy
                ? localPort.map { $0 + 1 } : nil
            let batch: HarborRealDelayBatch?
            if livePort == nil && due.contains(where: { $0.protocolName != "openvpn" }) {
                batch = await HarborNodeLatencyTester.startRealBatch(
                    nodes: due.filter { $0.protocolName != "openvpn" },
                    root: root, cancellation: cancellation
                )
            } else {
                batch = nil
            }
            let geoRoot = root
            let inspect: @Sendable (HarborProxyNode) async
                -> (HarborProxyNode, HarborProxyIPLocation?) = { node in
                if let livePort {
                    return (node, await HarborNodeGeoIPResolver.exitLocation(socksPort: livePort))
                }
                if node.protocolName == "openvpn" {
                    return (node, await HarborMihomoLatencyTester.exitLocation(
                        node: node, root: geoRoot, cancellation: cancellation))
                }
                return (node, await batch?.exitLocation(node: node))
            }
            var queue = HarborProxyLatencyQueue(
                count: due.count, limit: HarborProxyGeoIPPolicy.exitParallelCount
            )
            await withTaskGroup(of: (HarborProxyNode, HarborProxyIPLocation?).self) { group in
                for index in queue.initialIndices() {
                    let target = due[index]
                    group.addTask { await inspect(target) }
                }
                while let (target, observed) = await group.next() {
                    guard !Task.isCancelled else { group.cancelAll(); break }
                    if let index = queue.nextIndex() {
                        let next = due[index]
                        group.addTask { await inspect(next) }
                    }
                    guard let latest = nodes.first(where: { $0.id == target.id }),
                          latest.endpointSignature == target.endpointSignature,
                          livePort == nil || activeNodeID == target.id else { continue }
                    let manuallyRequested = exitGeoManualIDs.remove(target.id) != nil
                    exitGeoForcedIDs.remove(target.id)
                    if manuallyRequested {
                        exitGeoCompleted += 1
                        detail = "正在识别普通网站的出口地区：\(exitGeoCompleted)/\(exitGeoTotal)"
                    }
                    guard let observed else {
                        exitGeoFailureCounts[target.id, default: 0] += 1
                        continue
                    }
                    if manuallyRequested { exitGeoManualSucceeded += 1 }
                    exitGeoFailureCounts.removeValue(forKey: target.id)
                    exitGeoAttemptedAt.removeValue(forKey: target.id)
                    nodeExitLocations[target.id] = HarborProxyExitLocation(
                        location: observed, endpointSignature: target.endpointSignature,
                        resolvedServerIP: nodeServerLocations[latest.host.lowercased()]?.ip
                    )
                    if !latest.subscriptionID.isEmpty {
                        refreshAutomaticNames(for: latest.subscriptionID)
                    }
                    persist()
                }
            }
            if Task.isCancelled { cancellation.cancel() }
            if let batch {
                await Task.detached(priority: .utility) { batch.close() }.value
            }
        }
        exitGeoTask = nil
        if exitGeoUpdating {
            detail = "出口地区识别完成：确认 \(exitGeoManualSucceeded)/\(exitGeoTotal) 个；未确认的节点仍显示入口"
            exitGeoUpdating = false
            exitGeoManualIDs.removeAll()
            exitGeoForcedIDs.removeAll()
        }
        scheduleExitGeoRetry()
    }

    /// One sleeping task at most; retries only the currently connected exit,
    /// with 10s/1m/10m/1h backoff, not every node on a periodic sweep.
    private func scheduleExitGeoRetry() {
        exitGeoRetryTask?.cancel()
        exitGeoRetryTask = nil
        guard running, healthy, let activeNodeID,
              let count = exitGeoFailureCounts[activeNodeID], count <= 4,
              let attempted = exitGeoAttemptedAt[activeNodeID] else { return }
        let due = attempted.addingTimeInterval(
            HarborProxyGeoIPPolicy.retryInterval(afterFailures: count))
        let milliseconds = Int(max(0, due.timeIntervalSinceNow) * 1_000)
        exitGeoRetryTask = Task(priority: .utility) { [weak self] in
            do { try await Task.sleep(for: .milliseconds(milliseconds)) }
            catch { return }
            guard let self, !Task.isCancelled else { return }
            self.exitGeoRetryTask = nil
            if let activeNode = self.activeNode {
                self.enqueueExitGeoRefresh(for: [activeNode])
            }
        }
    }

    private func finalizeSubscriptionProbes(_ finalization: SubscriptionProbeFinalization) {
        var group = nodes.filter { $0.subscriptionID == finalization.subscriptionID }
        if finalization.initialImport {
            group = HarborProxySubscriptionRefreshPolicy.initialLatencyOrder(
                group, results: probeResults
            )
        } else if !finalization.newNodeIDs.isEmpty {
            let existing = group.filter { !finalization.newNodeIDs.contains($0.id) }
            let additions = HarborProxySubscriptionRefreshPolicy.initialLatencyOrder(
                group.filter { finalization.newNodeIDs.contains($0.id) }, results: probeResults
            )
            group = existing + additions
        }

        var iterator = group.makeIterator()
        nodes = nodes.map { node in
            node.subscriptionID == finalization.subscriptionID ? (iterator.next() ?? node) : node
        }
    }

    @discardableResult
    private func refreshAutomaticNames(for subscriptionID: String) -> Bool {
        let group = nodes.filter { $0.subscriptionID == subscriptionID }
        let exits = Dictionary(uniqueKeysWithValues: group.compactMap { node in
            exitLocation(for: node).map { (node.id, $0) }
        })
        let renamed = HarborProxyAutomaticName.refreshed(
            group, results: probeResults, locations: nodeServerLocations,
            exitLocationsByNodeID: exits
        )
        guard group != renamed else { return false }
        var iterator = renamed.makeIterator()
        nodes = nodes.map { node in
            node.subscriptionID == subscriptionID ? (iterator.next() ?? node) : node
        }
        return true
    }

    func cancelLatencyTests() {
        latencyCancellationRequested = true
        latencyCancellation?.cancel()
        latencyTestingIDs = []
    }

    func enableSystemProxy(interactive: Bool = false) {
        guard running, healthy, let localPort else { detail = "请先连接并验证当前节点"; return }
        if systemManaged && HarborSystemProxy.isOwned() { return }
        if interactive {
            autoManageSystemProxy = true
            persist()
        }
        do {
            try HarborSystemProxy.enable(port: localPort, forcedProxyDomains: forcedProxyDomains,
                                         interactive: interactive)
            systemManaged = true
            autoManageSystemProxy = true
            persist()
            detail = "已接管 macOS 系统代理"
        } catch {
            systemManaged = false
            detail = "本地节点已连接，但系统代理未接管：" + error.localizedDescription
        }
        refreshSystemProxyState()
    }

    func clearSystemProxy() {
        do {
            try HarborSystemProxy.restore(interactive: false)
            systemManaged = false
            autoManageSystemProxy = false
            persist()
            detail = "原系统代理设置已恢复"
        } catch { detail = error.localizedDescription }
        refreshSystemProxyState()
    }

    @discardableResult
    func stop(interactive: Bool = false) async -> Bool {
        if HarborProxyRecoveryPolicy.mustRestoreBeforeStop(hasBackup: HarborSystemProxy.hasBackup) {
            do { try HarborSystemProxy.restore(interactive: interactive) }
            catch {
                detail = "系统代理未恢复，已保留代理内核运行：" + error.localizedDescription
                refreshSystemProxyState()
                return false
            }
        }
        systemManaged = false
        let stopped = await stopCore()
        refreshSystemProxyState()
        return stopped
    }

    /// Stop only our Xray child. Node switching keeps the fixed macOS proxy
    /// address and the ownership/recovery snapshot intact; no authorization.
    private var coreProcessAlive: Bool {
        let mainAlive = child?.isRunning == true
            || adoptedPID.map { Darwin.kill($0, 0) == 0 } == true
        let underlayAlive = underlayPort == nil
            || underlayChild?.isRunning == true
            || adoptedUnderlayPID.map { Darwin.kill($0, 0) == 0 } == true
        return mainAlive && underlayAlive
    }

    private func startLivenessMonitoring() {
        guard livenessTask == nil else { return }
        livenessTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                await self.reconcileXrayLiveness()
                if self.running,
                   Date().timeIntervalSince(self.lastActiveHealthCheckAt ?? .distantPast)
                    >= HarborProxyLatencyPolicy.activeHealthCheckInterval {
                    self.checkingConnectivity = true
                    await self.finishHealthCheck(
                        port: self.configuredHTTPPort,
                        generation: self.connectionGeneration,
                        systemProxyInteractive: false
                    )
                }
                self.trimRuntimeErrorLogIfNeeded()
            }
        }
    }

    /// At most 512 KiB between low-rate checks, then retain the newest 64 KiB.
    /// O_APPEND on the child's stderr descriptor ensures it keeps writing at
    /// EOF even after this same-inode truncation, without restarting Xray.
    private func trimRuntimeErrorLogIfNeeded() {
        let url = runtimeErrorLogURL
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? NSNumber,
              size.uint64Value > maxRuntimeErrorLogBytes,
              let reader = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? reader.close() }
        let end = (try? reader.seekToEnd()) ?? size.uint64Value
        let start = end > retainedRuntimeErrorTailBytes ? end - retainedRuntimeErrorTailBytes : 0
        guard (try? reader.seek(toOffset: start)) != nil,
              let recent = try? reader.read(upToCount: Int(end - start)) else { return }
        let fd = url.path.withCString { Darwin.open($0, O_WRONLY | O_TRUNC | O_APPEND) }
        guard fd >= 0 else { return }
        defer { _ = Darwin.close(fd) }
        recent.withUnsafeBytes { data in
            guard let base = data.baseAddress else { return }
            var written = 0
            while written < data.count {
                let n = Darwin.write(fd, base.advanced(by: written), data.count - written)
                guard n > 0 else { break }
                written += n
            }
        }
    }

    private func reconcileXrayLiveness() async {
        guard running else { return }
        if coreProcessAlive {
            if let activeNodeID, !runningConfigMatches(activeNodeID, path: configPath) {
                healthy = false
                status = "代理运行配置与选中节点不一致"
                detail = "运行配置发生变化，已取消已连接状态；请重新选择节点"
                proxyAudit("periodic_identity_mismatch", nodeID: activeNodeID)
            }
            return
        }
        await handleUnexpectedXrayExit(pid: child?.processIdentifier ?? adoptedPID)
    }

    private func handleUnexpectedXrayExit(pid: Int32?) async {
        guard let pid,
              HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
                  running: running,
                  intentionallyStopping: intentionallyStoppingCore,
                  processMatches: pid == child?.processIdentifier || pid == adoptedPID,
                  coreAlive: coreProcessAlive
              ) else { return }
        // If an Xray crash leaves macOS pointing to dead listeners, restore
        // the previous network configuration without prompting for privileges.
        var restorationFailure: String?
        if HarborSystemProxy.hasBackup {
            do { try HarborSystemProxy.restore(interactive: false) }
            catch { restorationFailure = error.localizedDescription }
        }
        _ = await stopCore()
        systemManaged = false
        activeNodeID = nil
        healthy = false
        proxyAudit("unexpected_xray_exit")
        status = "代理内核异常退出"
        detail = restorationFailure.map {
            "Xray 意外退出，系统代理未能自动恢复：\($0)。请使用代理页面的恢复操作"
        } ?? "Xray 意外退出，已尝试恢复原系统代理。诊断记录：xray-runtime-warnings.log"
        refreshSystemProxyState(synchronizeOwnership: true)
    }

    private func stopCore() async -> Bool {
        intentionallyStoppingCore = true
        defer {
            intentionallyStoppingCore = false
            // A failed cleanup must not silently disable failure detection for
            // a child that is still running.
            if running && livenessTask == nil { startLivenessMonitoring() }
        }
        connectionGeneration &+= 1
        livenessTask?.cancel()
        livenessTask = nil
        healthTask?.cancel()
        healthTask = nil
        if adoptedPID != nil {
            await cleanupOrphan()
            guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                detail = "旧 Xray 进程尚未退出，不能切换节点"
                return false
            }
            adoptedPID = nil
        }
        if child == nil && FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
            await cleanupOrphan()
            guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                detail = "存在未清理的 Xray 进程，不能标记为已关闭"
                return false
            }
        }
        if let child {
            if child.isRunning {
                child.terminate()
                for _ in 0..<20 where child.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if child.isRunning { _ = Darwin.kill(child.processIdentifier, SIGKILL) }
                for _ in 0..<20 where child.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if child.isRunning {
                    detail = "代理内核未能退出，请手动检查进程"
                    return false
                }
            }
            self.child = nil
        }
        if let underlayChild {
            if underlayChild.isRunning {
                underlayChild.terminate()
                for _ in 0..<20 where underlayChild.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if underlayChild.isRunning { _ = Darwin.kill(underlayChild.processIdentifier, SIGKILL) }
                for _ in 0..<20 where underlayChild.isRunning {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                guard !underlayChild.isRunning else {
                    detail = "底座代理进程未能退出，请手动检查"
                    return false
                }
            }
            self.underlayChild = nil
        }
        if let underlayPort { HarborNodeLatencyTester.releasePortPair(underlayPort) }
        if let underlayConfigPath { try? FileManager.default.removeItem(at: underlayConfigPath) }
        underlayPort = nil
        underlayConfigPath = nil
        adoptedUnderlayPID = nil
        if let configPath { try? FileManager.default.removeItem(at: configPath) }
        try? FileManager.default.removeItem(at: runtimeRecordURL)
        configPath = nil; localPort = nil
        activeNodeID = nil
        running = false; healthy = false; checkingConnectivity = false; status = "已关闭"
        refreshSystemProxyState()
        return true
    }

    /// A previous app instance can exit without stopping Xray if macOS
    /// declined restoring the system proxy. Reuse its already-working listener
    /// instead of waiting for it to quit and racing for fixed ports.
    private func adoptExistingXray() -> Bool {
        guard HarborSystemProxy.isOwned(),
              let data = try? Data(contentsOf: runtimeRecordURL),
              let record = try? JSONDecoder().decode(HarborProxyProcessRecord.self, from: data),
              selectedNode != nil,
              recordedXrayIsOrphan(record),
              record.underlay.map({ validAdoptedUnderlay($0) }) ?? true,
              portListening(configuredHTTPPort),
              portListening(configuredHTTPPort + 1) else { return false }
        adoptedPID = record.pid
        adoptedUnderlayPID = record.underlay?.pid
        underlayPort = record.underlay?.httpPort
        underlayConfigPath = record.underlay.map { URL(fileURLWithPath: $0.configPath) }
        if let id = record.underlay?.nodeID { vpnGateUnderlayNodeID = id }
        configPath = URL(fileURLWithPath: record.configPath)
        localPort = configuredHTTPPort
        running = true
        startLivenessMonitoring()
        systemManaged = true
        // Adopt the actual outbound, never just the saved selectedID. If an
        // older connection differs, keep its listeners alive but clearly show
        // identity as unknown instead of reporting a false successful switch.
        let configData = configPath.flatMap { try? Data(contentsOf: $0) }
        let matched = configData.flatMap { data in
            nodes.first { node in
                node.protocolName == "openvpn"
                    ? HarborMihomoConfig.matches(
                        configuration: data, node: node,
                        underlaySocksPort: record.underlay.map { $0.httpPort + 1 })
                    : HarborProxyRuntimeIdentity.matches(configuration: data, node: node)
            }
        }
        activeNodeID = matched?.id
        healthy = false
        checkingConnectivity = matched != nil
        status = matched == nil ? "运行节点未能匹配保存的配置" : "已启动 · 正在检测网络"
        detail = matched == nil ? "已有代理仍在运行，但其实际节点不在当前列表；重新选择节点以恢复一致" : "已核验并接管上次运行的节点"
        proxyAudit(matched == nil ? "adopt_identity_unknown" : "adopt_matched", nodeID: matched?.id)
        if let matched, selectedID != matched.id {
            selectedID = matched.id
            persist()
        }
        guard matched != nil else { return true }
        connectionGeneration &+= 1
        let generation = connectionGeneration
        let port = configuredHTTPPort
        healthTask?.cancel()
        healthTask = Task { [weak self] in
            guard let self else { return }
            await self.finishHealthCheck(
                port: port,
                generation: generation,
                systemProxyInteractive: false
            )
        }
        return true
    }

    private func validAdoptedUnderlay(_ record: HarborProxyUnderlayRecord) -> Bool {
        guard recordedUnderlayIsOrphan(record),
              portListening(record.httpPort), portListening(record.httpPort + 1),
              let node = nodes.first(where: { $0.id == record.nodeID }),
              let config = try? Data(contentsOf: URL(fileURLWithPath: record.configPath)) else {
            return false
        }
        return HarborProxyRuntimeIdentity.matches(configuration: config, node: node)
    }

    /// Only remove an orphan that matches Harbor's unique config path and executable.
    /// Never kill a PID solely because a prior runtime record contains that number.
    private func recordedXrayIsOrphan(_ record: HarborProxyProcessRecord) -> Bool {
        recordedProcessIsOrphan(pid: record.pid, configPath: record.configPath,
                                executablePath: record.executablePath, prefix: "runtime-")
    }

    private func recordedUnderlayIsOrphan(_ record: HarborProxyUnderlayRecord) -> Bool {
        guard record.executablePath == root.appendingPathComponent("xray").path else { return false }
        return recordedProcessIsOrphan(pid: record.pid, configPath: record.configPath,
                                       executablePath: record.executablePath, prefix: "underlay-")
    }

    private func recordedProcessIsOrphan(pid: Int32, configPath: String,
                                         executablePath: String, prefix: String) -> Bool {
        let config = URL(fileURLWithPath: configPath).standardizedFileURL
        let xray = root.appendingPathComponent("xray").path
        let mihomo = root.appendingPathComponent("mihomo").path
        guard pid > 0,
              config.deletingLastPathComponent() == root.standardizedFileURL,
              config.lastPathComponent.hasPrefix(prefix),
              config.pathExtension == "json",
              executablePath == xray || executablePath == mihomo,
              Darwin.kill(pid, 0) == 0 else { return false }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(pid), "-o", "ppid=", "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let parts = output.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            return process.terminationStatus == 0 &&
                parts.count == 2 && parts[0] == "1" &&
                parts[1].contains(executablePath) &&
                parts[1].contains(configPath) &&
                (executablePath == xray
                    ? parts[1].contains("run") : parts[1].contains("-f"))
        } catch { return false }
    }

    private func cleanupOrphan() async {
        guard let data = try? Data(contentsOf: runtimeRecordURL),
              let record = try? JSONDecoder().decode(HarborProxyProcessRecord.self, from: data),
              record.pid > 0 else { return }
        let config = URL(fileURLWithPath: record.configPath).standardizedFileURL
        guard config.deletingLastPathComponent() == root.standardizedFileURL,
              config.lastPathComponent.hasPrefix("runtime-"),
              config.pathExtension == "json",
              (record.executablePath == root.appendingPathComponent("xray").path
               || record.executablePath == root.appendingPathComponent("mihomo").path) else {
            detail = "检测到异常的旧代理恢复记录，已停止自动清理"
            return
        }
        let isAlive = Darwin.kill(record.pid, 0) == 0
        if isAlive {
            guard recordedXrayIsOrphan(record) else {
                detail = "旧 Xray 仍由其他进程管理或运行身份已变更，已停止自动清理"
                return
            }
            _ = Darwin.kill(record.pid, SIGTERM)
            for _ in 0..<20 where Darwin.kill(record.pid, 0) == 0 {
                try? await Task.sleep(for: .milliseconds(50))
            }
            if Darwin.kill(record.pid, 0) == 0 {
                // Revalidate immediately before escalating, protecting against
                // PID reuse and accidental termination of unrelated processes.
                guard recordedXrayIsOrphan(record) else {
                    detail = "旧 Xray 身份发生变化，已停止自动清理"
                    return
                }
                _ = Darwin.kill(record.pid, SIGKILL)
                for _ in 0..<20 where Darwin.kill(record.pid, 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
            }
            guard Darwin.kill(record.pid, 0) != 0 else {
                detail = "旧 Xray 未退出，端口保持占用；不会自动更换端口"
                return
            }
        }
        if let underlay = record.underlay {
            let underlayConfig = URL(fileURLWithPath: underlay.configPath).standardizedFileURL
            guard underlayConfig.deletingLastPathComponent() == root.standardizedFileURL,
                  underlayConfig.lastPathComponent.hasPrefix("underlay-"),
                  underlayConfig.pathExtension == "json",
                  underlay.executablePath == root.appendingPathComponent("xray").path else {
                detail = "底座代理恢复记录异常，已停止自动清理"
                return
            }
            if Darwin.kill(underlay.pid, 0) == 0 {
                guard recordedUnderlayIsOrphan(underlay) else {
                    detail = "底座代理仍由其他进程管理，已停止自动清理"
                    return
                }
                _ = Darwin.kill(underlay.pid, SIGTERM)
                for _ in 0..<20 where Darwin.kill(underlay.pid, 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Darwin.kill(underlay.pid, 0) == 0 {
                    guard recordedUnderlayIsOrphan(underlay) else { return }
                    _ = Darwin.kill(underlay.pid, SIGKILL)
                }
                guard Darwin.kill(underlay.pid, 0) != 0 else {
                    detail = "底座代理未能退出，已保留恢复记录"
                    return
                }
            }
            try? FileManager.default.removeItem(at: underlayConfig)
        }
        try? FileManager.default.removeItem(at: config)
        try? FileManager.default.removeItem(at: runtimeRecordURL)
    }

    private func choosePort() throws -> Int {
        let port = try HarborProxyPortPolicy.validate(httpPort: configuredHTTPPort)
        if portListening(port) {
            throw HarborProxyError.invalid("HTTP 端口 \(port) 被其他进程占用。请关闭占用程序，或在代理页面手动更改端口；不会自动切换端口。")
        }
        if portListening(port + 1) {
            throw HarborProxyError.invalid("SOCKS5 端口 \(port + 1) 被其他进程占用。请关闭占用程序，或在代理页面手动更改端口；不会自动切换端口。")
        }
        return port
    }
    /// Check for a real listening socket instead of probing with bind(). A
    /// recently closed TCP connection can keep a port in TIME_WAIT and make a
    /// bind preflight fail even though Xray can immediately listen again.
    private func portListening(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
