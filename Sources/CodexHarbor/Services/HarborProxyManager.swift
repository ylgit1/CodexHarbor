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
    // Optional fields preserve existing encrypted state on upgrade.
    var warpAccount: HarborWARPAccount?
    var warpEndpoint: HarborWARPEndpoint?
    var warpProbeEndpoints: [String: HarborWARPEndpoint]?
    var routingRules = true
    // Optional so existing Keychain JSON decodes without losing saved subscriptions.
    var forcedProxyDomains: [String]?
    // Optional to preserve existing Keychain configurations on upgrade.
    var httpListenPort: Int?
    var autoManageSystemProxy: Bool?
    var resumeConnectionOnLaunch: Bool?
    var subscriptionUpdatedAt: [String: Date]?
    var probeNetworkFingerprint: String?
    var probeNetworkChangedAt: Date?
    var retainedRuntimeNodeIDs: Set<String>?
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
    var warpEndpoint: HarborWARPEndpoint?
}

private struct HarborProxyUnderlayRecord: Codable {
    var pid: Int32
    var configPath: String
    var executablePath: String
    var httpPort: Int
    var nodeID: String
}

private enum HarborProxyKeychain {
    private static var legacyQuery: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.codexharbor.v2rayn-replacement",
        kSecAttrAccount as String: "settings"
    ] }
    private static var keyQuery: [String: Any] { [
        kSecClass as String: kSecClassGenericPassword,
        kSecAttrService as String: "com.codexharbor.proxy-state-key",
        kSecAttrAccount as String: "v2"
    ] }

    static func loadLegacy() throws -> HarborProxyState? {
        var q = Self.legacyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw HarborProxyError.invalid("暂时无法读取旧版代理配置，请解锁钥匙串后重试")
        }
        return try JSONDecoder().decode(HarborProxyState.self, from: data)
    }

    static func encryptionKey(create: Bool) throws -> SymmetricKey {
        var q = Self.keyQuery
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(q as CFDictionary, &result)
        if status == errSecSuccess, let data = result as? Data, data.count == 32 {
            return SymmetricKey(data: data)
        }
        guard create, status == errSecItemNotFound else {
            let message = status == errSecItemNotFound
                ? "钥匙串中找不到原来的代理密钥，原配置已保留。"
                : "无法访问代理密钥。请解锁登录钥匙串后重试；原配置已保留。"
            throw HarborProxyError.invalid(message)
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
        if addStatus == errSecDuplicateItem { return try encryptionKey(create: false) }
        guard addStatus == errSecSuccess else {
            throw HarborProxyError.invalid("无法保存代理配置加密密钥")
        }
        return SymmetricKey(data: data)
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
            "State:/Network/Global/IPv4",
            "State:/Network/Global/IPv6"
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
    static let favoriteNodeIDsKey = "com.codexharbor.proxy.favoriteNodeIDs"
    @Published private(set) var nodes: [HarborProxyNode] = []
    @Published private(set) var subscriptions: [HarborProxySubscription] = []
    @Published private(set) var selectedID: String?
    /// Runtime identity is separate from the desired/saved profile; the UI
    /// must never call a merely selected node "connected".
    @Published private(set) var activeNodeID: String?
    @Published private(set) var running = false
    @Published private(set) var healthy = false
    @Published private(set) var checkingConnectivity = false
    @Published private(set) var warpExitIP: String?
    @Published private(set) var websiteChecking = false
    @Published private(set) var websiteSummary = ""
    private var websiteCancellation: HarborLatencyCancellation?
    @Published private(set) var busy = false
    @Published private(set) var systemManaged = false
    @Published private(set) var status = "已关闭"
    @Published private(set) var detail = ""
    @Published private(set) var localPort: Int?
    @Published private(set) var configuredHTTPPort = HarborProxyPortPolicy.defaultHTTPPort
    @Published private(set) var switchingNodeID: String?
    private var pendingActivation = HarborProxyActivationQueue()
    private var activationInProgress = false
    private var connectionTransition = false
    private var shuttingDownConnection = false
    /// Cancels only the isolated preconnection check; it never stops the
    /// currently active proxy or changes macOS network settings.
    private var activationPreflightCancellation: HarborLatencyCancellation?
    private var autoManageSystemProxy = true
    @Published private(set) var probeResults: [String: HarborProxyProbeResult] = [:]
    @Published private(set) var nodeServerLocations: [String: HarborProxyIPLocation] = [:]
    @Published private(set) var nodeNetworkEvidence: [String: HarborProxyNetworkEvidence] = [:]
    @Published private(set) var nodeExitLocations: [String: HarborProxyExitLocation] = [:]
    @Published private(set) var exitGeoUpdating = false
    @Published private(set) var exitGeoCleaningUp = false
    @Published private(set) var exitGeoSummary = ""
    @Published private(set) var exitGeoUnrecognizedIDs: Set<String> = []
    @Published private(set) var exitGeoFailureReasons: [String: String] = [:]
    @Published private(set) var exitGeoCompleted = 0
    @Published private(set) var exitGeoTotal = 0
    @Published private(set) var latencyTesting = false
    @Published private(set) var latencyStopping = false
    @Published private(set) var latencySummary = ""
    @Published private(set) var latencyBatchIDs: Set<String> = []
    @Published private(set) var installingCore = false
    @Published private(set) var latencyCurrentID: String?
    @Published private(set) var latencyTestingIDs: Set<String> = []
    @Published private(set) var latencyCompleted = 0
    @Published private(set) var latencyTotal = 0
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
    @Published private(set) var configurationLoaded = false
    @Published private(set) var configurationLoadError: String?
    @Published private(set) var configurationSaveError: String?
    @Published private(set) var resumeConnectionOnLaunch = false
    @Published private(set) var probeNetworkChangedAt = Date.distantPast
    private var store = HarborProxyState()
    private let persistence: HarborProxyStateFile<HarborProxyState>
    private var persistenceGeneration = 0
    private var persistenceTask: Task<Void, Never>?
    private var pendingSave: (state: HarborProxyState, generation: Int)?
    private var geoRefreshTask: Task<Void, Never>?
    private var exitGeoTask: Task<Void, Never>?
    private var exitGeoBatchGeneration: UUID?
    private var exitGeoCancellation: HarborLatencyCancellation?
    private var exitGeoManualGeneration: UUID?
    private var exitGeoWatchdog: Task<Void, Never>?
    private var exitGeoPendingIDs = Set<String>()
    private var exitGeoInFlightIDs = Set<String>()
    private var exitGeoForcedIDs = Set<String>()
    private var exitGeoManualIDs = Set<String>()
    private var exitGeoManualSucceeded = 0
    private var exitGeoManualNotStarted = 0
    private var exitGeoAttemptedAt: [String: Date] = [:]
    private var exitGeoFailureCounts: [String: Int] = [:]
    private var exitGeoRetryTask: Task<Void, Never>?
    private var nodeServerResolvedAt: [String: Date] = [:]
    private var lastActiveHealthCheckAt: Date?
    private var child: Process?
    private var adoptedPID: Int32?
    private var configPath: URL?
    private var underlayChild: Process?
    private var adoptedUnderlayPID: Int32?
    private var underlayConfigPath: URL?
    private var underlayPort: Int?
    private var vpnGateUnderlayNodeID: String?
    private var activeWARPProfile: HarborWARPProfile?
    private var activePolicy: RoutingPolicy?
    private var warpRegistrationTask: Task<HarborWARPAccount, Error>?
    private var vpnGateDownloadCancellation: HarborLatencyCancellation?
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

    private struct RoutingPolicy: Sendable {
        let ruleMode: Bool
        let forcedDomains: [String]
        let localHostAddresses: [String: [String]]
        var localHosts: [String] { localHostAddresses.keys.sorted() }

        static func read(ruleMode: Bool, forcedDomains: [String]) async -> Self {
            await Task.detached(priority: .utility) {
                let file = URL(fileURLWithPath: "/etc/hosts")
                let bytes = (try? FileHandle(forReadingFrom: file)).flatMap { handle -> Data? in
                    defer { try? handle.close() }
                    return try? handle.read(upToCount: 65_536)
                }
                let addresses = bytes.map {
                    HarborProxyDomainRules.localHostAddresses(
                        in: String(decoding: $0, as: UTF8.self), forced: forcedDomains)
                } ?? [:]
                return Self(ruleMode: ruleMode, forcedDomains: forcedDomains, localHostAddresses: addresses)
            }.value
        }

        func configuration(for node: HarborProxyNode, port: Int, underlayPort: Int? = nil,
                           warp: HarborWARPProfile? = nil) throws -> Data {
            let testHost = HarborNodeLatencyTester.verificationURL(openVPN: node.protocolName == "openvpn").host
            if node.protocolName == "openvpn" {
                return try HarborMihomoConfig.make(
                    node: node, httpPort: port, underlaySocksPort: underlayPort.map { $0 + 1 },
                    warpProfile: warp, ruleMode: ruleMode, forcedProxyDomains: forcedDomains,
                    localHosts: localHosts, verificationHost: testHost, localHostAddresses: localHostAddresses)
            }
            return try HarborXrayConfig.make(
                node: node, httpPort: port, ruleMode: ruleMode, forcedProxyDomains: forcedDomains,
                routeVerificationViaProxy: true, verificationHost: testHost, localHosts: localHosts)
        }
    }

    private enum VPNGateRoute: Sendable {
        case direct
        case underlay(String)
        case warp(HarborWARPProfile)
    }
    var selectedNode: HarborProxyNode? { nodes.first { $0.id == selectedID } }
    var activeNode: HarborProxyNode? { nodes.first { $0.id == activeNodeID } }
    private var workingVPNGateUnderlay: (nodeID: String, socksPort: Int, routeID: String)? {
        guard running, healthy, let activeNode,
              !HarborIndependentWARP.isBuiltIn(activeNode) else { return nil }
        let isOpenVPN = activeNode.protocolName == "openvpn"
        guard let port = isOpenVPN ? underlayPort : localPort,
              let nodeID = isOpenVPN ? vpnGateUnderlayNodeID : activeNodeID else { return nil }
        return (nodeID, port + 1, "underlay:" + nodeID)
    }

    /// A relay's validity is scoped to its network path. Changing from
    /// direct access to VLESS (or switching VLESS nodes) requires new evidence.
    private var vpnGateProbeRouteID: String {
        workingVPNGateUnderlay?.routeID ?? currentVPNGateRouteID ?? "direct"
    }

    private var currentVPNGateRouteID: String? {
        guard activeNode?.protocolName == "openvpn" else { return nil }
        if underlayPort != nil, let vpnGateUnderlayNodeID { return "underlay:" + vpnGateUnderlayNodeID }
        return activeWARPProfile?.routeID ?? "direct"
    }

    struct MeasurementScope: Sendable {
        let activeID: String?
        let activeRouteID: String?
        let changedAt: Date
        let workingUnderlay: String?
        let warpAccountID: String?
        let warpEndpoint: HarborWARPEndpoint?
        let warpEndpoints: [String: HarborWARPEndpoint]

        func accepts(_ result: HarborProxyProbeResult, for node: HarborProxyNode) -> Bool {
            guard let date = result.effectiveRealCheckedAt, date >= changedAt else { return false }
            guard node.protocolName == "openvpn" else { return true }
            if result.probeRouteID == "direct" { return true }
            if let workingUnderlay, result.probeRouteID == workingUnderlay { return true }
            guard let warpAccountID, let endpoint = warpEndpoints[node.id] ?? warpEndpoint else { return false }
            return result.probeRouteID == "warp:\(warpAccountID):\(endpoint.id)"
        }

        func verifiedExit(_ exit: HarborProxyExitLocation?, for node: HarborProxyNode,
                          resolvedIP: String?) -> HarborProxyIPLocation? {
            guard let exit, exit.observedAt >= changedAt,
                  node.id != activeID || exit.probeRouteID == activeRouteID else { return nil }
            return exit.verifiedLocation(for: node, resolvedServerIP: resolvedIP)
        }
    }

    var measurementScope: MeasurementScope {
        MeasurementScope(activeID: activeNodeID, activeRouteID: currentVPNGateRouteID, changedAt: probeNetworkChangedAt,
                         workingUnderlay: workingVPNGateUnderlay?.routeID, warpAccountID: store.warpAccount?.id,
                         warpEndpoint: store.warpEndpoint, warpEndpoints: store.warpProbeEndpoints ?? [:])
    }

    func isUsable(_ result: HarborProxyProbeResult, for node: HarborProxyNode) -> Bool {
        result.isUsable() && measurementScope.accepts(result, for: node)
    }

    func isUnavailable(_ result: HarborProxyProbeResult, for node: HarborProxyNode) -> Bool {
        result.isConfirmedUnavailable && measurementScope.accepts(result, for: node)
    }

    private func warpProfile(for node: HarborProxyNode) -> HarborWARPProfile? {
        guard node.protocolName == "openvpn",
              probeResults[node.id]?.probeRouteID != "direct",
              probeResults[node.id]?.probeRouteID?.hasPrefix("underlay:") != true,
              let account = store.warpAccount,
              let endpoint = store.warpProbeEndpoints?[node.id] ?? store.warpEndpoint else { return nil }
        return HarborWARPProfile(account: account, endpoint: endpoint)
    }

    /// Enrollment and discovery are independent of the selected subscription,
    /// the active proxy, and every VPN Gate candidate.
    private func prepareIndependentVPNGateTunnel(
        cancellation: HarborLatencyCancellation,
        preferred: HarborWARPEndpoint? = nil
    ) async throws -> HarborWARPTunnel {
        guard mihomoInstalled else { throw HarborProxyError.invalid("请从安装包恢复内置 Mihomo 内核") }
        if store.warpAccount == nil {
            detail = "首次准备独立筛选通道，正在生成本机凭据"
            if warpRegistrationTask == nil {
                warpRegistrationTask = Task { try await HarborWARPRegistration.register() }
            }
            let task = warpRegistrationTask!
            let observer = cancellation.observe { task.cancel() }
            defer {
                if let observer { cancellation.removeObserver(observer) }
                warpRegistrationTask = nil
            }
            store.warpAccount = try await task.value
            persist()
        }
        guard !cancellation.isCancelled, let account = store.warpAccount else { throw CancellationError() }
        detail = "正在验证独立筛选通道，无需启用订阅节点"
        let tunnel = try await HarborWARPTunnel.prepare(
            account: account, preferred: preferred ?? store.warpEndpoint,
            root: root, cancellation: cancellation)
        store.warpEndpoint = tunnel.profile.endpoint
        persist()
        return tunnel
    }

    private func runningConfigMatches(_ id: String, path: URL?) -> Bool {
        guard let node = nodes.first(where: { $0.id == id }),
              let path, let data = try? Data(contentsOf: path) else { return false }
        return HarborIndependentWARP.isBuiltIn(node)
            ? activeWARPProfile.map {
                HarborWARPConfig.matches(configuration: data, profile: $0,
                                        httpPort: localPort ?? configuredHTTPPort)
              } ?? false
            : node.protocolName == "openvpn"
            ? HarborMihomoConfig.matches(configuration: data, node: node,
                                         underlaySocksPort: underlayPort.map { $0 + 1 },
                                         warpProfile: activeWARPProfile)
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
            try HarborProbeFiles.write(config, to: file)
            let engine = Process()
            engine.executableURL = root.appendingPathComponent("xray")
            engine.currentDirectoryURL = root
            engine.arguments = ["run", "-config", file.path]
            engine.standardInput = FileHandle.nullDevice
            engine.standardOutput = FileHandle.nullDevice
            engine.standardError = FileHandle.nullDevice
            try engine.run()
            process = engine
            underlayChild = engine
            underlayConfigPath = file
            underlayPort = port
            var ready = false
            for _ in 0..<25 where engine.isRunning {
                if portListening(port) && portListening(port + 1) { ready = true; break }
                try? await Task.sleep(for: .milliseconds(150))
            }
            guard ready else { throw HarborProxyError.invalid("底座代理无法启动，请先检查普通节点") }
        } catch {
            if let process, !(await HarborProxyCommand.stop(process)) { throw error }
            underlayChild = nil
            underlayConfigPath = nil
            underlayPort = nil
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
        (node.protocolName == "openvpn" || HarborIndependentWARP.isBuiltIn(node))
            ? mihomoInstalled : coreInstalled
    }

    private func availableCores() -> (HarborProxyNode) -> Bool {
        let ordinary = coreInstalled
        let openVPN = mihomoInstalled
        return { $0.protocolName == "openvpn" ? openVPN : ordinary }
    }

    /// Restores the packaged runtime without downloading or changing system proxy.
    func installBundledXray() async {
        guard configurationLoaded, !busy, !latencyTesting, !exitGeoUpdating, !exitGeoCleaningUp,
              !installingCore, !running, child == nil, !connectionTransition, !bootstrapping,
              !HarborSystemProxy.hasBackup,
              !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
            detail = "请先清理连接，等后台操作结束后再修复内核"
            return
        }
        await prepareBundledRuntimes(repair: true)
    }

    private func prepareBundledRuntimes(repair: Bool = false) async {
        guard !busy, !running, !installingCore, !shuttingDownConnection else { return }
        busy = true
        installingCore = true
        if repair { detail = "正在从安装包校验并修复内核" }
        defer {
            busy = false
            installingCore = false
        }
        let root = root
        let hadXray = coreInstalled
        let hadMihomo = mihomoInstalled
        let result = await Task.detached(priority: .utility) { () -> (changed: Bool, failures: [String]) in
            var changed = false
            var failures: [String] = []
            do {
                let source = try HarborXrayInstaller.bundledSource()
                if repair || !HarborXrayInstaller.matchesBundle(at: root, source: source) {
                    _ = try HarborXrayInstaller.installBundled(into: root, source: source)
                    changed = true
                }
            } catch where !hadXray || repair {
                failures.append("Xray：" + error.localizedDescription)
            } catch {
                if (try? HarborXrayInstaller.bundledSource()) != nil {
                    failures.append("Xray 升级失败，保留原版本")
                }
            }
            do {
                let source = try HarborMihomoInstaller.bundledSource()
                if repair || !HarborMihomoInstaller.matchesBundle(at: root, source: source) {
                    try HarborMihomoInstaller.installBundled(into: root, source: source)
                    changed = true
                }
            } catch where !hadMihomo || repair {
                failures.append("Mihomo：" + error.localizedDescription)
            } catch {
                if (try? HarborMihomoInstaller.bundledSource()) != nil {
                    failures.append("Mihomo 升级失败，保留原版本")
                }
            }
            do { try HarborMihomoInstaller.prepareDataDirectory(root: root) }
            catch { failures.append("Mihomo 地区资源暂不可用") }
            return (changed, failures)
        }.value
        if !result.failures.isEmpty {
            detail = result.failures.joined(separator: "；")
        } else if repair || result.changed {
            detail = "已校验并准备好内置 Xray 和 Mihomo"
        }
    }
    /// Reconcile the persisted ownership snapshot immediately before a node
    /// operation. If another client (for example v2rayN) has replaced every
    /// Harbor listener, discard only Harbor's marker and leave that proxy
    /// untouched. If macOS still points to Harbor, preserve the listener while
    /// the core reloads so network access is never cut mid-switch.
    private func prepareSystemProxyForActivation() async -> Bool? {
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
        do {
            try await HarborSystemProxy.restore()
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
            Task { @MainActor [weak self] in
                self?.refreshSystemProxyState(synchronizeOwnership: true)
                self?.refreshProbeNetwork()
            }
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

    private func refreshProbeNetwork() {
        guard configurationLoaded, let route = HarborSystemProxy.currentNetworkFingerprintInput() else { return }
        let key = Data(SHA256.hash(data: Data(route.utf8))).base64EncodedString()
        guard store.probeNetworkFingerprint != key else { return }
        if store.probeNetworkFingerprint != nil {
            probeNetworkChangedAt = .now
            cancelLatencyTests()
            cancelAllExitGeoWork()
            nodeServerResolvedAt.removeAll()
            scheduleGeoIPRefresh()
            if running { lastActiveHealthCheckAt = nil }
        }
        store.probeNetworkFingerprint = key
        persist()
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
        persistence = HarborProxyStateFile(
            url: root.appendingPathComponent("proxy-settings-v2.enc"), emptyState: HarborProxyState(),
            legacyState: HarborProxyKeychain.loadLegacy, keyProvider: HarborProxyKeychain.encryptionKey
        )
    }

    func retryConfigurationLoad() async {
        await bootstrap(retryConfiguration: true)
        await refreshCommunitySourcesIfNeeded()
    }

    func bootstrap(retryConfiguration: Bool = false) async {
        guard !bootstrapped, !bootstrapping,
              retryConfiguration || configurationLoadError == nil else { return }
        NSLog("HarborProxy lifecycle: bootstrap entered")
        bootstrapping = true
        defer { bootstrapping = false }
        startSystemProxyMonitoring()
        refreshSystemProxyState(synchronizeOwnership: true)
        let probeRoot = root
        await HarborWARPTunnel.cleanupOrphans(root: probeRoot)
        await HarborProbeFiles.cleanOrphans(root: probeRoot)
        if !configurationLoaded {
            configurationLoadError = nil
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
                subscriptionUpdatedAt = state.subscriptionUpdatedAt ?? [:]
                probeNetworkChangedAt = state.probeNetworkChangedAt ?? .distantPast
                selectedID = state.selectedID
                vpnGateUnderlayNodeID = state.vpnGateUnderlayNodeID
                routingRules = state.routingRules
                autoManageSystemProxy = state.autoManageSystemProxy ?? true
                resumeConnectionOnLaunch = state.resumeConnectionOnLaunch ?? HarborSystemProxy.hasBackup
                configuredHTTPPort = (try? HarborProxyPortPolicy.validate(
                    httpPort: state.httpListenPort ?? HarborProxyPortPolicy.defaultHTTPPort
                )) ?? HarborProxyPortPolicy.defaultHTTPPort
                forcedProxyDomains = (try? HarborProxyDomainRules.normalized(
                    state.forcedProxyDomains ?? HarborProxyDomainRules.defaults
                )) ?? HarborProxyDomainRules.defaults
                let favorites = favoriteNodeIDs
                let distinct = HarborProxyNodeDeduplication.coalesce(
                    nodes, withinSubscriptions: true
                ) { node in
                    if node.id == selectedID { return 8 }
                    if node.id == vpnGateUnderlayNodeID { return 4 }
                    if favorites.contains(node.id) { return 2 }
                    return probeResults[node.id]?.succeeded == true ? 1 : 0
                }
                let removedDuplicates = distinct.nodes.count < nodes.count
                if removedDuplicates {
                    mergeDuplicateMetadata(distinct.replacementIDs, keeping: distinct.nodes)
                    nodes = distinct.nodes
                }
                // Built-in WARP requires no subscriptions and is not auto-selected.
                nodes.removeAll {
                    $0.id == HarborIndependentWARP.nodeID &&
                    !HarborIndependentWARP.isBuiltIn($0)
                }
                if !nodes.contains(where: HarborIndependentWARP.isBuiltIn) {
                    nodes.append(HarborIndependentWARP.node)
                }
                configurationLoaded = true
                refreshProbeNetwork()
                var namesChanged = false
                for subscription in subscriptions {
                    namesChanged = refreshAutomaticNames(for: subscription.id) || namesChanged
                }
                if namesChanged || removedDuplicates { persist() }
            } catch let error as HarborProxyError {
                configurationLoadError = error.localizedDescription
                return
            } catch {
                configurationLoadError = "代理配置暂时无法读取，原文件已保留。"
                return
            }
        }
        startSystemProxyMonitoring()
        refreshSystemProxyState(synchronizeOwnership: true)
        startupTrace("bootstrap-entered")
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
                    try await HarborSystemProxy.restore()
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
        if await adoptExistingXray() {
            refreshSystemProxyState()
            pruneRetiredProfiles(keeping: [activeNodeID, vpnGateUnderlayNodeID])
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
        await prepareBundledRuntimes()
        pruneRetiredProfiles(keeping: resumeConnectionOnLaunch ? [selectedID, vpnGateUnderlayNodeID] : [])
        bootstrapped = true
        startupTrace("starting-selected-node")
        NSLog("HarborProxy lifecycle: cleanup complete, resuming selected node")
        // Restore the user's last active node *and* prior system-proxy intent.
        // Automatic system changes are always noninteractive and never take
        // over a proxy managed by another app.
        if !pendingActivation.hasPending, resumeConnectionOnLaunch,
           let selectedNode, supportsCore(for: selectedNode) {
            await queueActivation(selectedNode.id, restart: false, userInitiated: false)
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
        measurementScope.verifiedExit(nodeExitLocations[node.id], for: node, resolvedIP: entranceLocation(for: node)?.ip)
    }

    func serverLocation(for node: HarborProxyNode) -> HarborProxyIPLocation? {
        exitLocation(for: node) ?? entranceLocation(for: node)
    }

    func entranceLocation(for node: HarborProxyNode) -> HarborProxyIPLocation? {
        nodeServerLocations[node.host.lowercased()]
    }

    func observedExit(for node: HarborProxyNode) -> HarborProxyIPLocation? {
        guard let observation = nodeExitLocations[node.id],
              node.id != activeNodeID || observation.probeRouteID == currentVPNGateRouteID else { return nil }
        return observation.observedLocation(for: node, resolvedServerIP: entranceLocation(for: node)?.ip)
    }

    func networkEvidence(for node: HarborProxyNode) -> HarborProxyNetworkEvidence? {
        guard node.protocolName == "openvpn", let evidence = nodeNetworkEvidence[node.host],
              evidence.isFresh() else { return nil }
        return evidence
    }

    /// Resolve a bounded set of server addresses without keeping the workspace busy.
    /// VPN Gate advertises its origin, so it does not consume this provider's quota.
    private func scheduleGeoIPRefresh() {
        geoRefreshTask?.cancel()
        guard configurationLoaded else { return }
        let groups = Dictionary(grouping: nodes.filter {
            $0.protocolName != "openvpn" && !HarborIndependentWARP.isBuiltIn($0)
        }) { $0.host.lowercased() }
        let currentHosts = Set(groups.keys)
        nodeServerResolvedAt = nodeServerResolvedAt.filter { currentHosts.contains($0.key) }
        let locations = nodeServerLocations.filter { currentHosts.contains($0.key) }
        if locations.count != nodeServerLocations.count { nodeServerLocations = locations }
        let gateHosts = Set(nodes.lazy.filter { $0.protocolName == "openvpn" }.map(\.host))
        let evidence = nodeNetworkEvidence.filter { gateHosts.contains($0.key) }
        if evidence.count != nodeNetworkEvidence.count { nodeNetworkEvidence = evidence }
        let activeHost = activeNode?.host.lowercased()
        let now = Date.now
        let candidates = currentHosts.filter { host in
            guard !host.isEmpty else { return false }
            let cacheInterval = locations[host]?.countryIsFresh(now: now) == true
                ? HarborProxyGeoIPPolicy.serverDNSCacheInterval : 5 * 60
            return nodeServerResolvedAt[host].map { now.timeIntervalSince($0) >= cacheInterval } ?? true
        }.sorted { lhs, rhs in
            if lhs == activeHost || rhs == activeHost { return lhs == activeHost && rhs != activeHost }
            let left = nodeServerResolvedAt[lhs] ?? .distantPast
            let right = nodeServerResolvedAt[rhs] ?? .distantPast
            return left == right ? lhs < rhs : left < right
        }.prefix(24)
        guard !candidates.isEmpty else { return }
        geoRefreshTask = Task(priority: .utility) { [weak self] in
            var byIP = [String: String]()
            for location in locations.values where location.countryIsFresh(now: now) {
                if let country = location.verifiedCountryCode { byIP[location.ip] = country }
            }
            var failedIPs = Set<String>()
            var renamed = Set<String>()
            var changed = false
            let deadline = ContinuousClock.now + .seconds(90)
            for host in candidates {
                guard !Task.isCancelled, ContinuousClock.now < deadline, let self else { break }
                let result = await HarborNodeGeoIPResolver.resolvedIP(for: host)
                guard !Task.isCancelled else { break }
                self.nodeServerResolvedAt[host] = .now
                changed = true
                guard let resolvedIP = result, let profiles = groups[host] else { continue }
                if let existing = self.nodeServerLocations[host],
                   existing.matches(resolvedIP), existing.countryIsFresh() { continue }
                if let existing = self.nodeServerLocations[host], !existing.matches(resolvedIP) {
                    self.nodeServerLocations.removeValue(forKey: host)
                    for node in profiles {
                        self.probeResults.removeValue(forKey: node.id)
                        self.nodeExitLocations.removeValue(forKey: node.id)
                    }
                    renamed.formUnion(profiles.map(\.subscriptionID).filter { !$0.isEmpty })
                }
                var country = byIP[resolvedIP]
                if country == nil && !failedIPs.contains(resolvedIP) {
                    country = await HarborNodeGeoIPResolver.countryCode(
                        for: resolvedIP, proxyPort: self.running && self.healthy ? self.localPort : nil)
                    if let country { byIP[resolvedIP] = country }
                    else { failedIPs.insert(resolvedIP) }
                    try? await Task.sleep(for: .milliseconds(1100))
                }
                guard !Task.isCancelled, let country else { continue }
                self.nodeServerLocations[host] = HarborProxyIPLocation(ip: resolvedIP, countryCode: country)
                renamed.formUnion(profiles.map(\.subscriptionID).filter { !$0.isEmpty })
            }
            guard !Task.isCancelled, changed, let self else { return }
            for id in renamed { self.refreshAutomaticNames(for: id) }
            self.persist()
        }
    }

    private func persist() {
        guard configurationLoaded else { return }
        store.nodes = nodes
        if let endpoints = store.warpProbeEndpoints {
            let validIDs = Set(nodes.map(\.id))
            store.warpProbeEndpoints = endpoints.filter { validIDs.contains($0.key) }
        }
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
        store.resumeConnectionOnLaunch = resumeConnectionOnLaunch
        store.subscriptionUpdatedAt = subscriptionUpdatedAt
        store.probeNetworkChangedAt = probeNetworkChangedAt
        persistenceGeneration += 1
        pendingSave = (store, persistenceGeneration)
        guard persistenceTask == nil else { return }
        persistenceTask = Task { [weak self] in
            guard let self else { return }
            defer { persistenceTask = nil }
            while let next = pendingSave {
                pendingSave = nil
                do {
                    try await persistence.save(next.state, generation: next.generation)
                    configurationSaveError = nil
                } catch {
                    configurationSaveError = "代理配置未能保存，原文件已保留。"
                }
            }
        }
    }

    func retryConfigurationSave() {
        persist()
    }

    func setResumeConnectionOnLaunch(_ enabled: Bool) {
        guard configurationLoaded else { return }
        resumeConnectionOnLaunch = enabled
        persist()
    }

    func flushConfigurationBeforeQuit() async {
        // Saving can be waiting on Keychain. Give disk writes a short window
        // after network recovery without holding the app open for approval.
        let deadline = ContinuousClock.now + .seconds(1)
        while persistenceTask != nil, ContinuousClock.now < deadline, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(40))
        }
    }

    /// Explicit listener-port change. Never switch to a free fallback port.
    /// When macOS proxy was managed, restore it before stopping the old Xray,
    /// then enable it only after the new listener passes the proxy health probe.
    func updateHTTPPort(_ requestedPort: Int) async throws {
        let port = try HarborProxyPortPolicy.validate(httpPort: requestedPort)
        guard configurationLoaded, !busy, !latencyTesting, !installingCore, !requiresRecovery,
              !connectionTransition, !activationInProgress, !shuttingDownConnection else {
            throw HarborProxyError.invalid("当前有其他代理操作或系统代理待恢复，请完成后再更改端口")
        }
        guard port != configuredHTTPPort else { return }
        guard !portListening(port), !portListening(port + 1) else {
            throw HarborProxyError.invalid("端口 \(port) 或 \(port + 1) 已被占用，请选择其他端口；原有连接不会中断")
        }

        guard running, let activeNodeID else {
            guard !running else { throw HarborProxyError.invalid("无法识别当前运行的节点") }
            configuredHTTPPort = port
            persist()
            detail = "监听端口已设为 HTTP \(port) / SOCKS5 \(port + 1)，下次连接生效"
            return
        }
        switchingNodeID = activeNodeID
        defer { if !activationInProgress { switchingNodeID = nil } }
        await activateOne(activeNodeID, restart: true, userInitiated: false, replacementPort: port)
        guard localPort == port, configuredHTTPPort == port, healthy else {
            throw HarborProxyError.invalid("端口切换失败：" + detail)
        }
        detail = "端口切换成功：HTTP \(port) / SOCKS5 \(port + 1)"
    }

    func updateForcedProxyDomains(_ domains: [String]) throws {
        // Tests keep a snapshot of the routing rules, so editing the next
        // connection's rules is safe even while a probe batch is winding down.
        guard configurationLoaded, !busy else {
            throw HarborProxyError.invalid("代理正在执行其他操作，请稍后修改规则")
        }
        forcedProxyDomains = try HarborProxyDomainRules.normalized(domains)
        persist()
        detail = running ? "站点规则已保存；重新连接当前节点后生效" : "站点规则已保存，下次连接生效"
    }

    /// Read legacy v2rayN profiles without replacing the packaged engine.
    func migrateV2rayN() async {
        guard configurationLoaded, !busy, !running, !latencyTesting, !connectionTransition,
              !shuttingDownConnection, child == nil, !HarborSystemProxy.hasBackup else {
            detail = "检测到正在运行或待清理的代理，请先关闭代理再导入"
            return
        }
        busy = true
        defer { busy = false }
        let source = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN")
        do {
            let imported = try await Task.detached(priority: .utility) { try HarborV2rayNReader.read(at: source) }.value
            try Task.checkCancellation()
            guard !shuttingDownConnection else { throw CancellationError() }
            guard !imported.nodes.isEmpty else { throw HarborProxyError.invalid("没有可迁移的受支持节点") }
            let merged = HarborProxyImportMerger.merge(
                currentNodes: nodes, currentSubscriptions: subscriptions,
                selectedID: selectedID, imported: imported
            )
            try validateCatalogSize(nodes: merged.nodes.count, subscriptions: merged.subscriptions.count)
            nodes = merged.nodes
            subscriptions = merged.subscriptions
            selectedID = merged.selectedID
            scheduleGeoIPRefresh()
            persist()
            detail = "迁移成功：\(imported.nodes.count) 个节点、\(imported.subscriptions.count) 条订阅；\(imported.unsupportedCount) 条非支持类型未导入。原 v2rayN 配置未修改。"
        } catch { detail = "迁移失败：" + error.localizedDescription }
    }

    private func validateCatalogSize(nodes nodeCount: Int, subscriptions subscriptionCount: Int) throws {
        // Existing catalogs above the limits can still be refreshed or reduced.
        guard nodeCount <= max(nodes.count, 12_000), subscriptionCount <= max(subscriptions.count, 200) else {
            throw HarborProxyError.invalid("节点或订阅已达本机上限，请先移除不需要的订阅或节点")
        }
    }

    @discardableResult
    func addLinks(_ value: String) async -> Bool {
        guard configurationLoaded, !busy, !connectionTransition, !shuttingDownConnection,
              value.utf8.count <= 2_000_000 else {
            detail = "请等待当前操作结束；单次导入内容不能超过 2 MB"
            return false
        }
        busy = true
        defer { busy = false }
        let existing = nodes
        let (parsed, additions) = await Task.detached(priority: .utility) {
            let parsed = HarborProxyLinks.parseReport(value)
            return (parsed, HarborProxyNodeDeduplication.newNodes(parsed.nodes, excluding: existing))
        }.value
        guard !Task.isCancelled, !shuttingDownConnection else { return false }
        let duplicates = parsed.nodes.count - additions.count
        guard !parsed.nodes.isEmpty else { detail = "未找到有效节点链接"; return false }
        guard !additions.isEmpty else {
            detail = "节点已存在，已跳过 \(duplicates) 个重复节点"
            return false
        }
        do { try validateCatalogSize(nodes: nodes.count + additions.count, subscriptions: subscriptions.count) }
        catch { detail = error.localizedDescription; return false }
        nodes += additions
        if selectedID == nil { selectedID = additions[0].id }
        scheduleGeoIPRefresh()
        persist()
        detail = "已导入 \(additions.count) 个节点"
            + (duplicates > 0 ? "；已跳过 \(duplicates) 个重复节点" : "")
            + (parsed.rejected > 0 ? "；已跳过 \(parsed.rejected) 条无效或超出限制的配置" : "")
        return true
    }

    func addSubscription(name: String, url: String) -> Bool {
        guard configurationLoaded, !busy, !connectionTransition, !shuttingDownConnection else {
            detail = "请等待当前代理操作结束后再添加订阅"
            return false
        }
        do {
            try validateCatalogSize(nodes: nodes.count, subscriptions: subscriptions.count + 1)
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
        guard configurationLoaded, !busy, !latencyTesting, !connectionTransition, !shuttingDownConnection else {
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
                let incoming = try await downloadSubscriptionNodes(from: sourceURL, id: id)
                try Task.checkCancellation()
                guard !shuttingDownConnection, let current = subscriptions.firstIndex(where: { $0.id == id })
                else { throw CancellationError() }
                let update = try applySubscriptionNodes(incoming.nodes, id: id)
                subscriptions[current] = updated
                refreshAutomaticNames(for: id)
                let refreshed = nodes.filter { $0.subscriptionID == id }
                let testCount = refreshed.filter { probeResults[$0.id]?.realTested != true }.count
                scheduleGeoIPRefresh()
                persist()
                busy = false
                // Import and refresh never start an unrequested batch probe.
                // New or changed nodes are shown as 未测速 until the user tests.
                detail = "订阅「\(updated.name)」已保存并更新 \(update.count) 个节点；待测速 \(testCount) 个"
                    + update.duplicateSummary + incoming.rejectedSummary +
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
        guard configurationLoaded, let index = nodes.firstIndex(where: { $0.id == id }) else {
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
        guard configurationLoaded, let index = nodes.firstIndex(where: { $0.id == id }),
              nodes[index].customName != nil else { return }
        nodes[index].customName = nil
        persist()
        detail = nodes[index].automaticName == nil
            ? "已恢复订阅名称「\(nodes[index].name)」"
            : "已恢复自动名称「\(nodes[index].displayName)」"
    }
    @discardableResult
    func removeSubscription(_ id: String) -> Bool {
        guard configurationLoaded, !busy, !latencyTesting, !connectionTransition, !shuttingDownConnection else {
            detail = "请等待当前操作结束后再删除订阅"
            return false
        }
        guard let subscription = subscriptions.first(where: { $0.id == id }) else { return false }
        let matching = nodes.filter { $0.subscriptionID == id }
        if matching.contains(where: { isInUse($0.id) }) {
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
        guard configurationLoaded, !busy, !latencyTesting, !connectionTransition, !shuttingDownConnection,
              let subscription = subscriptions.first(where: { $0.id == id }),
              let url = URL(string: subscription.url) else { return }
        busy = true
        defer { busy = false }
        detail = "正在下载订阅「\(subscription.name)」"
        do {
            let incoming = try await downloadSubscriptionNodes(from: url, id: id)
            try Task.checkCancellation()
            guard !shuttingDownConnection else { throw CancellationError() }
            let update = try applySubscriptionNodes(incoming.nodes, id: id)
            refreshAutomaticNames(for: id)
            let testCount = nodes.filter {
                $0.subscriptionID == id && probeResults[$0.id]?.realTested != true
            }.count
            scheduleGeoIPRefresh()
            persist()
            // Don't silently test the full subscription after refresh.
            detail = "订阅更新完成：\(update.count) 个节点；待测速 \(testCount) 个"
                + update.duplicateSummary + incoming.rejectedSummary +
                (update.retainedActive ? "；原连接仍在运行，请手动选择最新节点" : "")
        } catch {
            detail = "订阅「\(subscription.name)」更新失败，已保留原节点：" + error.localizedDescription
        }
    }

    /// Refresh publisher-provided feeds on opening the proxy workspace, never
    /// switching the active node or silently testing an unlimited feed.
    func refreshCommunitySourcesIfNeeded() async {
        while bootstrapping && !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard configurationLoaded, !Task.isCancelled else { return }
        for subscription in subscriptions {
            guard HarborProxyCommunitySource.matching(subscription.url) == .vpnGate else { continue }
            if let updated = subscriptionUpdatedAt[subscription.id],
               Date.now.timeIntervalSince(updated) < 6 * 60 * 60 { continue }
            guard !busy, !latencyTesting else { return }
            // Refresh feed metadata only. Never start a 24-node VPN Gate probe
            // merely because the user opened the network proxy workspace.
            await refreshSubscription(subscription.id)
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
        let hasCore = availableCores()
        let eligible = nodes.filter { $0.subscriptionID == id && hasCore($0) }
        let candidates = source == .vpnGate
            ? HarborVPNGateProbePolicy.select(
                nodes: eligible, evidence: nodeNetworkEvidence,
                results: probeResults, limit: 24,
                probeRouteID: vpnGateProbeRouteID,
                acceptedSuccessfulIDs: Set(eligible.compactMap { node in
                    probeResults[node.id].map { isUsable($0, for: node) } == true ? node.id : nil
                }))
            : Array(eligible.prefix(20))
        guard !candidates.isEmpty else { return }
        await testRealLatency(candidates.map(\.id))
        refreshExitLocations(for: candidates.compactMap { node in
            probeResults[node.id].map { isUsable($0, for: node) } == true ? node.id : nil
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
        var lastSourceFailure: String?
        var lastSourceResult: String?
        for subscription in sources {
            guard !Task.isCancelled else { return }
            let previousUpdate = subscriptionUpdatedAt[subscription.id]
            await refreshCommunitySubscription(subscription.id)
            if subscriptionUpdatedAt[subscription.id] == previousUpdate {
                failedSources += 1
                lastSourceFailure = detail
            } else {
                lastSourceResult = detail
            }
        }
        if failedSources == sources.count {
            detail = "筛选未完成：" + (lastSourceFailure ?? "独立通道或节点来源暂时不可用") + "；已保留旧列表"
            return
        }
        let gateIDs = Set(subscriptions.filter {
            HarborProxyCommunitySource.matching($0.url) == .vpnGate
        }.map(\.id))
        let gateNodes = nodes.filter { gateIDs.contains($0.subscriptionID) }
        let home = gateNodes.filter { networkEvidence(for: $0)?.kind == .residential }
        let usableHome = home.filter { node in
            probeResults[node.id].map { isUsable($0, for: node) } == true
        }.count
        detail = "已加载 \(gateNodes.count) 个志愿候选，\(home.count) 个家宽入口，\(usableHome) 个家宽入口测速通过" +
            (lastSourceResult.map { "；\($0)" } ?? "") +
            (failedSources > 0 ? "；\(failedSources) 个来源获取失败，旧列表已保留" : "")
    }

    /// Both refresh and changed-URL edits use the same validation and parsing.
    private struct DownloadedSubscription: Sendable {
        let nodes: [HarborProxyNode]
        let rejected: Int

        var rejectedSummary: String {
            rejected == 0 ? "" : "；已跳过 \(rejected) 条无效、不支持或超出上限的配置"
        }
    }

    private func downloadSubscriptionNodes(from url: URL, id: String) async throws -> DownloadedSubscription {
        do {
            return try await downloadSubscriptionNodesOnce(from: url, id: id)
        } catch {
            try Task.checkCancellation()
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

    private func downloadSubscriptionNodesOnce(from url: URL, id: String) async throws -> DownloadedSubscription {
        if HarborProxyCommunitySource.matching(url.absoluteString) == .vpnGate {
            return DownloadedSubscription(nodes: try await downloadVPNGateNodes(from: url, id: id), rejected: 0)
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = url.host == "api.github.com" ? 8 : 20
        if url.host == "api.github.com" { request.setValue("CodexHarbor", forHTTPHeaderField: "User-Agent") }
        let activeProxyPort = running && healthy ? localPort : nil
        let configuration = HarborProxyHTTP.configuration(httpPort: activeProxyPort)
        let text = try await fetchSubscriptionText(request, configuration: configuration)
        let parsed = await Task.detached(priority: .utility) { HarborProxyLinks.parseReport(text) }.value
        guard !parsed.nodes.isEmpty else {
            throw HarborProxyError.invalid("订阅没有可识别的节点，已拒绝清空旧列表")
        }
        return DownloadedSubscription(nodes: parsed.nodes.map { original in
            var node = original
            node.subscriptionID = id
            return node
        }, rejected: parsed.rejected)
    }

    private func fetchSubscriptionText(
        _ request: URLRequest, configuration: URLSessionConfiguration,
        cancellation: HarborLatencyCancellation? = nil
    ) async throws -> String {
        guard let lease = await HarborProbeBudget.requests.acquire(cancellation) else { throw CancellationError() }
        let load = Task {
            try await HarborProxyHTTPBody.data(
                for: request, configuration: configuration, limit: 2_000_000,
                timeout: min(20, request.timeoutInterval), status: 200..<201)
        }
        let observer = cancellation?.observe { load.cancel() }
        defer {
            if let observer { cancellation?.removeObserver(observer) }
        }
        let response = await withTaskCancellationHandler {
            await load.result
        } onCancel: {
            load.cancel()
        }
        await HarborProbeBudget.requests.release(lease)
        let (data, _) = try response.get()
        let text = request.url?.host == "api.github.com"
            ? HarborProxyCommunitySource.decodedAPIContents(data)
            : String(data: data, encoding: .utf8)
        guard let text else { throw HarborProxyError.invalid("订阅内容无法解码") }
        return text
    }

    private func downloadVPNGateNodes(from url: URL, id: String) async throws -> [HarborProxyNode] {
        let cancellation = HarborLatencyCancellation()
        vpnGateDownloadCancellation = cancellation
        defer { vpnGateDownloadCancellation = nil }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20

        func fetch(httpPort: Int?) async throws -> [HarborProxyNode] {
            let text = try await fetchSubscriptionText(
                request, configuration: HarborProxyHTTP.configuration(httpPort: httpPort),
                cancellation: cancellation)
            let nodes = await Task.detached(priority: .utility) {
                HarborVPNGate.parse(text, subscriptionID: id)
            }.value
            guard !nodes.isEmpty else {
                throw HarborProxyError.invalid("VPN Gate 名单没有可识别的节点")
            }
            return nodes
        }

        let activeProxyPort = running && healthy ? localPort : nil
        var candidates: [HarborProxyNode] = []
        var usedProxyPort: Int?
        var source = "direct"
        var tunnel: HarborWARPTunnel?
        var lastFailure = "独立通道或节点来源暂时不可用"
        detail = "正在准备独立通道获取 VPN Gate 名单"
        do {
            let independent = try await prepareIndependentVPNGateTunnel(cancellation: cancellation)
            tunnel = independent
            candidates = try await fetch(httpPort: independent.httpPort)
            usedProxyPort = independent.httpPort
            source = "warp"
        } catch {
            lastFailure = error.localizedDescription
            await tunnel?.close()
            tunnel = nil
        }
        if candidates.isEmpty {
            for port in activeProxyPort.map({ [Optional($0), nil] }) ?? [nil] {
                guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                do {
                    candidates = try await fetch(httpPort: port)
                    usedProxyPort = port
                    source = port == nil ? "direct" : "underlay"
                    break
                } catch { lastFailure = error.localizedDescription }
            }
        }
        guard !candidates.isEmpty else {
            await tunnel?.close()
            throw HarborProxyError.invalid("无法获取 VPN Gate 名单：" + lastFailure)
        }
        detail = "已获取 \(candidates.count) 个志愿候选，正在预筛入口"
        let ranked = await HarborVPNGatePortScanner.rank(
            candidates, socksPort: usedProxyPort.map { $0 + 1 }, cancellation: cancellation)
        detail = "正在识别家宽入口类型"
        let classification = HarborLatencyCancellation()
        let observer = cancellation.observe { classification.cancel() }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(120)) } catch { return }
            classification.cancel()
        }
        let evidence = await HarborVPNGateNetworkClassifier.classify(
            ranked, cached: nodeNetworkEvidence, proxyPort: usedProxyPort, cancellation: classification)
        deadline.cancel()
        if let observer { cancellation.removeObserver(observer) }
        await tunnel?.close()
        try Task.checkCancellation()
        guard !cancellation.isCancelled, !shuttingDownConnection else { throw CancellationError() }
        nodeNetworkEvidence.merge(evidence) { _, latest in latest }
        proxyAudit("vpngate_catalog", note: "route=\(source) candidates=\(ranked.count) classified=\(evidence.count) partial=\(classification.isCancelled)")
        return ranked
    }

    private var favoriteNodeIDs: Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.favoriteNodeIDsKey) ?? [])
    }

    private func mergeDuplicateMetadata(_ replacements: [String: String],
                                        keeping remaining: [HarborProxyNode]) {
        guard !replacements.isEmpty else { return }
        let favorites = favoriteNodeIDs
        let mergedFavorites = Set(favorites.map { replacements[$0] ?? $0 })
        if mergedFavorites != favorites {
            UserDefaults.standard.set(mergedFavorites.sorted(), forKey: Self.favoriteNodeIDsKey)
        }
        if let selectedID { self.selectedID = replacements[selectedID] ?? selectedID }
        if let vpnGateUnderlayNodeID {
            self.vpnGateUnderlayNodeID = replacements[vpnGateUnderlayNodeID] ?? vpnGateUnderlayNodeID
        }
        let byID = Dictionary(remaining.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for (removed, kept) in replacements {
            if let probe = probeResults.removeValue(forKey: removed),
               probeResults[kept] == nil {
                probeResults[kept] = probe
            }
            if let observation = nodeExitLocations.removeValue(forKey: removed),
               nodeExitLocations[kept] == nil,
               observation.endpointSignature == byID[kept]?.endpointSignature {
                nodeExitLocations[kept] = observation
            }
        }
    }

    /// No Xray restart is performed. Preserve matching profile IDs, aliases
    /// and favorites; retain an active endpoint removed by the provider until
    /// the user explicitly connects to a new profile.
    private struct SubscriptionNodeUpdate {
        let count: Int
        let retainedActive: Bool
        let duplicatesRemoved: Int

        var duplicateSummary: String {
            duplicatesRemoved > 0 ? "；已合并 \(duplicatesRemoved) 个重复节点" : ""
        }
    }

    private func applySubscriptionNodes(_ incoming: [HarborProxyNode], id: String) throws
        -> SubscriptionNodeUpdate {
        let previous = Dictionary(nodes.filter { $0.subscriptionID == id }.map {
            ($0.id, $0.endpointSignature)
        }, uniquingKeysWith: { first, _ in first })
        let merged = HarborProxySubscriptionReconciler.replace(
            current: nodes, incoming: incoming, subscriptionID: id,
            selectedID: activeNodeID ?? selectedID, keepActiveConnection: running,
            preferredNodeIDs: favoriteNodeIDs,
            protectedNodeIDs: Set([running && underlayPort != nil ? vpnGateUnderlayNodeID : nil].compactMap { $0 })
        )
        try validateCatalogSize(nodes: merged.nodes.count, subscriptions: subscriptions.count)
        mergeDuplicateMetadata(merged.replacementIDs, keeping: merged.nodes)
        let favorites = favoriteNodeIDs
        let rotatedFavorites = Set(favorites.map { merged.rotatedFavoriteIDs[$0] ?? $0 })
        if rotatedFavorites != favorites {
            UserDefaults.standard.set(rotatedFavorites.sorted(), forKey: Self.favoriteNodeIDsKey)
        }
        let byID = Dictionary(merged.nodes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let validIDs = Set(byID.keys)
        let changedIDs = Set(merged.nodes.compactMap { node in
            previous[node.id].map { $0 != node.endpointSignature } == true ? node.id : nil
        })
        store.retainedRuntimeNodeIDs = (store.retainedRuntimeNodeIDs ?? []).union(
            merged.nodes.compactMap { node in
                node.subscriptionID.isEmpty && previous[node.id] != nil ? node.id : nil
            }
        )
        nodes = merged.nodes
        selectedID = merged.selectedID
        probeResults = probeResults.filter { validIDs.contains($0.key) && !changedIDs.contains($0.key) }
        exitGeoFailureCounts = exitGeoFailureCounts.filter { validIDs.contains($0.key) && !changedIDs.contains($0.key) }
        exitGeoAttemptedAt = exitGeoAttemptedAt.filter { validIDs.contains($0.key) && !changedIDs.contains($0.key) }
        exitGeoPendingIDs = exitGeoPendingIDs.filter { validIDs.contains($0) }
        nodeExitLocations = nodeExitLocations.filter { id, observation in
            byID[id]?.endpointSignature == observation.endpointSignature
        }
        store.warpProbeEndpoints = store.warpProbeEndpoints?.filter { !changedIDs.contains($0.key) }
        subscriptionUpdatedAt[id] = .now
        let count = merged.nodes.filter { $0.subscriptionID == id }.count
        return SubscriptionNodeUpdate(
            count: count,
            retainedActive: merged.retainedActiveNode,
            duplicatesRemoved: max(0, incoming.count - count)
        )
    }

    private func pruneRetiredProfiles(keeping activeIDs: [String?]) {
        guard let retained = store.retainedRuntimeNodeIDs, !retained.isEmpty else { return }
        let keep = retained.intersection(activeIDs.compactMap { $0 })
        let drop = retained.subtracting(keep)
        guard !drop.isEmpty else { return }
        store.retainedRuntimeNodeIDs = keep
        nodes.removeAll { drop.contains($0.id) && $0.subscriptionID.isEmpty }
        let ids = Set(nodes.map(\.id))
        for id in drop where !ids.contains(id) {
            probeResults.removeValue(forKey: id)
            nodeExitLocations.removeValue(forKey: id)
            exitGeoPendingIDs.remove(id)
            exitGeoAttemptedAt.removeValue(forKey: id)
            exitGeoFailureCounts.removeValue(forKey: id)
        }
        if let selectedID, !ids.contains(selectedID) { self.selectedID = nodes.first?.id }
        if let vpnGateUnderlayNodeID, !ids.contains(vpnGateUnderlayNodeID) { self.vpnGateUnderlayNodeID = nil }
        let favorites = favoriteNodeIDs
        let surviving = favorites.intersection(ids)
        if favorites != surviving { UserDefaults.standard.set(surviving.sorted(), forKey: Self.favoriteNodeIDsKey) }
        persist()
    }

    /// Explicit refresh of the selected node (also used when routing changes).
    func select(_ id: String) async {
        await queueActivation(id, restart: true, userInitiated: true)
    }

    func reapplyRouting() async {
        guard running, let activeNodeID else { return }
        await queueActivation(activeNodeID, restart: true, userInitiated: false)
    }

    /// All rows are selectable, including while a previous node is starting.
    /// The most recent click wins; no click is silently discarded due to busy.
    func activate(_ id: String) async {
        await queueActivation(id, restart: false, userInitiated: true)
    }

    private func queueActivation(_ id: String, restart: Bool, userInitiated: Bool) async {
        guard !shuttingDownConnection, configurationLoaded, nodes.contains(where: { $0.id == id }) else {
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
            while busy || installingCore || connectionTransition || (bootstrapping && !bootstrapped) {
                guard !shuttingDownConnection, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            // A newer click arrived while waiting for another operation.
            // Do not start an obsolete preflight or stop the active core.
            if shuttingDownConnection || Task.isCancelled { return }
            if pendingActivation.hasPending { continue }
            await activateOne(
                request.nodeID,
                restart: request.restart,
                userInitiated: request.userInitiated
            )
        }
    }

    private func activateOne(_ id: String, restart: Bool, userInitiated: Bool,
                             replacementPort: Int? = nil) async {
        guard let requestedNode = nodes.first(where: { $0.id == id }) else {
            detail = "所选节点已不存在"
            return
        }
        connectionTransition = true
        defer { connectionTransition = false }
        let cancellation = HarborLatencyCancellation()
        activationPreflightCancellation = cancellation
        defer { activationPreflightCancellation = nil }
        let previousUnderlayID = activeNode?.protocolName == "openvpn" && underlayPort != nil
            ? vpnGateUnderlayNodeID : nil
        let previousRoute = previousUnderlayID.map(VPNGateRoute.underlay)
            ?? activeWARPProfile.map(VPNGateRoute.warp) ?? .direct
        let previousPolicy = activePolicy
        let previousID = activeNodeID
        let previousPort = localPort ?? configuredHTTPPort
        let wasRunning = running
        let previousIntent = autoManageSystemProxy
        let wantsSystemProxy = HarborProxyConnectionIntent.shouldManageSystemProxy(
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
                if !systemManaged && wantsSystemProxy {
                    await applySystemProxy(interactive: userInitiated)
                }
                if userInitiated, !shuttingDownConnection, !cancellation.isCancelled {
                    setResumeConnectionOnLaunch(true)
                }
                return
            }
        }

        if (requestedNode.protocolName == "openvpn" ||
            HarborIndependentWARP.isBuiltIn(requestedNode)), !mihomoInstalled {
            detail = "Mihomo 内核未安装，原连接保持不变"
            return
        }

        guard supportsCore(for: requestedNode) else {
            detail = "当前节点的代理内核不可用，原连接未改变"
            return
        }
        let policy = await RoutingPolicy.read(ruleMode: routingRules, forcedDomains: forcedProxyDomains)
        let route: VPNGateRoute
        do {
            route = try await validateConnection(requestedNode, policy: policy, cancellation: cancellation)
        } catch {
            guard !cancellation.isCancelled, !shuttingDownConnection, !Task.isCancelled else { return }
            detail = (wasRunning ? "新节点验证失败，原连接保持不变：" : "节点验证失败：") + error.localizedDescription
            return
        }
        guard !pendingActivation.hasPending, !shuttingDownConnection, !cancellation.isCancelled,
              !Task.isCancelled, nodes.contains(where: {
                  $0.id == id && $0.endpointSignature == requestedNode.endpointSignature
              }) else { return }
        guard let wasManaged = await prepareSystemProxyForActivation(),
              !shuttingDownConnection, !cancellation.isCancelled else { return }
        autoManageSystemProxy = wantsSystemProxy
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
            route: route,
            policy: policy,
            requestedPort: replacementPort,
            preservingSystemProxy: wasManaged,
            cancellation: cancellation
        )
        if running && healthy && (wasManaged || wantsSystemProxy)
            && !shuttingDownConnection && !cancellation.isCancelled {
            await applySystemProxy(interactive: userInitiated, policy: policy, reconfigure: true)
        }
        if !running || !healthy || (wasManaged && !systemManaged) || cancellation.isCancelled {
            let failure = detail
            proxyAudit("switch_failed", nodeID: id)
            autoManageSystemProxy = previousIntent
            if running {
                guard await stopCore() else { return }
            }
            if !shuttingDownConnection, wasRunning, let previousID,
               nodes.contains(where: { $0.id == previousID }) {
                let rollbackPolicy: RoutingPolicy
                if let previousPolicy { rollbackPolicy = previousPolicy }
                else { rollbackPolicy = policy }
                await start(
                    nodeID: previousID,
                    route: previousRoute,
                    policy: rollbackPolicy,
                    requestedPort: previousPort,
                    preservingSystemProxy: wasManaged,
                    cancellation: nil
                )
                if running && healthy {
                    if wasManaged {
                        await applySystemProxy(interactive: false, policy: rollbackPolicy, reconfigure: true)
                    }
                    proxyAudit("rollback_restored", nodeID: previousID)
                    detail = "新节点连接失败：\(failure)；已恢复原连接"
                } else {
                    proxyAudit("rollback_failed", nodeID: previousID)
                    detail = "新节点连接失败：\(failure)；原连接恢复失败：" + detail
                }
            }
            if (!running || !healthy) && HarborSystemProxy.hasBackup {
                _ = try? await HarborSystemProxy.restore()
                refreshSystemProxyState(synchronizeOwnership: true)
            }
            return
        }

        configuredHTTPPort = localPort ?? configuredHTTPPort
        selectedID = id
        if userInitiated { resumeConnectionOnLaunch = true }
        pruneRetiredProfiles(keeping: [id, underlayPort == nil ? nil : vpnGateUnderlayNodeID])
        persist()
        if let activeNode, !HarborIndependentWARP.isBuiltIn(activeNode) {
            enqueueExitGeoRefresh(for: [activeNode])
        }

        proxyAudit("switch_listener_committed", nodeID: id)
        if wasManaged {
            // The unchanged system proxy already targets our fixed listener.
            if !HarborSystemProxy.isOwned() {
                systemManaged = false
                detail = "Xray 已切换，但系统代理被其他程序更改；未覆盖其配置"
            } else {
                detail = "已切换节点 · 系统代理端口保持不变"
            }
            refreshSystemProxyState()
        }
    }

    private func validateConnection(_ node: HarborProxyNode, policy: RoutingPolicy,
                                    cancellation: HarborLatencyCancellation) async throws -> VPNGateRoute {
        // Independent WARP is itself the outbound; never treat its placeholder
        // identity as a remote Xray server or a subscription node.
        if HarborIndependentWARP.isBuiltIn(node) {
            let tunnel = try await prepareIndependentVPNGateTunnel(cancellation: cancellation)
            let profile = tunnel.profile
            await tunnel.close()
            return .warp(profile)
        }
        guard node.protocolName == "openvpn" else {
            try await validateCandidate(node, policy: policy, cancellation: cancellation)
            return .direct
        }
        let previous = probeResults[node.id].flatMap { $0.succeeded && !$0.isStale() ? $0.probeRouteID : nil }
        let availableUnderlay = workingVPNGateUnderlay
        let underlay = availableUnderlay.flatMap { item in
            nodes.contains(where: { $0.id == item.nodeID }) ? item : nil
        }
        if let underlay, previous == underlay.routeID {
            if (try? await validateCandidate(node, policy: policy, underlayPort: underlay.socksPort - 1,
                                             cancellation: cancellation)) != nil {
                return .underlay(underlay.nodeID)
            }
        }
        if let cached = warpProfile(for: node), previous == cached.routeID,
           (try? await validateCandidate(node, policy: policy, warp: cached, cancellation: cancellation)) != nil {
            return .warp(cached)
        }
        if (try? await validateCandidate(node, policy: policy, cancellation: cancellation)) != nil {
            return .direct
        }
        guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        if let underlay, previous != underlay.routeID,
           (try? await validateCandidate(node, policy: policy, underlayPort: underlay.socksPort - 1,
                                         cancellation: cancellation)) != nil {
            return .underlay(underlay.nodeID)
        }
        let tunnel = try await prepareIndependentVPNGateTunnel(
            cancellation: cancellation, preferred: store.warpProbeEndpoints?[node.id])
        let profile = tunnel.profile
        await tunnel.close()
        try await validateCandidate(node, policy: policy, warp: profile, cancellation: cancellation)
        return .warp(profile)
    }

    private func validateCandidate(_ node: HarborProxyNode, policy: RoutingPolicy,
                                   underlayPort: Int? = nil, warp: HarborWARPProfile? = nil,
                                   cancellation: HarborLatencyCancellation) async throws {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        let root = root
        try await Self.runCandidate(node, root: root, policy: policy, underlayPort: underlayPort,
                                    warp: warp, cancellation: cancellation)
    }

    private nonisolated static func runCandidate(
        _ node: HarborProxyNode, root: URL, policy: RoutingPolicy, underlayPort: Int?,
        warp: HarborWARPProfile?, cancellation: HarborLatencyCancellation
    ) async throws {
        guard let lease = await HarborProbeBudget.engines.acquire(cancellation) else { throw CancellationError() }
        guard let port = HarborNodeLatencyTester.reservePortPair() else {
            await HarborProbeBudget.engines.release(lease)
            throw HarborProxyError.invalid("没有空闲的验证端口")
        }
        let file = root.appendingPathComponent("probe-\(UUID().uuidString).json")
        let engine = Process()
        let openVPN = node.protocolName == "openvpn"
        var failed: (any Error)?
        do {
            let config = try policy.configuration(for: node, port: port, underlayPort: underlayPort, warp: warp)
            try HarborProbeFiles.write(config, to: file)
            engine.executableURL = root.appendingPathComponent(openVPN ? "mihomo" : "xray")
            engine.currentDirectoryURL = root
            engine.arguments = openVPN
                ? ["-d", HarborMihomoInstaller.dataDirectory(root: root).path, "-f", file.path]
                : ["run", "-config", file.path]
            engine.standardInput = FileHandle.nullDevice
            engine.standardOutput = FileHandle.nullDevice
            engine.standardError = FileHandle.nullDevice
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
            try engine.run()
            HarborProbeFiles.record(engine, config: file)
            guard await HarborNodeLatencyTester.awaitListening(
                port: port, process: engine, cancellation: cancellation),
                await HarborNodeLatencyTester.awaitListening(
                    port: port + 1, process: engine, cancellation: cancellation) else {
                throw HarborProxyError.invalid("验证内核未能监听本地端口")
            }
            let reachable = openVPN
                ? await HarborMihomoLatencyTester.checkActiveSOCKS(port: port + 1, cancellation: cancellation)
                : await HarborNodeLatencyTester.checkActiveHTTP(port: port, cancellation: cancellation)
            guard reachable, engine.isRunning, !cancellation.isCancelled else {
                throw HarborProxyError.invalid("该线路未完成真实 HTTPS 验证")
            }
        } catch { failed = error }
        if await HarborProxyCommand.stop(engine) {
            HarborProbeFiles.remove(file)
            HarborNodeLatencyTester.releasePortPair(port)
            await HarborProbeBudget.engines.release(lease)
        } else {
            throw HarborProxyError.invalid("验证内核未退出，已保留其清理记录")
        }
        if let failed { throw failed }
    }

    /// The visible 'clear proxy' action never silently deletes another
    /// application's system settings or node/subscription configurations.
    func clearProxy(interactive: Bool = false) async {
        setResumeConnectionOnLaunch(false)
        if running || child != nil || underlayChild != nil || adoptedPID != nil
            || HarborSystemProxy.hasBackup || connectionTransition || activationInProgress
            || FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
            if await stop(interactive: interactive) {
                resumeConnectionOnLaunch = false
                autoManageSystemProxy = false
                pruneRetiredProfiles(keeping: [])
                persist()
            }
        } else {
            autoManageSystemProxy = false
            pruneRetiredProfiles(keeping: [])
            persist()
            detail = "Harbor 当前没有启用代理；其他程序的系统代理设置未修改"
        }
    }

    func remove(_ id: String) {
        guard id != HarborIndependentWARP.nodeID else {
            detail = "内置 WARP 不能删除"
            return
        }
        guard configurationLoaded, !busy, !connectionTransition, !shuttingDownConnection else { return }
        guard !isInUse(id) else { detail = "请先切换或关闭使用此节点的连接"; return }
        nodes.removeAll { $0.id == id }
        if selectedID == id { selectedID = nodes.first?.id }
        probeResults.removeValue(forKey: id)
        nodeExitLocations.removeValue(forKey: id)
        exitGeoFailureCounts.removeValue(forKey: id)
        exitGeoAttemptedAt.removeValue(forKey: id)
        exitGeoPendingIDs.remove(id)
        let favorites = favoriteNodeIDs
        if favorites.contains(id) {
            UserDefaults.standard.set(favorites.subtracting([id]).sorted(), forKey: Self.favoriteNodeIDsKey)
        }
        scheduleGeoIPRefresh()
        persist()
    }

    func isInUse(_ id: String) -> Bool {
        running && (id == activeNodeID || (underlayPort != nil && id == vpnGateUnderlayNodeID))
    }

    private func start(
        nodeID: String? = nil,
        route: VPNGateRoute,
        policy: RoutingPolicy,
        requestedPort: Int? = nil,
        preservingSystemProxy: Bool = false,
        cancellation: HarborLatencyCancellation? = nil
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
        guard !HarborSystemProxy.hasBackup ||
                preservingSystemProxy else {
            detail = "系统代理状态尚未安全恢复"
            return
        }
        guard let node = nodes.first(where: { $0.id == (nodeID ?? selectedID) }) else {
            detail = "先导入并选择节点"
            return
        }
        guard supportsCore(for: node) else {
            detail = (node.protocolName == "openvpn" || HarborIndependentWARP.isBuiltIn(node))
                ? "请从安装包恢复内置 Mihomo 内核" : "请从安装包恢复内置 Xray 内核"
            return
        }
        busy = true; defer { busy = false }
        status = "正在连接"; detail = ""
        do {
            guard cancellation?.isCancelled != true, !shuttingDownConnection else { throw CancellationError() }
            let port = try choosePort(requestedPort ?? configuredHTTPPort)
            let isOpenVPN = node.protocolName == "openvpn"
            let isStandaloneWARP = HarborIndependentWARP.isBuiltIn(node)
            let underlayNodeID: String?
            if case .underlay(let id) = route, isOpenVPN { underlayNodeID = id }
            else { underlayNodeID = nil }
            if case .warp(let profile) = route, (isOpenVPN || isStandaloneWARP) {
                activeWARPProfile = profile
            } else {
                activeWARPProfile = nil
            }
            if let underlayNodeID {
                guard coreInstalled,
                      let base = nodes.first(where: {
                          $0.id == underlayNodeID && $0.protocolName != "openvpn"
                      }) else {
                    throw HarborProxyError.invalid("住宅节点的底座订阅节点已不存在")
                }
                try await startUnderlay(base)
            }
            let config: Data
            if isStandaloneWARP {
                guard let profile = activeWARPProfile else {
                    throw HarborProxyError.invalid("WARP 通道配置尚未就绪")
                }
                config = try HarborWARPConfig.make(profile: profile, httpPort: port)
            } else {
                config = try policy.configuration(
                    for: node, port: port, underlayPort: underlayPort, warp: activeWARPProfile)
            }
            let file = root.appendingPathComponent("runtime-\(UUID().uuidString).json")
            try HarborProbeFiles.write(config, to: file)
            configPath = file
            let process = Process()
            process.executableURL = root.appendingPathComponent(
                (isOpenVPN || isStandaloneWARP) ? "mihomo" : "xray")
            process.currentDirectoryURL = root
            process.arguments = (isOpenVPN || isStandaloneWARP)
                ? ["-d", HarborMihomoInstaller.dataDirectory(root: root).path, "-f", file.path]
                : ["run", "-config", file.path]
            process.standardInput = FileHandle.nullDevice
            // The active child may be adopted after an app restart. Its raw
            // output must not depend on an app pipe or grow a persistent log.
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
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
                underlay: underlayRecord(nodeID: underlayNodeID),
                warpEndpoint: activeWARPProfile?.endpoint
            )
            try HarborProbeFiles.replace(JSONEncoder().encode(record), at: runtimeRecordURL)
            var ready = false
            for _ in 0..<25 {
                guard process.isRunning, cancellation?.isCancelled != true,
                      !shuttingDownConnection else { break }
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
            warpExitIP = nil
            activePolicy = policy
            if isOpenVPN { vpnGateUnderlayNodeID = underlayPort == nil ? nil : underlayNodeID }
            running = true
            proxyAudit("listener_ready", nodeID: node.id)
            startLivenessMonitoring()
            healthy = false
            checkingConnectivity = true
            status = "已启动 · 正在检测网络"
            detail = "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
            connectionGeneration &+= 1
            let generation = connectionGeneration
            await finishHealthCheck(port: port, generation: generation, systemProxyInteractive: false,
                                    publishConnection: false, cancellation: cancellation)
        } catch {
            _ = await stopCore()
            status = "连接失败"
            detail = error.localizedDescription
        }
    }

    /// Recheck HTTPS over the running route, independently of website tests.
    private func finishHealthCheck(
        port: Int,
        generation: UInt64,
        systemProxyInteractive: Bool,
        publishConnection: Bool = true,
        cancellation: HarborLatencyCancellation? = nil
    ) async {
        let isOpenVPN = activeNode?.protocolName == "openvpn"
        let isWarp = activeNode.map(HarborIndependentWARP.isBuiltIn) ?? false
        let warpReport = isWarp ? await HarborWARPConnectivity.check(httpPort: port) : nil
        let reachable: Bool
        if let warpReport {
            reachable = warpReport.verified
        } else if isOpenVPN {
            reachable = await HarborMihomoLatencyTester.checkActiveSOCKS(
                port: port + 1, cancellation: cancellation)
        } else {
            reachable = await HarborNodeLatencyTester.checkActiveHTTP(port: port, cancellation: cancellation)
        }
        guard generation == connectionGeneration,
              running, localPort == port, cancellation?.isCancelled != true,
              !shuttingDownConnection, !Task.isCancelled else { return }
        lastActiveHealthCheckAt = .now
        guard coreProcessAlive else {
            await handleUnexpectedXrayExit(pid: child?.processIdentifier ?? adoptedPID)
            return
        }
        guard let activeNodeID, runningConfigMatches(activeNodeID, path: configPath) else {
            checkingConnectivity = false
            healthy = false
            proxyAudit("health_identity_mismatch", nodeID: activeNodeID)
            status = "运行配置与选中节点不一致"
            detail = "代理内核已启动，但无法核对实际运行节点；请重新选择节点"
            return
        }
        checkingConnectivity = false
        healthy = reachable
        warpExitIP = isWarp ? warpReport?.exitIP : nil
        proxyAudit(reachable ? "health_success" : "health_failed",
                   nodeID: activeNodeID, note: isOpenVPN ? "method=socks_https" : "method=http_proxy_https")
        if reachable {
            status = "已连接"
            detail = isWarp
                ? "WARP 出口已验证 \(warpExitIP ?? "IP 待识别") · HTTP \(port) / SOCKS5 \(port + 1)"
                : "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
            guard publishConnection else { return }
            if let activeNode, !isWarp { enqueueExitGeoRefresh(for: [activeNode]) }
            if autoManageSystemProxy && !systemManaged {
                await enableSystemProxy(interactive: systemProxyInteractive)
            }
        } else {
            // Inbound identity and node selection remain committed; a probe
            // failure does not mean the Xray outbound changed to another node.
            status = isWarp ? "WARP 出口验证失败" : "代理仍在运行 · 连通性检查未通过"
            detail = isWarp
                ? (warpReport?.reason ?? "WARP 真实出口验证失败，未接管系统代理")
                : "当前代理未能完成 HTTPS 验证请求。可以重试网站检测或选择其他节点。"
            if isWarp && systemManaged {
                do {
                    try await HarborSystemProxy.restore()
                    systemManaged = false
                    refreshSystemProxyState()
                } catch {
                    detail += "；系统代理恢复失败：" + error.localizedDescription
                    refreshSystemProxyState()
                }
            }
        }
    }

    /// Check website compatibility through the currently active outbound.
    /// Deliberately separate from the basic 204 health check: a blocked
    /// website is not equivalent to an unusable tunnel.
    func checkActiveWebsites() async {
        guard running, !checkingConnectivity, !websiteChecking, !connectionTransition,
              !busy, !shuttingDownConnection, let port = localPort else {
            detail = "请先连接并验证当前代理，再测试网站"
            return
        }
        websiteChecking = true
        let cancellation = HarborLatencyCancellation()
        websiteCancellation = cancellation
        websiteSummary = "正在检查网站首页…"
        defer {
            websiteChecking = false
            websiteCancellation = nil
        }
        let generation = connectionGeneration
        let activeID = activeNodeID
        let report = await HarborMihomoLatencyTester.websiteReport(socksPort: port + 1, cancellation: cancellation)
        guard running, generation == connectionGeneration, activeID == activeNodeID,
              !cancellation.isCancelled else {
            websiteSummary = "网站检测已取消，连接已改变"
            return
        }
        websiteSummary = report
    }

    func verify() async {
        guard running, let port = localPort, !busy, !connectionTransition,
              !shuttingDownConnection, !checkingConnectivity else { return }
        checkingConnectivity = true
        await finishHealthCheck(port: port, generation: connectionGeneration, systemProxyInteractive: false)
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
        _ ids: [String], finalization: SubscriptionProbeFinalization? = nil
    ) async {
        guard configurationLoaded, !latencyTesting, !busy, !connectionTransition, !shuttingDownConnection else { return }
        let requested = Set(ids)
        let candidates = nodes.filter {
            requested.contains($0.id) && !HarborIndependentWARP.isBuiltIn($0)
        }
        let targets = candidates.filter(availableCores()).enumerated().sorted { lhs, rhs in
            let first = probeResults[lhs.element.id]?.effectiveRealCheckedAt ?? .distantPast
            let second = probeResults[rhs.element.id]?.effectiveRealCheckedAt ?? .distantPast
            return first == second ? lhs.offset < rhs.offset : first < second
        }.map(\.element)
        let untested = candidates.count - targets.count
        guard !targets.isEmpty else {
            if untested > 0 { latencySummary = "缺少代理内核，所选节点未测试" }
            return
        }
        latencyTesting = true
        latencyBatchIDs = Set(targets.map(\.id))
        latencyCompleted = 0
        latencyTotal = targets.count
        let cancellation = HarborLatencyCancellation()
        latencyCancellation = cancellation
        latencySummary = "正在准备测试 \(targets.count) 个连接配置"
        let relayCount = targets.filter { $0.protocolName == "openvpn" }.count
        let relayParallelism = HarborProxyLatencyPolicy.openVPNParallelCount(
            processors: ProcessInfo.processInfo.activeProcessorCount, physicalMemory: ProcessInfo.processInfo.physicalMemory)
        let budget = relayCount == 0 ? HarborProxyLatencyPolicy.batchDeadlineSeconds
            : HarborProxyLatencyPolicy.vpnGateBatchDeadlineSeconds(nodeCount: relayCount, parallelCount: relayParallelism)
        let timer = Task {
            do { try await Task.sleep(for: .seconds(budget)) } catch { return }
            if latencyCancellation === cancellation {
                latencyStopping = true
                latencySummary = "已到本轮时间上限，正在结束剩余测试"
                cancellation.cancel()
            }
        }
        defer {
            timer.cancel()
            latencyTesting = false
            latencyStopping = false
            latencyBatchIDs = []
            latencyCurrentID = nil
            latencyTestingIDs = []
            latencyCancellation = nil
            persist()
        }

        let root = root
        let ordinary = targets.filter { $0.protocolName != "openvpn" }
        let relays = targets.filter { $0.protocolName == "openvpn" }
        let wave = HarborProxyLatencyPolicy.realPingBatchSize
        var available = 0
        var unavailable = 0
        var lastFailure: String?
        func save(_ node: HarborProxyNode, _ report: HarborNodeDelayReport,
                  routeID: String?, endpoint: HarborWARPEndpoint? = nil) {
            guard !cancellation.isCancelled, !Task.isCancelled,
                  let current = nodes.first(where: { $0.id == node.id }),
                  current.endpointSignature == node.endpointSignature else { return }
            let previous = probeResults[node.id]
            let sameRoute = previous?.probeRouteID == routeID && previous?.isStale() == false
            let failures = report.milliseconds == nil ? (sameRoute ? previous?.consecutiveRealFailures ?? 0 : 0) + 1 : 0
            let result = HarborProxyProbeResult(
                milliseconds: report.milliseconds, checkedAt: .now,
                realTested: true, realFailureReason: report.failure,
                consecutiveRealFailures: failures, probeRouteID: routeID)
            probeResults[node.id] = result
            if let endpoint, result.succeeded {
                if store.warpProbeEndpoints == nil { store.warpProbeEndpoints = [:] }
                store.warpProbeEndpoints?[node.id] = endpoint
            }
            latencyCompleted += 1
            if result.succeeded { available += 1 }
            if result.isConfirmedUnavailable { unavailable += 1 }
            if let failure = report.failure { lastFailure = failure }
        }

        for start in stride(from: 0, to: ordinary.count, by: wave) {
            guard !cancellation.isCancelled, !Task.isCancelled else { break }
            let group = Array(ordinary[start..<min(start + wave, ordinary.count)])
            latencySummary = "正在测速：\(latencyCompleted)/\(latencyTotal)"
            let shared = await HarborNodeLatencyTester.startRealBatch(nodes: group, root: root, cancellation: cancellation)
            await runLatencyPass(group, limit: shared == nil ? HarborProxyLatencyPolicy.standaloneParallelCount
                                 : HarborProxyLatencyPolicy.parallelCount, cancellation: cancellation) { node in
                if let shared, shared.hasRunningEngine { return await shared.measure(node: node) }
                return await HarborNodeLatencyTester.measure(node: node, root: root, cancellation: cancellation)
            } finish: { node, result in
                save(node, result, routeID: nil)
            }
            await shared?.close()
        }

        if !relays.isEmpty, !cancellation.isCancelled, !Task.isCancelled {
            let count = relayParallelism
            var pending = Set(relays.map(\.id))
            var failures: [String: (HarborNodeDelayReport, String)] = [:]
            var warpPrepared = false
            latencySummary = "正在准备 VPN Gate 独立筛选通道"
            do {
                let tunnel = try await prepareIndependentVPNGateTunnel(cancellation: cancellation)
                let profile = tunnel.profile
                let ranked = await HarborVPNGatePortScanner.rank(
                    relays, socksPort: tunnel.socksPort, cancellation: cancellation)
                await tunnel.close()
                warpPrepared = true
                latencySummary = "正在通过独立通道验证 VPN Gate 家宽候选"
                await runLatencyPass(ranked, limit: count, cancellation: cancellation) { node in
                    await HarborMihomoLatencyTester.measure(node: node, root: root,
                        cancellation: cancellation, warpProfile: profile)
                } finish: { node, report in
                    if report.milliseconds != nil {
                        pending.remove(node.id)
                        save(node, report, routeID: profile.routeID, endpoint: profile.endpoint)
                    } else { failures[node.id] = (report, profile.routeID) }
                }
                proxyAudit("vpngate_warp_pass", note: "total=\(relays.count) passed=\(relays.count - pending.count)")
            } catch {
                proxyAudit("vpngate_warp_unavailable", note: "cancelled=\(cancellation.isCancelled)")
            }

            if let underlay = workingVPNGateUnderlay, !pending.isEmpty, !cancellation.isCancelled,
               await HarborMihomoLatencyTester.underlayReady(socksPort: underlay.socksPort, cancellation: cancellation),
               workingVPNGateUnderlay?.routeID == underlay.routeID {
                latencySummary = "正在通过当前代理复测 VPN Gate"
                let retry = relays.filter { pending.contains($0.id) }
                await runLatencyPass(retry, limit: count, cancellation: cancellation) { node in
                    await HarborMihomoLatencyTester.measure(node: node, root: root, cancellation: cancellation,
                                                           underlaySocksPort: underlay.socksPort, seconds: 28)
                } finish: { node, report in
                    if report.milliseconds != nil {
                        pending.remove(node.id)
                        save(node, report, routeID: underlay.routeID)
                    } else if failures[node.id] == nil { failures[node.id] = (report, underlay.routeID) }
                }
            }

            if !pending.isEmpty, !cancellation.isCancelled, !Task.isCancelled {
                latencySummary = "正在用本机网络复测剩余 VPN Gate 节点"
                let retry = relays.filter { pending.contains($0.id) }
                let ranked = await HarborVPNGatePortScanner.rank(retry, socksPort: nil, cancellation: cancellation)
                // TCP preflight ranks candidates only. It is not evidence of
                // an OpenVPN failure and cannot exclude a real HTTPS test.
                await runLatencyPass(ranked, limit: count, cancellation: cancellation) { node in
                    await HarborMihomoLatencyTester.measure(node: node, root: root,
                                                           cancellation: cancellation, seconds: 12)
                } finish: { node, report in
                    if report.milliseconds != nil {
                        pending.remove(node.id)
                        save(node, report, routeID: "direct")
                    } else if failures[node.id] == nil { failures[node.id] = (report, "direct") }
                }
            }
            if !cancellation.isCancelled, !Task.isCancelled {
                for node in relays where pending.contains(node.id) {
                    guard let (report, routeID) = failures[node.id] else { continue }
                    let reason = (report.failure ?? "节点验证失败") +
                        (warpPrepared ? "" : "；独立通道暂不可用")
                    // Failure of an alternative path does not disprove a
                    // previously verified WARP route when WARP itself is down.
                    if !warpPrepared, var previous = probeResults[node.id],
                       previous.succeeded, previous.probeRouteID?.hasPrefix("warp:") == true {
                        // Retain the historical latency, but make it ineligible
                        // as a currently verified success until WARP is retested.
                        previous.realTested = false
                        previous.realFailureReason = reason
                        previous.consecutiveRealFailures = 0
                        probeResults[node.id] = previous
                        latencyCompleted += 1
                        lastFailure = reason
                        continue
                    }
                    save(node, .failed(reason), routeID: routeID)
                }
            }
            proxyAudit("vpngate_probe_summary", note: "total=\(relays.count) remaining=\(pending.count) completed=\(latencyCompleted) cancelled=\(cancellation.isCancelled)")
        }

        if let finalization, !cancellation.isCancelled, !Task.isCancelled, latencyCompleted == latencyTotal {
            finalizeSubscriptionProbes(finalization)
        }
        if cancellation.isCancelled || Task.isCancelled {
            latencySummary = "测速已结束：完成 \(latencyCompleted)/\(latencyTotal)；未完成的节点保留上次结果"
        } else {
            latencySummary = "测速完成：通过 \(available)，待复测 \(latencyCompleted - available - unavailable)，不可用 \(unavailable)"
            if untested > 0 { latencySummary += "；\(untested) 个配置缺少内核，未测试" }
            if let lastFailure { latencySummary += "；" + lastFailure }
        }
    }

    private func runLatencyPass(
        _ targets: [HarborProxyNode], limit: Int, cancellation: HarborLatencyCancellation,
        measure: @escaping @Sendable (HarborProxyNode) async -> HarborNodeDelayReport,
        finish: (HarborProxyNode, HarborNodeDelayReport) -> Void
    ) async {
        guard !cancellation.isCancelled, !Task.isCancelled else { return }
        var queue = HarborProxyLatencyQueue(count: targets.count, limit: limit)
        await withTaskGroup(of: (HarborProxyNode, HarborNodeDelayReport).self) { group in
            @MainActor func submit(_ index: Int) {
                let node = targets[index]
                latencyTestingIDs.insert(node.id)
                latencyCurrentID = node.id
                group.addTask { (node, await measure(node)) }
            }
            for index in queue.initialIndices() { submit(index) }
            while let (node, result) = await group.next() {
                latencyTestingIDs.remove(node.id)
                guard !cancellation.isCancelled, !Task.isCancelled else {
                    group.cancelAll()
                    break
                }
                finish(node, result)
                if let index = queue.nextIndex() { submit(index) }
            }
        }
    }
    func refreshExitLocations(for ids: [String]) {
        guard configurationLoaded, !busy, !exitGeoUpdating, !exitGeoCleaningUp,
              !shuttingDownConnection else { return }
        let requested = Set(ids)
        let hasCore = availableCores()
        let candidates = nodes.filter {
            requested.contains($0.id) && hasCore($0) && !HarborIndependentWARP.isBuiltIn($0)
        }
        guard !candidates.isEmpty else {
            exitGeoSummary = "没有可检测的配置，请检查节点和内核"
            return
        }
        exitGeoManualIDs = Set(candidates.map(\.id))
        exitGeoUnrecognizedIDs.subtract(exitGeoManualIDs)
        for id in exitGeoManualIDs { exitGeoFailureReasons.removeValue(forKey: id) }
        exitGeoForcedIDs.formUnion(exitGeoManualIDs)
        let manualGeneration = UUID()
        exitGeoManualGeneration = manualGeneration
        exitGeoWatchdog?.cancel()
        let timeoutSeconds = HarborProxyGeoIPPolicy.exitBatchDeadlineSeconds(nodeCount: candidates.count)
        exitGeoWatchdog = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(timeoutSeconds)) }
            catch { return }
            self?.finishExitGeoRefreshEarly(generation: manualGeneration, reason: "超时")
        }
        exitGeoUpdating = true
        exitGeoCompleted = 0
        exitGeoTotal = candidates.count
        exitGeoManualSucceeded = 0
        exitGeoManualNotStarted = 0
        exitGeoSummary = "正在识别出口地区：0/\(exitGeoTotal)"
        enqueueExitGeoRefresh(for: candidates)
    }

    /// Exit discovery has its own queue and Xray process.
    private func enqueueExitGeoRefresh(for candidates: [HarborProxyNode]) {
        guard !shuttingDownConnection, !exitGeoCleaningUp else { return }
        let now = Date.now
        let hasCore = availableCores()
        // All callers supply a snapshot of nodes on this actor. The worker
        // checks their identity again after its network requests complete.
        for current in candidates {
            guard !exitGeoPendingIDs.contains(current.id), !exitGeoInFlightIDs.contains(current.id),
                  hasCore(current), !HarborIndependentWARP.isBuiltIn(current) else { continue }
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
        guard !exitGeoPendingIDs.isEmpty, exitGeoTask == nil else { return }
        let generation = UUID()
        exitGeoBatchGeneration = generation
        exitGeoTask = Task(priority: .utility) { [weak self] in
            await self?.runExitGeoQueue(generation: generation)
        }
    }

    /// A canceled or timed-out batch must not modify state owned by the next.
    private func runExitGeoQueue(generation: UUID) async {
        defer {
            if exitGeoBatchGeneration == generation {
                exitGeoBatchGeneration = nil
                exitGeoInFlightIDs.removeAll()
                exitGeoCancellation = nil
                exitGeoTask = nil
                exitGeoCleaningUp = false
            }
        }
        while !Task.isCancelled, exitGeoBatchGeneration == generation,
              !exitGeoPendingIDs.isEmpty {
            // Bound the number of listeners and the impact of one invalid
            // profile. Prefer explicit requests over queued automatic work.
            exitGeoPendingIDs.formIntersection(Set(nodes.map(\.id)))
            let pending = nodes.filter { exitGeoPendingIDs.contains($0.id) }
            let manual = pending.filter { exitGeoManualIDs.contains($0.id) }.enumerated().sorted { lhs, rhs in
                let first = exitGeoAttemptedAt[lhs.element.id] ?? .distantPast
                let second = exitGeoAttemptedAt[rhs.element.id] ?? .distantPast
                return first == second ? lhs.offset < rhs.offset : first < second
            }.map(\.element)
            let ordered = manual
                + pending.filter { !exitGeoManualIDs.contains($0.id) }
            let candidates = Array(ordered.prefix(HarborProxyGeoIPPolicy.exitBatchSize))
            exitGeoPendingIDs.subtract(candidates.map(\.id))
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
            exitGeoInFlightIDs = Set(due.map(\.id))
            for node in due { exitGeoAttemptedAt[node.id] = now }
            let cancellation = HarborLatencyCancellation()
            exitGeoCancellation = cancellation
            // A lone automatic refresh can reuse the active listener. Manual
            // batches always use isolated inbounds so node switches cannot
            // attribute an exit IP to the wrong profile.
            let livePort = due.count == 1 && due[0].id == activeNodeID
                && !exitGeoManualIDs.contains(due[0].id) && running && healthy
                ? localPort.map { $0 + 1 } : nil
            let liveGeneration = connectionGeneration
            let activeRoute = currentVPNGateRouteID
            let batch: HarborRealDelayBatch?
            if livePort == nil && due.contains(where: { $0.protocolName != "openvpn" }) {
                batch = await HarborNodeLatencyTester.startRealBatch(
                    nodes: due.filter { $0.protocolName != "openvpn" },
                    root: root, cancellation: cancellation
                )
            } else {
                batch = nil
            }
            guard exitGeoBatchGeneration == generation, !Task.isCancelled else {
                cancellation.cancel()
                await batch?.close()
                return
            }
            let geoRoot = root
            let warpProfiles = Dictionary(uniqueKeysWithValues: due.compactMap { node in
                warpProfile(for: node).map { (node.id, $0) }
            })
            let underlay = workingVPNGateUnderlay
            let probeRoutes = probeResults
            let inspect: @Sendable (HarborProxyNode) async
                -> (HarborProxyNode, HarborNodeExitGeoReport, String?) = { node in
                if let livePort {
                    return (node, .probed(await HarborNodeGeoIPResolver.exitLocation(
                        socksPort: livePort, cancellation: cancellation)), activeRoute)
                }
                if node.protocolName == "openvpn" {
                    let routeID = probeRoutes[node.id]?.probeRouteID
                    let base = routeID == "direct" ? nil : underlay
                    let warp = base == nil && routeID != "direct" ? warpProfiles[node.id] : nil
                    let attempt = await HarborMihomoLatencyTester.exitLocationReport(
                        node: node, root: geoRoot, cancellation: cancellation,
                        underlaySocksPort: base?.socksPort, warpProfile: warp)
                    if attempt.location == nil, (base != nil || warp != nil), !cancellation.isCancelled {
                        return (node, await HarborMihomoLatencyTester.exitLocationReport(
                            node: node, root: geoRoot, cancellation: cancellation), "direct")
                    }
                    return (node, attempt, base?.routeID ?? warp?.routeID ?? "direct")
                }
                return (node, await HarborNodeLatencyTester.probeExitLocation(
                    node: node, root: geoRoot, cancellation: cancellation, batch: batch), nil)
            }
            var queue = HarborProxyLatencyQueue(
                count: due.count, limit: HarborProxyGeoIPPolicy.exitParallelCount
            )
            var renamedSubscriptions = Set<String>()
            await withTaskGroup(of: (HarborProxyNode, HarborNodeExitGeoReport, String?).self) { group in
                for index in queue.initialIndices() {
                    let target = due[index]
                    group.addTask { await inspect(target) }
                }
                while let (target, report, routeID) = await group.next() {
                    guard exitGeoBatchGeneration == generation,
                          !Task.isCancelled, !cancellation.isCancelled else {
                        group.cancelAll()
                        break
                    }
                    if let index = queue.nextIndex() {
                        let next = due[index]
                        group.addTask { await inspect(next) }
                    }
                    guard let latest = nodes.first(where: { $0.id == target.id }),
                          latest.endpointSignature == target.endpointSignature else { continue }
                    if livePort != nil && (activeNodeID != target.id || connectionGeneration != liveGeneration) {
                        if exitGeoForcedIDs.contains(target.id) { exitGeoPendingIDs.insert(target.id) }
                        continue
                    }
                    let manuallyRequested = exitGeoManualIDs.remove(target.id) != nil
                    exitGeoForcedIDs.remove(target.id)
                    if manuallyRequested {
                        if report.started {
                            exitGeoCompleted += 1
                        } else {
                            exitGeoManualNotStarted += 1
                        }
                        exitGeoSummary = "正在识别出口地区：已检测 \(exitGeoCompleted)/\(exitGeoTotal)"
                        if exitGeoManualNotStarted > 0 {
                            exitGeoSummary += "，检测代理未启动 \(exitGeoManualNotStarted)"
                        }
                    }
                    guard let observed = report.location else {
                        exitGeoFailureCounts[target.id, default: 0] += 1
                        exitGeoFailureReasons[target.id] = report.failure
                        if manuallyRequested { exitGeoUnrecognizedIDs.insert(target.id) }
                        continue
                    }
                    exitGeoFailureReasons[target.id] = report.failure
                    if observed.verifiedCountryCode != nil {
                        exitGeoUnrecognizedIDs.remove(target.id)
                        if manuallyRequested { exitGeoManualSucceeded += 1 }
                        exitGeoFailureCounts.removeValue(forKey: target.id)
                        exitGeoAttemptedAt.removeValue(forKey: target.id)
                    } else {
                        exitGeoUnrecognizedIDs.insert(target.id)
                        exitGeoFailureCounts[target.id, default: 0] += 1
                    }
                    nodeExitLocations[target.id] = HarborProxyExitLocation(
                        location: observed, endpointSignature: target.endpointSignature,
                        resolvedServerIP: nodeServerLocations[latest.host.lowercased()]?.ip, probeRouteID: routeID
                    )
                    if !latest.subscriptionID.isEmpty {
                        renamedSubscriptions.insert(latest.subscriptionID)
                    }
                }
            }
            for id in renamedSubscriptions { refreshAutomaticNames(for: id) }
            persist()
            if Task.isCancelled || exitGeoBatchGeneration != generation {
                cancellation.cancel()
            }
            await batch?.close()
            exitGeoInFlightIDs.removeAll()
        }
        guard exitGeoBatchGeneration == generation, !Task.isCancelled else { return }
        if exitGeoUpdating {
            // If a node was skipped or disappeared, count it as unresolved
            // rather than leaving the UI in an unending "23/24" state.
            exitGeoUnrecognizedIDs.formUnion(exitGeoManualIDs)
            // The actual completed count remains visible after finishing.
            exitGeoWatchdog?.cancel()
            exitGeoWatchdog = nil
            exitGeoManualGeneration = nil
            exitGeoSummary = "出口地区识别结束：已检测 \(exitGeoCompleted)/\(exitGeoTotal)，确认 \(exitGeoManualSucceeded)"
            if exitGeoManualNotStarted > 0 {
                exitGeoSummary += "；\(exitGeoManualNotStarted) 个检测代理未启动，可查看节点地区提示"
            } else if exitGeoManualSucceeded < exitGeoTotal {
                exitGeoSummary += "；未确认的节点可查看地区提示后重试"
            }
            exitGeoUpdating = false
            exitGeoManualIDs.removeAll()
            exitGeoForcedIDs.removeAll()
        }
        scheduleExitGeoRetry()
    }

    /// Called by the manual batch watchdog or the Stop button. This is a
    /// presentation deadline, not a claim that a network request succeeded.
    /// Remaining nodes are explicitly marked "未识别" and can be retried.
    private func finishExitGeoRefreshEarly(generation: UUID, reason: String) {
        guard exitGeoManualGeneration == generation, exitGeoUpdating else { return }
        let unresolved = exitGeoManualIDs
        if reason == "超时" {
            for id in unresolved {
                exitGeoFailureCounts[id, default: 0] += 1
                exitGeoFailureReasons[id] = "本次地区识别超时，尚未完成"
            }
        }
        exitGeoForcedIDs.subtract(unresolved)
        exitGeoPendingIDs.subtract(unresolved)
        exitGeoManualIDs.removeAll()
        exitGeoUpdating = false
        // Keep the real number completed: a stopped node is not "tested".
        exitGeoManualGeneration = nil
        exitGeoWatchdog?.cancel()
        exitGeoWatchdog = nil
        exitGeoCleaningUp = exitGeoTask != nil
        exitGeoCancellation?.cancel()
        exitGeoTask?.cancel()
        exitGeoPendingIDs.removeAll()
        exitGeoSummary = "出口地区识别\(reason)：完成 \(exitGeoCompleted)/\(exitGeoTotal)；未完成的节点保留上次结果"
    }

    func cancelExitGeoRefresh() {
        guard let generation = exitGeoManualGeneration else { return }
        finishExitGeoRefreshEarly(generation: generation, reason: "已停止")
    }

    private func cancelAllExitGeoWork() {
        cancelExitGeoRefresh()
        exitGeoCancellation?.cancel()
        exitGeoTask?.cancel()
        exitGeoRetryTask?.cancel()
        exitGeoRetryTask = nil
        exitGeoPendingIDs.removeAll()
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
        guard latencyTesting, !latencyStopping, let cancellation = latencyCancellation else { return }
        latencyStopping = true
        latencySummary = "正在停止测速并释放探测资源…"
        cancellation.cancel()
    }

    func enableSystemProxy(interactive: Bool = false) async {
        guard !connectionTransition, !shuttingDownConnection else { return }
        connectionTransition = true
        defer { connectionTransition = false }
        await applySystemProxy(interactive: interactive)
    }

    private func applySystemProxy(interactive: Bool, policy: RoutingPolicy? = nil,
                                  reconfigure: Bool = false) async {
        guard running, healthy, let localPort else { detail = "请先连接并验证当前节点"; return }
        if !reconfigure && systemManaged && HarborSystemProxy.isOwned() { return }
        let generation = connectionGeneration
        let rules: RoutingPolicy
        if let policy = policy ?? activePolicy { rules = policy }
        else { rules = await RoutingPolicy.read(ruleMode: routingRules, forcedDomains: forcedProxyDomains) }
        guard generation == connectionGeneration, !shuttingDownConnection else { return }
        do {
            try await HarborSystemProxy.enable(port: localPort, forcedProxyDomains: rules.forcedDomains,
                                               automaticBypass: rules.localHosts)
            for _ in 0..<10 where !HarborSystemProxy.isOwned() {
                do { try await Task.sleep(for: .milliseconds(60)) } catch { break }
            }
            guard generation == connectionGeneration else { return }
            systemManaged = HarborSystemProxy.isOwned()
            if systemManaged {
                autoManageSystemProxy = true
                persist()
            }
            detail = systemManaged ? "已接管 macOS 系统代理" : "本地节点已连接，但当前网络未采用 Harbor 系统代理"
        } catch {
            systemManaged = false
            detail = "本地节点已连接，但系统代理未接管：" + error.localizedDescription
        }
        refreshSystemProxyState()
    }

    func clearSystemProxy() async {
        guard !connectionTransition, !shuttingDownConnection else { return }
        connectionTransition = true
        defer { connectionTransition = false }
        do {
            try await HarborSystemProxy.restore()
            systemManaged = false
            autoManageSystemProxy = false
            persist()
            detail = "原系统代理设置已恢复"
        } catch { detail = error.localizedDescription }
        refreshSystemProxyState()
    }

    @discardableResult
    func stop(interactive: Bool = false) async -> Bool {
        guard !shuttingDownConnection else { return false }
        shuttingDownConnection = true
        defer { shuttingDownConnection = false }
        pendingActivation.clear()
        activationPreflightCancellation?.cancel()
        vpnGateDownloadCancellation?.cancel()
        warpRegistrationTask?.cancel()
        cancelLatencyTests()
        cancelAllExitGeoWork()
        websiteCancellation?.cancel()
        let shutdownDeadline = ContinuousClock.now + .seconds(35)
        while connectionTransition || latencyTesting || exitGeoCleaningUp || websiteChecking {
            guard ContinuousClock.now < shutdownDeadline else {
                detail = "后台操作尚未结束，当前代理已保留，请稍后重试"
                return false
            }
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + .milliseconds(50)) {
                    continuation.resume()
                }
            }
        }
        if HarborProxyRecoveryPolicy.mustRestoreBeforeStop(hasBackup: HarborSystemProxy.hasBackup) {
            do { try await HarborSystemProxy.restore() }
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
                if self.running, !self.connectionTransition, !self.shuttingDownConnection,
                   !self.checkingConnectivity, let port = self.localPort,
                   Date().timeIntervalSince(self.lastActiveHealthCheckAt ?? .distantPast)
                    >= HarborProxyLatencyPolicy.activeHealthCheckInterval {
                    self.checkingConnectivity = true
                    await self.finishHealthCheck(
                        port: port,
                        generation: self.connectionGeneration,
                        systemProxyInteractive: false
                    )
                }
                if self.adoptedPID != nil { self.trimRuntimeErrorLogIfNeeded() }
            }
        }
    }

    /// Trim the log of an adopted legacy process, which still writes to it.
    /// New processes only write bounded application diagnostics.
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
        guard !connectionTransition, !shuttingDownConnection, let pid,
              HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
                  running: running,
                  intentionallyStopping: intentionallyStoppingCore,
                  processMatches: pid == child?.processIdentifier || pid == adoptedPID,
                  coreAlive: coreProcessAlive
              ) else { return }
        connectionTransition = true
        defer { connectionTransition = false }
        // If an Xray crash leaves macOS pointing to dead listeners, restore
        // the previous network configuration without prompting for privileges.
        var restorationFailure: String?
        if HarborSystemProxy.hasBackup {
            do { try await HarborSystemProxy.restore() }
            catch { restorationFailure = error.localizedDescription }
        }
        _ = await stopCore()
        systemManaged = false
        activeNodeID = nil
        healthy = false
        proxyAudit("unexpected_xray_exit")
        status = "代理内核异常退出"
        detail = restorationFailure.map {
            "代理内核意外退出，系统代理未能自动恢复：\($0)。请使用代理页面的恢复操作"
        } ?? "代理内核意外退出。诊断记录：proxy-switch-diagnostics.log"
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
            guard await HarborProxyCommand.stop(child) else {
                detail = "代理内核未能退出，请手动检查进程"
                return false
            }
            self.child = nil
        }
        if let underlayChild {
            guard await HarborProxyCommand.stop(underlayChild) else {
                detail = "底座代理进程未能退出，请手动检查"
                return false
            }
            self.underlayChild = nil
        }
        if let underlayPort { HarborNodeLatencyTester.releasePortPair(underlayPort) }
        if let underlayConfigPath { try? FileManager.default.removeItem(at: underlayConfigPath) }
        underlayPort = nil
        underlayConfigPath = nil
        adoptedUnderlayPID = nil
        activeWARPProfile = nil
        activePolicy = nil
        warpExitIP = nil
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
    private func adoptExistingXray() async -> Bool {
        guard HarborSystemProxy.isOwned(),
              let data = try? Data(contentsOf: runtimeRecordURL),
              let record = try? JSONDecoder().decode(HarborProxyProcessRecord.self, from: data),
              selectedNode != nil,
              await recordedXrayIsOrphan(record),
              portListening(configuredHTTPPort),
              portListening(configuredHTTPPort + 1) else { return false }
        if let underlay = record.underlay, !(await validAdoptedUnderlay(underlay)) { return false }
        if let endpoint = record.warpEndpoint {
            guard let account = store.warpAccount else { return false }
            activeWARPProfile = HarborWARPProfile(account: account, endpoint: endpoint)
        }
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
                HarborIndependentWARP.isBuiltIn(node)
                    ? activeWARPProfile.map {
                        HarborWARPConfig.matches(configuration: data, profile: $0,
                                                httpPort: configuredHTTPPort)
                      } ?? false
                    : node.protocolName == "openvpn"
                    ? HarborMihomoConfig.matches(
                        configuration: data, node: node,
                        underlaySocksPort: record.underlay.map { $0.httpPort + 1 },
                        warpProfile: activeWARPProfile)
                    : HarborProxyRuntimeIdentity.matches(configuration: data, node: node)
            }
        }
        activeNodeID = matched?.id
        warpExitIP = nil
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

    private func validAdoptedUnderlay(_ record: HarborProxyUnderlayRecord) async -> Bool {
        guard await recordedUnderlayIsOrphan(record),
              portListening(record.httpPort), portListening(record.httpPort + 1),
              let node = nodes.first(where: { $0.id == record.nodeID }),
              let config = try? Data(contentsOf: URL(fileURLWithPath: record.configPath)) else {
            return false
        }
        return HarborProxyRuntimeIdentity.matches(configuration: config, node: node)
    }

    /// Only remove an orphan that matches Harbor's unique config path and executable.
    /// Never kill a PID solely because a prior runtime record contains that number.
    private func recordedXrayIsOrphan(_ record: HarborProxyProcessRecord) async -> Bool {
        await recordedProcessIsOrphan(pid: record.pid, configPath: record.configPath,
                                executablePath: record.executablePath, prefix: "runtime-")
    }

    private func recordedUnderlayIsOrphan(_ record: HarborProxyUnderlayRecord) async -> Bool {
        guard record.executablePath == root.appendingPathComponent("xray").path else { return false }
        return await recordedProcessIsOrphan(pid: record.pid, configPath: record.configPath,
                                       executablePath: record.executablePath, prefix: "underlay-")
    }

    private func recordedProcessIsOrphan(pid: Int32, configPath: String,
                                         executablePath: String, prefix: String) async -> Bool {
        let config = URL(fileURLWithPath: configPath).standardizedFileURL
        let xray = root.appendingPathComponent("xray").path
        let mihomo = root.appendingPathComponent("mihomo").path
        guard pid > 0,
              config.deletingLastPathComponent() == root.standardizedFileURL,
              config.lastPathComponent.hasPrefix(prefix),
              config.pathExtension == "json",
              executablePath == xray || executablePath == mihomo,
              Darwin.kill(pid, 0) == 0 else { return false }
        let args = ["-ww", "-p", String(pid), "-o", "ppid=", "-o", "command="]
        guard let result = try? await HarborProxyCommand.run(
            URL(fileURLWithPath: "/bin/ps"), arguments: args, timeout: 2, outputLimit: 16_384
        ), result.status == 0 else { return false }
        let output = String(decoding: result.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = output.split(maxSplits: 1, whereSeparator: { $0.isWhitespace })
        guard parts.count == 2, parts[0] == "1" else { return false }
        if executablePath == xray { return parts[1] == "\(xray) run -config \(configPath)" }
        return parts[1] == "\(mihomo) -d \(root.path) -f \(configPath)"
            || parts[1] == "\(mihomo) -d \(HarborMihomoInstaller.dataDirectory(root: root).path) -f \(configPath)"
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
            guard await recordedXrayIsOrphan(record) else {
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
                guard await recordedXrayIsOrphan(record) else {
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
                guard await recordedUnderlayIsOrphan(underlay) else {
                    detail = "底座代理仍由其他进程管理，已停止自动清理"
                    return
                }
                _ = Darwin.kill(underlay.pid, SIGTERM)
                for _ in 0..<20 where Darwin.kill(underlay.pid, 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Darwin.kill(underlay.pid, 0) == 0 {
                    guard await recordedUnderlayIsOrphan(underlay) else { return }
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

    private func choosePort(_ requestedPort: Int) throws -> Int {
        let port = try HarborProxyPortPolicy.validate(httpPort: requestedPort)
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
        HarborNodeLatencyTester.canConnect(port)
    }
}
