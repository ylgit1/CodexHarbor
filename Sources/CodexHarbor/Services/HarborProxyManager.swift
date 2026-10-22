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
    var routingRules = true
    // Optional so existing Keychain JSON decodes without losing saved subscriptions.
    var forcedProxyDomains: [String]?
    // Optional to preserve existing Keychain configurations on upgrade.
    var httpListenPort: Int?
    var autoManageSystemProxy: Bool?
}
@MainActor
private struct HarborProxyProcessRecord: Codable {
    var pid: Int32
    var configPath: String
    var executablePath: String
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
    @Published private(set) var running = false
    @Published private(set) var healthy = false
    @Published private(set) var checkingConnectivity = false
    @Published private(set) var busy = false
    @Published private(set) var systemManaged = false
    @Published private(set) var status = "已关闭"
    @Published private(set) var detail = ""
    @Published private(set) var localPort: Int?
    @Published private(set) var configuredHTTPPort = HarborProxyPortPolicy.defaultHTTPPort
    @Published private(set) var switchingNodeID: String?
    private var pendingActivation = HarborProxyActivationQueue()
    private var activationInProgress = false
    private var autoManageSystemProxy = true
    @Published private(set) var probeResults: [String: HarborProxyProbeResult] = [:]
    @Published private(set) var latencyTesting = false
    @Published private(set) var installingCore = false
    @Published private(set) var latencyCurrentID: String?
    @Published private(set) var latencyCompleted = 0
    @Published private(set) var latencyTotal = 0
    private var latencyCancellationRequested = false
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
    private var configurationLoaded = false
    private var child: Process?
    private var adoptedPID: Int32?
    private var configPath: URL?
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
    private var runtimeRecordURL: URL { root.appendingPathComponent("active-process.json") }
    private let root: URL
    private var appActivationObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var systemProxyMonitor: HarborSystemProxyChangeMonitor?
    var selectedNode: HarborProxyNode? { nodes.first { $0.id == selectedID } }
    var coreInstalled: Bool {
        let files = ["xray", "geoip.dat", "geosite.dat"]
        return files.allSatisfy {
            let path = root.appendingPathComponent($0).path
            return $0 == "xray"
                ? FileManager.default.isExecutableFile(atPath: path)
                : FileManager.default.fileExists(atPath: path)
        }
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
            Task { @MainActor [weak self] in self?.refreshSystemProxyState(synchronizeOwnership: true) }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in self?.refreshSystemProxyState(synchronizeOwnership: true) }
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
                subscriptions = state.subscriptions
                selectedID = state.selectedID
                routingRules = state.routingRules
                autoManageSystemProxy = state.autoManageSystemProxy ?? true
                configuredHTTPPort = (try? HarborProxyPortPolicy.validate(
                    httpPort: state.httpListenPort ?? HarborProxyPortPolicy.defaultHTTPPort
                )) ?? HarborProxyPortPolicy.defaultHTTPPort
                forcedProxyDomains = (try? HarborProxyDomainRules.normalized(
                    state.forcedProxyDomains ?? HarborProxyDomainRules.defaults
                )) ?? HarborProxyDomainRules.defaults
                configurationLoaded = true
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
    }

    private func persist() {
        guard configurationLoaded else { return }
        store.nodes = nodes
        store.subscriptions = subscriptions
        store.selectedID = selectedID
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
            defer { busy = false }
            do {
                let incoming = try await downloadSubscriptionNodes(from: sourceURL, id: id)
                let update = applySubscriptionNodes(incoming, id: id)
                // Both values are committed only after a successful download.
                subscriptions[index] = updated
                persist()
                detail = "订阅「\(updated.name)」已保存并更新 \(update.count) 个节点" +
                    (update.retainedActive
                        ? "；原连接保持运行，请手动选择新节点"
                        : "；不会自动切换当前连接")
                return true
            } catch {
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
        detail = "已恢复订阅名称「\(nodes[index].name)」"
    }
    @discardableResult
    func removeSubscription(_ id: String) -> Bool {
        guard !busy, !latencyTesting else {
            detail = "请等待当前操作结束后再删除订阅"
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return false }
        let matching = nodes.filter { $0.subscriptionID == id }
        if running && matching.contains(where: { $0.id == selectedID }) {
            detail = "正在使用此订阅节点，请先清理代理再删除订阅"
            return false
        }
        subscriptions.removeAll { $0.id == id }
        let removedIDs = Set(matching.map(\.id))
        nodes.removeAll { removedIDs.contains($0.id) }
        for nodeID in removedIDs { probeResults.removeValue(forKey: nodeID) }
        subscriptionUpdatedAt.removeValue(forKey: id)
        if let selectedID, removedIDs.contains(selectedID) {
            self.selectedID = nodes.first?.id
        }
        persist()
        detail = "已删除订阅「\(subscription.name)」及其 \(matching.count) 个节点"
        return true
    }

    func refreshSubscription(_ id: String) async {
        guard !busy, let subscription = subscriptions.first(where: { $0.id == id }),
              let url = URL(string: subscription.url) else { return }
        busy = true
        defer { busy = false }
        do {
            let incoming = try await downloadSubscriptionNodes(from: url, id: id)
            let update = applySubscriptionNodes(incoming, id: id)
            persist()
            detail = "订阅更新完成：\(update.count) 个节点" +
                (update.retainedActive
                    ? "；原连接仍在运行，请手动选择最新节点"
                    : "")
        } catch { detail = "更新失败，已保留原节点：" + error.localizedDescription }
    }

    /// Both refresh and changed-URL edits use the same validation and parsing.
    private func downloadSubscriptionNodes(from url: URL, id: String) async throws -> [HarborProxyNode] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        let config = URLSessionConfiguration.ephemeral
        if running, healthy, let localPort {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": localPort,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": localPort
            ]
        }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 2_000_000,
              let text = String(data: data, encoding: .utf8) else {
            throw HarborProxyError.invalid("订阅响应不是有效的 HTTP 200 文本（最大 2 MB）")
        }
        let incoming = HarborProxyLinks.parse(text).map { original -> HarborProxyNode in
            var node = original
            node.subscriptionID = id
            return node
        }
        guard !incoming.isEmpty else {
            throw HarborProxyError.invalid("订阅没有可识别的节点，已拒绝清空旧列表")
        }
        return incoming
    }

    /// No Xray restart is performed. Preserve matching profile IDs, aliases
    /// and favorites; retain an active endpoint removed by the provider until
    /// the user explicitly connects to a new profile.
    @discardableResult
    private func applySubscriptionNodes(_ incoming: [HarborProxyNode], id: String)
        -> (count: Int, retainedActive: Bool) {
        let merged = HarborProxySubscriptionReconciler.replace(
            current: nodes, incoming: incoming, subscriptionID: id,
            selectedID: selectedID, keepActiveConnection: running
        )
        let validIDs = Set(merged.nodes.map(\.id))
        nodes = merged.nodes
        selectedID = merged.selectedID
        probeResults = probeResults.filter { validIDs.contains($0.key) }
        subscriptionUpdatedAt[id] = .now
        return (incoming.count, merged.retainedActiveNode)
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
            await activateOne(
                request.nodeID,
                restart: request.restart,
                userInitiated: request.userInitiated
            )
        }
    }

    private func activateOne(_ id: String, restart: Bool, userInitiated: Bool) async {
        guard nodes.contains(where: { $0.id == id }) else {
            detail = "所选节点已不存在"
            return
        }
        guard let preserveSystemProxy = prepareSystemProxyForActivation() else { return }
        let previousID = selectedID
        let wasRunning = running
        let wasManaged = preserveSystemProxy

        autoManageSystemProxy = HarborProxyConnectionIntent.shouldManageSystemProxy(
            persistedPreference: autoManageSystemProxy,
            userInitiated: userInitiated
        )

        // Remember the selection before starting: even a failed first attempt
        // must not force the user to connect the old node before choosing another.
        selectedID = id
        persist()

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

        if wasRunning {
            // Keep the macOS proxy settings and ownership snapshot untouched:
            // Xray's fixed ports do not change when only the remote node changes.
            guard await stopCore() else {
                detail = "旧代理内核仍未退出，请稍候重试：" + detail
                return
            }
        }

        await start(
            preservingSystemProxy: wasManaged,
            systemProxyInteractive: userInitiated
        )
        if !running {
            let failure = detail
            // Restore the previous active node if the replacement fails.
            if wasRunning, let previousID, previousID != id,
               nodes.contains(where: { $0.id == previousID }) {
                selectedID = previousID
                await start(
                    preservingSystemProxy: wasManaged,
                    systemProxyInteractive: false
                )
                if running {
                    detail = "新节点连接失败：\(failure)；已恢复原连接"
                } else {
                    detail = "新节点连接失败：\(failure)；原连接恢复失败：" + detail
                }
                // Preserve the user's next choice for retry if no client is live.
                if !running { selectedID = id }
                persist()
            }
            return
        }

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
    func clearProxy() async {
        if running || HarborSystemProxy.hasBackup {
            if await stop() {
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
        preservingSystemProxy: Bool = false,
        waitForHealth: Bool = false,
        systemProxyInteractive: Bool = false
    ) async {
        guard !busy, !running else { return }
        // A former Xray can still be alive if its health state was lost.
        // Do not overwrite our process handle and leave an orphan listening.
        if child != nil {
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
        guard let node = selectedNode else { detail = "先导入并选择节点"; return }
        guard coreInstalled else { detail = "请从安装包恢复内置 Xray 内核"; return }
        busy = true; defer { busy = false }
        status = "正在连接"; detail = ""
        do {
            let port = try choosePort()
            let config = try HarborXrayConfig.make(node: node, httpPort: port, ruleMode: routingRules,
                                                  forcedProxyDomains: forcedProxyDomains)
            let file = root.appendingPathComponent("runtime-\(UUID().uuidString).json")
            try config.write(to: file, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
            configPath = file
            let process = Process()
            process.executableURL = root.appendingPathComponent("xray")
            process.currentDirectoryURL = root
            process.arguments = ["run", "-config", file.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            child = process; localPort = port
            let record = HarborProxyProcessRecord(
                pid: process.processIdentifier, configPath: file.path,
                executablePath: process.executableURL?.path ?? ""
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
                throw HarborProxyError.invalid("Xray 未能监听本地 HTTP/SOCKS5 端口，请检查端口或节点配置")
            }
            running = true
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

    /// Complete outbound verification in the background for ordinary node
    /// starts. Only the still-current Xray generation may publish the result.
    private func finishHealthCheck(
        port: Int,
        generation: UInt64,
        systemProxyInteractive: Bool
    ) async {
        let reachable = await probe(port: port)
        guard generation == connectionGeneration,
              running, localPort == port else { return }
        guard coreProcessAlive else {
            _ = await stopCore()
            status = "代理内核已退出"
            detail = "本地监听进程意外退出，请重新连接或检查节点配置"
            return
        }
        checkingConnectivity = false
        healthy = reachable
        if reachable {
            status = "已连接"
            detail = "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
            if autoManageSystemProxy && !systemManaged {
                enableSystemProxy(interactive: systemProxyInteractive)
            }
        } else {
            status = "内核已启动 · 网络检测失败"
            detail = "本地 HTTP/SOCKS5 端口已就绪，但外网检测失败；可以直接切换其他节点"
        }
    }

    func verify() async {
        guard running, let port = localPort, !busy else { return }
        busy = true; defer { busy = false }
        healthy = await probe(port: port)
        status = healthy ? "已连接" : "连接异常"
        detail = healthy ? "当前节点可访问外网" : "内核运行中，但测试目标不可达；可尝试切换节点"
    }

    private func probe(port: Int) async -> Bool {
        let nodeID = selectedID
        if let milliseconds = await probeAddress(
            "https://www.apple.com/library/test/success.html",
            port: port
        ) {
            if let nodeID { probeResults[nodeID] = HarborProxyProbeResult(milliseconds: milliseconds) }
            return true
        }

        // Independent fallbacks run together. A blocked target therefore adds
        // one timeout window instead of two serial timeout windows.
        async let gstatic = probeAddress("https://www.gstatic.com/generate_204", port: port)
        async let cloudflare = probeAddress("https://www.cloudflare.com/cdn-cgi/trace", port: port)
        let fallbackResults = await [gstatic, cloudflare]
        if let milliseconds = fallbackResults.compactMap({ $0 }).min() {
            if let nodeID { probeResults[nodeID] = HarborProxyProbeResult(milliseconds: milliseconds) }
            return true
        }
        if let nodeID { probeResults[nodeID] = HarborProxyProbeResult(milliseconds: nil) }
        return false
    }

    private func probeAddress(_ address: String, port: Int) async -> Int? {
        if Task.isCancelled { return nil }
        let started = ContinuousClock.now
        let succeeded = await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            proc.arguments = ["-q", "--silent", "--fail", "--noproxy", "", "--proxy",
                              "http://127.0.0.1:\(port)", "--connect-timeout", "2",
                              "--max-time", "4", "--output", "/dev/null", address]
            proc.standardError = FileHandle.nullDevice
            proc.standardOutput = FileHandle.nullDevice
            proc.terminationHandler = { p in continuation.resume(returning: p.terminationStatus == 0) }
            do { try proc.run() } catch { continuation.resume(returning: false) }
        }
        guard succeeded, !Task.isCancelled else { return nil }
        let duration = started.duration(to: .now).components
        return max(1, Int(duration.seconds * 1_000
            + duration.attoseconds / 1_000_000_000_000_000))
    }

    /// User-triggered latency checks. Each node uses a short-lived independent
    /// Xray process and HTTPS request; never switch the active system proxy.
    func testLatency(_ ids: [String]) async {
        guard !latencyTesting, !busy, coreInstalled else {
            if !coreInstalled { detail = "请先恢复内置 Xray，才能测试节点延迟" }
            return
        }
        let uniqueIDs = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
        let targets = uniqueIDs.compactMap { id in nodes.first(where: { $0.id == id }) }
        guard !targets.isEmpty else { return }

        latencyTesting = true
        latencyCancellationRequested = false
        latencyCompleted = 0
        latencyTotal = targets.count
        defer {
            latencyTesting = false
            latencyCurrentID = nil
            latencyCancellationRequested = false
        }
        for node in targets {
            if latencyCancellationRequested || Task.isCancelled { break }
            latencyCurrentID = node.id
            let result = await HarborNodeLatencyTester.measure(node: node, root: root, ruleMode: routingRules,
                                                                 forcedProxyDomains: forcedProxyDomains)
            probeResults[node.id] = HarborProxyProbeResult(milliseconds: result)
            latencyCompleted += 1
        }
        detail = "本次测试完成 \(latencyCompleted)/\(latencyTotal) 个节点；测试为经过 Xray 的 HTTPS 请求耗时"
    }

    func cancelLatencyTests() {
        latencyCancellationRequested = true
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
        if child?.isRunning == true { return true }
        if let adoptedPID { return Darwin.kill(adoptedPID, 0) == 0 }
        return false
    }

    private func stopCore() async -> Bool {
        connectionGeneration &+= 1
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
        if let configPath { try? FileManager.default.removeItem(at: configPath) }
        try? FileManager.default.removeItem(at: runtimeRecordURL)
        configPath = nil; localPort = nil
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
              portListening(configuredHTTPPort),
              portListening(configuredHTTPPort + 1) else { return false }
        adoptedPID = record.pid
        configPath = URL(fileURLWithPath: record.configPath)
        localPort = configuredHTTPPort
        running = true
        systemManaged = true
        healthy = false
        checkingConnectivity = true
        status = "已启动 · 正在检测网络"
        detail = "已接管上次运行的 Xray，端口保持不变"
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

    /// Only remove an orphan that matches Harbor's unique config path and executable.
    /// Never kill a PID solely because a prior runtime record contains that number.
    private func recordedXrayIsOrphan(_ record: HarborProxyProcessRecord) -> Bool {
        let config = URL(fileURLWithPath: record.configPath).standardizedFileURL
        guard record.pid > 0,
              config.deletingLastPathComponent() == root.standardizedFileURL,
              config.lastPathComponent.hasPrefix("runtime-"),
              config.pathExtension == "json",
              record.executablePath == root.appendingPathComponent("xray").path,
              Darwin.kill(record.pid, 0) == 0 else { return false }
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/ps")
        process.arguments = ["-ww", "-p", String(record.pid), "-o", "ppid=", "-o", "command="]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
            let output = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            let parts = output.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
            return process.terminationStatus == 0 &&
                parts.count == 2 && parts[0] == "1" &&
                parts[1].contains(record.executablePath) &&
                parts[1].contains(record.configPath) &&
                parts[1].contains("run")
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
              record.executablePath == root.appendingPathComponent("xray").path else {
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
