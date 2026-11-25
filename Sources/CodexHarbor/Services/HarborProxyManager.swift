import AppKit
import CodexHarborCore
import CryptoKit
import Foundation
import Network
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
    var fallbackPolicy: HarborProxyFallbackPolicy?
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
    var nodeExitNetworkEvidence: [String: HarborProxyNetworkEvidence]?
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
    @Published private(set) var connectionPhase: HarborConnectionPhase = .stopped
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
    private let connectionCoordinator = HarborConnectionCoordinator()
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
    @Published private(set) var nodeExitNetworkEvidence: [String: HarborProxyNetworkEvidence] = [:]
    @Published private(set) var lastSuccessfulHealthCheckAt: Date?
    private var exitClassificationTask: Task<Void, Never>?
    private var exitObservationTask: Task<Void, Never>?
    private var exitObservationCancellation: HarborLatencyCancellation?
    private var exitClassificationCancellation: HarborLatencyCancellation?
    private var exitClassificationKey: String?
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
    @Published private(set) var fallbackPolicy = HarborProxyFallbackPolicy()
    private var attemptedFallbackIDs: Set<String> = []
    private var lastFallbackAttempt: ContinuousClock.Instant?
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
    private let runtimeSupervisor = HarborRuntimeEngineSupervisor()
    private var localGateway: HarborAgentGateway?
    private var gatewayBackend: GatewayBackend?
    private var drainingBackend: GatewayBackend?
    private var migrationGateway: HarborAgentGateway?
    private var gatewayHealthPolicy = HarborProxyHealthPolicy()
    private var gatewayRecoveryTask: Task<Void, Never>?
    private var gatewayRecoveryToken = UUID()
    private var networkPathMonitor: NWPathMonitor?
    private var networkOnline = true
    private var warpRegistrationTask: Task<HarborWARPAccount, Error>?
    private var warpRegistrationID: UUID?
    private let warpDiscoveryPool = HarborWARPDiscoveryPool()
    private var formalWARPDiscovery = HarborWARPFormalDiscoveryPolicy()
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
    private var activeHealthCancellation: HarborLatencyCancellation?
    /// Cheap process-only check, started only while Xray runs. Handles adoption
    /// of a previous process, where Process.terminationHandler is unavailable.
    private var livenessTask: Task<Void, Never>?
    private var intentionallyStoppingCore = false
    private var runtimeRecordURL: URL { root.appendingPathComponent("active-process.json") }
    private var legacyMigrationURL: URL { root.appendingPathComponent("legacy-migration.json") }

    private struct LegacyMigration: Codable {
        let oldPort: Int
        let stagingPort: Int
        let targetPort: Int
        let wasManaged: Bool
    }
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
    private struct GatewayBackend {
        let nodeID: String
        let endpointSignature: String
        var observedExitIP: String?
        let primary: HarborRuntimeEngineSupervisor.Engine
        let underlay: HarborRuntimeEngineSupervisor.Engine?
        let underlayID: String?
        let warp: HarborWARPProfile?
        let warpExitIP: String?
        let policy: RoutingPolicy

        func agentRoute() throws -> HarborProxyAgentRoute {
            let engines = [primary] + (underlay.map { [$0] } ?? [])
            let records = engines.compactMap(\.agentRecord)
            guard records.count == engines.count else { throw HarborProxyError.invalid("代理内核身份未确认") }
            for engine in engines { engine.managedByAgent = true }
            return .init(nodeID: nodeID, endpointSignature: endpointSignature, primaryID: primary.id,
                underlayID: underlay?.id, underlayNodeID: underlayID, warpEndpoint: warp?.endpoint,
                ruleMode: policy.ruleMode, forcedDomains: policy.forcedDomains,
                localHostAddresses: policy.localHostAddresses, observedExitIP: observedExitIP, engines: records)
        }

        var engineIDs: Set<UUID> {
            Set([primary.id] + (underlay.map { [$0.id] } ?? []))
        }

        var alive: Bool {
            primary.isAlive && primary.configurationUnchanged
                && (underlay.map { $0.isAlive && $0.configurationUnchanged } ?? true)
        }
    }

    var selectedNode: HarborProxyNode? { nodes.first { $0.id == selectedID } }
    var canMaintainResidentProxy: Bool {
        configurationLoaded && (running || bootstrapping || activationInProgress || connectionTransition
                                || shuttingDownConnection)
    }
    var activeNode: HarborProxyNode? { nodes.first { $0.id == activeNodeID } }
    var currentVerifiedExitIP: String? {
        guard running, healthy, let activeNode else { return nil }
        if HarborIndependentWARP.isBuiltIn(activeNode) { return warpExitIP }
        if let gatewayBackend { return gatewayBackend.observedExitIP }
        return observedExit(for: activeNode)?.ip
    }
    private var workingVPNGateUnderlay: (nodeID: String, socksPort: Int, routeID: String)? {
        guard running, healthy, let activeNode,
              !HarborIndependentWARP.isBuiltIn(activeNode) else { return nil }
        let isOpenVPN = activeNode.protocolName == "openvpn"
        guard let port = isOpenVPN ? underlayPort : (gatewayBackend?.primary.port ?? localPort),
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

    /// Enrollment is shared by screening and formal connection discovery.
    private func ensureWARPAccount(
        cancellation: HarborLatencyCancellation
    ) async throws -> HarborWARPAccount {
        let epoch = connectionCoordinator.networkEpoch
        guard mihomoInstalled else { throw HarborProxyError.invalid("请从安装包恢复内置 Mihomo 内核") }
        if store.warpAccount == nil {
            detail = "首次准备独立筛选通道，正在生成本机凭据"
            if warpRegistrationTask == nil {
                warpRegistrationID = UUID()
                warpRegistrationTask = Task { try await HarborWARPRegistration.register() }
            }
            guard let task = warpRegistrationTask, let id = warpRegistrationID else { throw CancellationError() }
            defer {
                if warpRegistrationID == id {
                    warpRegistrationTask = nil
                    warpRegistrationID = nil
                }
            }
            let account = try await task.value
            guard !shuttingDownConnection, networkOnline, epoch == connectionCoordinator.networkEpoch else {
                throw CancellationError()
            }
            if store.warpAccount == nil {
                store.warpAccount = account
                persist()
            }
        }
        guard !cancellation.isCancelled, !Task.isCancelled, !shuttingDownConnection,
              networkOnline, epoch == connectionCoordinator.networkEpoch,
              let account = store.warpAccount else { throw CancellationError() }
        try account.validate()
        return account
    }

    /// Screening uses a shared temporary tunnel; the formal connection
    /// path instead verifies resident candidates directly.
    private func prepareIndependentVPNGateTunnel(
        cancellation: HarborLatencyCancellation,
        preferred: HarborWARPEndpoint? = nil
    ) async throws -> HarborWARPDiscoveryPool.Lease {
        let epoch = connectionCoordinator.networkEpoch
        let account = try await ensureWARPAccount(cancellation: cancellation)
        detail = "正在验证独立筛选通道，无需启用订阅节点"
        let tunnel = try await warpDiscoveryPool.acquire(
            account: account, preferred: preferred ?? store.warpEndpoint,
            root: root, networkEpoch: epoch, cancellation: cancellation)
        guard epoch == connectionCoordinator.networkEpoch, !shuttingDownConnection,
              !cancellation.isCancelled, !Task.isCancelled else {
            await tunnel.close()
            throw CancellationError()
        }
        store.warpEndpoint = tunnel.profile.endpoint
        persist()
        return tunnel
    }

    private func runningConfigMatches(_ id: String, path: URL?) -> Bool {
        if let gatewayBackend {
            return gatewayBackend.nodeID == id && gatewayBackend.primary.configuration == path
                && gatewayBackend.alive && nodes.first(where: { $0.id == id })?.endpointSignature == gatewayBackend.endpointSignature
        }
        guard let node = nodes.first(where: { $0.id == id }),
              let path, let data = try? Data(contentsOf: path) else { return false }
        return HarborIndependentWARP.isBuiltIn(node)
            ? activeWARPProfile.map {
                HarborWARPConfig.matches(configuration: data, profile: $0,
                                        httpPort: gatewayBackend?.primary.port ?? localPort ?? configuredHTTPPort)
              } ?? false
            : node.protocolName == "openvpn"
            ? HarborMihomoConfig.matches(configuration: data, node: node,
                                         underlaySocksPort: underlayPort.map { $0 + 1 },
                                         warpProfile: activeWARPProfile)
            : HarborProxyRuntimeIdentity.matches(configuration: data, node: node)
    }

    private lazy var proxyDiagnostics = HarborProxyDiagnostics(
        destination: root.appendingPathComponent("proxy-switch-diagnostics.log"))

    /// Structured, bounded audit. Node IDs are hashed; error text, endpoints,
    /// subscription URLs and credentials never enter the journal.
    private func proxyAudit(_ event: String, nodeID: String? = nil, note: String = "",
                            category explicitCategory: HarborProxyErrorCategory? = nil) {
        let marker = nodeID.map { id in
            SHA256.hash(data: Data(id.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        }
        var fields = HarborProxyDiagnosticEvent.fields(from: note)
        fields["pid"] = String(child?.processIdentifier ?? adoptedPID ?? 0)
        fields["port"] = String(localPort ?? 0)
        let category: HarborProxyErrorCategory?
        if let explicitCategory { category = explicitCategory }
        else {
            switch event {
            case "underlay_listener_failed": category = .underlayUnavailable
            case "health_identity_mismatch", "runtime_config_mismatch", "periodic_identity_mismatch":
                category = .configurationIdentityMismatch
            case "health_failed", "gateway_candidate_failed", "switch_preflight_failed":
                category = .httpsUnreachable
            case "gateway_backend_unavailable", "unexpected_xray_exit", "startup_failed":
                category = .engineStartFailed
            case "gateway_port_migration_failed", "rollback_system_proxy_failed": category = .systemProxyConflict
            case "vpngate_warp_unavailable": category = .warpUnavailable
            case "gateway_recovery_failed", "rollback_failed", "switch_failed": category = .recoveryFailed
            case "old_stop_failed": category = .cleanupFailed
            default: category = nil
            }
        }
        let transaction = connectionCoordinator.current
        let elapsed = transaction.map { value -> Int in
            let parts = value.startedAt.duration(to: .now).components
            return max(0, Int(parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000))
        }
        proxyDiagnostics.append(HarborProxyDiagnosticEvent(
            event: event, transactionID: transaction?.id, generation: transaction?.generation ?? connectionGeneration,
            engineID: gatewayBackend?.primary.id, nodeHash: marker,
            engineType: gatewayBackend.map { $0.primary.kind == .xray ? "xray" : "mihomo" },
            connectionState: connectionPhase, networkEpoch: connectionCoordinator.networkEpoch,
            errorCategory: category, failureStage: fields["stage"], durationMilliseconds: elapsed,
            retryCount: gatewayHealthPolicy.recoveryAttempts, fields: fields))
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
        if localGateway != nil, !HarborSystemProxy.activeUsesManagedListener {
            // Leave inactive-service records intact. The active service may
            // belong to another application; enable() checks it independently.
            systemManaged = false
            refreshSystemProxyState()
            return false
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
        let pathMonitor = NWPathMonitor()
        pathMonitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor [weak self] in self?.updateNetworkAvailability(online) }
        }
        pathMonitor.start(queue: DispatchQueue(label: "com.codexharbor.proxy.network-path", qos: .utility))
        networkPathMonitor = pathMonitor
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

    private func updateNetworkAvailability(_ online: Bool) {
        guard online != networkOnline else { return }
        networkOnline = online
        gatewayHealthPolicy.networkChanged(online: online)
        cancelGatewayRecovery(reset: false)
        activeHealthCancellation?.cancel()
        connectionCoordinator.networkChanged()
        formalWARPDiscovery.invalidate()
        warpDiscoveryPool.invalidate()
        cancelActiveExitClassification()
        gatewayBackend?.observedExitIP = nil
        activationPreflightCancellation?.cancel()
        if !online {
            if localGateway != nil {
                healthy = false
                checkingConnectivity = false
                connectionPhase = .offline
                status = "网络离线 · 已暂停恢复"
            }
        } else if gatewayBackend != nil {
            lastActiveHealthCheckAt = nil
            connectionPhase = .degraded
            scheduleGatewayRecovery(.recheck(afterSeconds: 0))
        }
        refreshProbeNetwork()
    }

    private func cancelGatewayRecovery(reset: Bool) {
        gatewayRecoveryToken = UUID()
        gatewayRecoveryTask?.cancel()
        gatewayRecoveryTask = nil
        if reset { gatewayHealthPolicy.recordHealthy() }
    }

    private func scheduleGatewayRecovery(_ action: HarborProxyHealthPolicy.Action) {
        guard gatewayRecoveryTask == nil, networkOnline, !shuttingDownConnection,
              let nodeID = activeNodeID, localGateway != nil else { return }
        let delay: Int
        switch action {
        case .none: return
        case .recheck(let seconds), .recover(let seconds), .cooldown(let seconds):
            delay = seconds
        }
        let token = UUID()
        gatewayRecoveryToken = token
        let generation = connectionGeneration
        if case .cooldown = action {
            connectionPhase = .failed
            status = "代理恢复失败 · 退避中"
            detail = "将在 \(delay) 秒后重新尝试当前节点，未绕过代理"
        }
        gatewayRecoveryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            guard let self, self.gatewayRecoveryToken == token else { return }
            self.gatewayRecoveryTask = nil
            guard self.networkOnline, !self.shuttingDownConnection, !Task.isCancelled,
                  self.connectionGeneration == generation, self.activeNodeID == nodeID else { return }
            if self.connectionTransition || self.activationInProgress || self.busy || self.checkingConnectivity {
                // Retry only after other operations finish; never enqueue a
                // recovery ahead of a newer explicit user request.
                if !self.connectionCoordinator.hasPending {
                    let deferred: HarborProxyHealthPolicy.Action
                    switch action {
                    case .recheck: deferred = .recheck(afterSeconds: 5)
                    case .recover: deferred = .recover(afterSeconds: 5)
                    case .cooldown: deferred = .cooldown(afterSeconds: 5)
                    case .none: deferred = .none
                    }
                    self.scheduleGatewayRecovery(deferred)
                }
                return
            }
            if case .recheck = action, self.coreProcessAlive {
                await self.verify()
                return
            }
            if case .cooldown = action { self.gatewayHealthPolicy.cooldownElapsed() }
            guard self.gatewayHealthPolicy.beginRecovery() else {
                self.scheduleGatewayRecovery(self.gatewayHealthPolicy.recoveryFailed())
                return
            }
            self.connectionPhase = .recovering
            self.status = "正在恢复当前节点"
            self.proxyAudit("gateway_recovery_started", nodeID: nodeID,
                            note: "attempt=\(self.gatewayHealthPolicy.recoveryAttempts)")
            await self.queueActivation(nodeID, restart: true, userInitiated: false)
            guard !self.shuttingDownConnection, !Task.isCancelled,
                  self.gatewayRecoveryToken == token,
                  self.connectionGeneration == generation,
                  self.activeNodeID == nodeID, !self.healthy else { return }
            self.proxyAudit("gateway_recovery_failed", nodeID: nodeID)
            if self.gatewayHealthPolicy.recoveryAttempts >= HarborProxyHealthPolicy.recoveryLimit {
                await self.tryAuthorizedFallback(from: nodeID)
                guard !self.shuttingDownConnection, !Task.isCancelled,
                      self.gatewayRecoveryToken == token, self.connectionGeneration == generation,
                      self.activeNodeID == nodeID, !self.healthy else { return }
            }
            self.scheduleGatewayRecovery(self.gatewayHealthPolicy.recoveryFailed())
        }
    }

    /// At most three distinct explicitly authorized backups per manual
    /// connection, at least 60 seconds apart. Never infer authorization
    /// from favorites or subscription membership.
    private func tryAuthorizedFallback(from nodeID: String) async {
        guard fallbackPolicy.enabled, networkOnline, !shuttingDownConnection,
              !connectionTransition, !activationInProgress, !connectionCoordinator.hasPending,
              let original = activeNode, original.id == nodeID,
              let backend = gatewayBackend, backend.nodeID == nodeID,
              let ip = backend.observedExitIP,
              let evidence = nodeExitNetworkEvidence[nodeID],
              evidence.networkEpoch == connectionCoordinator.networkEpoch,
              let constraint = HarborProxyFallbackPolicy.ExitConstraint(evidence: evidence, observedIP: ip)
        else { return }
        if let lastFallbackAttempt, lastFallbackAttempt.duration(to: .now) < .seconds(60) { return }
        attemptedFallbackIDs.insert(nodeID)
        guard attemptedFallbackIDs.count < 4 else { return }
        let candidates = nodes.filter {
            $0.id != nodeID && !attemptedFallbackIDs.contains($0.id)
                && fallbackPolicy.permits(nodeID: $0.id, signature: $0.endpointSignature)
                && $0.protocolName == original.protocolName
                && supportsCore(for: $0)
        }.sorted { $0.id < $1.id }
        guard let candidate = candidates.first else { return }
        attemptedFallbackIDs.insert(candidate.id)
        lastFallbackAttempt = .now
        switchingNodeID = candidate.id
        status = "正在验证已授权备用节点"
        proxyAudit("authorized_fallback_started", nodeID: candidate.id)
        await HarborProbeScope.$priority.withValue(.recovery) {
            await activateOne(candidate.id, restart: true, userInitiated: false, fallback: constraint)
        }
        if !activationInProgress { switchingNodeID = nil }
        if activeNodeID == candidate.id && healthy {
            proxyAudit("authorized_fallback_succeeded", nodeID: candidate.id)
        } else {
            proxyAudit("authorized_fallback_rejected", nodeID: candidate.id)
        }
    }

    private func refreshProbeNetwork() {
        guard configurationLoaded, let route = HarborSystemProxy.currentNetworkFingerprintInput() else { return }
        let key = Data(SHA256.hash(data: Data(route.utf8))).base64EncodedString()
        guard store.probeNetworkFingerprint != key else { return }
        if store.probeNetworkFingerprint != nil {
            connectionCoordinator.networkChanged()
            formalWARPDiscovery.invalidate()
            warpDiscoveryPool.invalidate()
            cancelActiveExitClassification()
            gatewayBackend?.observedExitIP = nil
            activeHealthCancellation?.cancel()
            activationPreflightCancellation?.cancel()
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
        var resident: HarborProxyAgentSnapshot?
        if FileManager.default.fileExists(atPath: HarborProxyAgentConstants.journalURL.path) {
            do { resident = try await HarborProxyAgentClient.shared.inspect() }
            catch {
                detail = "独立代理服务记录尚未确认，已暂停启动清理：" + error.localizedDescription
                return
            }
        }
        var protectedPaths = Set((resident?.engines ?? []).flatMap { [$0.configurationPath, $0.directoryPath] })
        for id in (resident?.pendingLaunchPorts ?? [:]).keys {
            let file = probeRoot.appendingPathComponent("probe-runtime-\(id.uuidString).json")
            protectedPaths.insert(file.path)
            protectedPaths.insert(file.deletingPathExtension().appendingPathExtension("data").path)
        }
        await HarborWARPTunnel.cleanupOrphans(root: probeRoot, protectedPaths: protectedPaths)
        await HarborProbeFiles.cleanOrphans(root: probeRoot, protectedPaths: protectedPaths)
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
                nodeExitNetworkEvidence = state.nodeExitNetworkEvidence ?? [:]
                probeResults = state.probeResults ?? [:]
                subscriptions = state.subscriptions
                subscriptionUpdatedAt = state.subscriptionUpdatedAt ?? [:]
                probeNetworkChangedAt = state.probeNetworkChangedAt ?? .distantPast
                selectedID = state.selectedID
                vpnGateUnderlayNodeID = state.vpnGateUnderlayNodeID
                routingRules = state.routingRules
                autoManageSystemProxy = state.autoManageSystemProxy ?? true
                resumeConnectionOnLaunch = state.resumeConnectionOnLaunch ?? HarborSystemProxy.hasBackup
                fallbackPolicy = state.fallbackPolicy ?? HarborProxyFallbackPolicy()
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
        var migration: LegacyMigration?
        if FileManager.default.fileExists(atPath: legacyMigrationURL.path) {
            guard let data = try? Data(contentsOf: legacyMigrationURL), data.count <= 4096,
                  let saved = try? JSONDecoder().decode(LegacyMigration.self, from: data),
                  [saved.oldPort, saved.stagingPort, saved.targetPort].allSatisfy({ (1024...65534).contains($0) }),
                  abs(saved.stagingPort - saved.oldPort) > 1,
                  abs(saved.stagingPort - saved.targetPort) > 1 else {
                detail = "旧代理迁移记录无法核对，已停止自动清理"
                return
            }
            migration = saved
            if FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
                let stagedRoute = resident?.gateways.first(where: { $0.port == saved.stagingPort })
                let stagedCommitted = stagedRoute?.route != nil &&
                    stagedRoute?.routingBackendID == stagedRoute?.route?.primaryID && stagedRoute?.ready == true
                if HarborSystemProxy.referencesListener(saved.oldPort) || !stagedCommitted {
                    // The system still points at the legacy listener, or the
                    // staged route never became live. Never
                    // adopt a staging route as though it had replaced it.
                    if HarborSystemProxy.referencesListener(saved.stagingPort) {
                        detail = "旧入口和迁移入口均被引用，保留两个入口，请先恢复系统代理"
                        return
                    }
                    if let current = resident {
                        runtimeSupervisor.adoptSnapshot(current)
                        for entry in current.gateways {
                            guard entry.port == saved.stagingPort,
                                  let gateway = try? HarborAgentGateway(httpPort: entry.port),
                                  await gateway.stop() else {
                                detail = "迁移入口回收未确认，保留旧连接"
                                return
                            }
                        }
                        guard await runtimeSupervisor.reap(excluding: []) else {
                            detail = "迁移候选尚未清理，保留旧连接"; return
                        }
                        resident = nil
                        HarborProxyAgentClient.shared.disconnect()
                    }
                    try? FileManager.default.removeItem(at: legacyMigrationURL)
                    migration = nil
                } else {
                    await cleanupOrphan()
                    guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                        detail = "旧内核清理未确认，保留迁移入口与记录"
                        return
                    }
                }
            }
        }
        if let resident {
            runtimeSupervisor.adoptSnapshot(resident)
            if !resident.gateways.isEmpty {
                guard adoptResidentProxy(resident) else {
                    detail = "独立代理服务状态尚未确认，保留入口与内核记录"
                    return
                }
                if let migration, let backend = gatewayBackend {
                    if localPort == migration.stagingPort {
                        await finishLegacyMigration(migration, policy: backend.policy)
                    } else if localPort == migration.targetPort {
                        if let extra = migrationGateway, extra.port == migration.stagingPort,
                           await extra.stop() { migrationGateway = nil }
                        if migrationGateway == nil {
                            try? FileManager.default.removeItem(at: legacyMigrationURL)
                        }
                    }
                }
                bootstrapped = true
                startLivenessMonitoring()
                scheduleGeoIPRefresh()
                if running, let activeNode { enqueueExitGeoRefresh(for: [activeNode]) }
                if !running, resumeConnectionOnLaunch, let selectedNode {
                    await queueActivation(selectedNode.id, restart: false, userInitiated: false)
                }
                return
            }
            guard await runtimeSupervisor.reap(excluding: []) else {
                detail = "独立代理服务遗留内核尚未清理"; return
            }
            HarborProxyAgentClient.shared.disconnect()
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
        if !connectionCoordinator.hasPending, resumeConnectionOnLaunch,
           let selectedNode, supportsCore(for: selectedNode) {
            await queueActivation(selectedNode.id, restart: false, userInitiated: false)
        }
        scheduleGeoIPRefresh()
        scheduleLegacyRealPingRetest()
        Task { [weak self] in await self?.retryDueFailedNodes() }
    }

    private func residentBackend(_ route: HarborProxyAgentRoute) -> GatewayBackend? {
        guard let primary = runtimeSupervisor.engine(route.primaryID) else { return nil }
        let base = route.underlayID.flatMap { runtimeSupervisor.engine($0) }
        guard route.underlayID == nil || base != nil else { return nil }
        let warp = route.warpEndpoint.flatMap { endpoint in
            store.warpAccount.map { HarborWARPProfile(account: $0, endpoint: endpoint) }
        }
        return GatewayBackend(nodeID: route.nodeID, endpointSignature: route.endpointSignature,
            observedExitIP: route.observedExitIP, primary: primary, underlay: base,
            underlayID: route.underlayNodeID, warp: warp,
            warpExitIP: route.nodeID == HarborIndependentWARP.nodeID ? route.observedExitIP : nil,
            policy: RoutingPolicy(ruleMode: route.ruleMode, forcedDomains: route.forcedDomains,
                                  localHostAddresses: route.localHostAddresses))
    }

    private func adoptResidentProxy(_ snapshot: HarborProxyAgentSnapshot) -> Bool {
        guard let entry = snapshot.gateways.first(where: { $0.port == HarborSystemProxy.ownedHTTPPort })
                ?? snapshot.gateways.first(where: { $0.port == configuredHTTPPort })
                ?? snapshot.gateways.first,
              let gateway = try? HarborAgentGateway(httpPort: entry.port) else { return false }
        gateway.refresh(snapshot)
        localGateway = gateway
        localPort = entry.port
        configuredHTTPPort = entry.port
        if let other = snapshot.gateways.first(where: { $0.port != entry.port }),
           let extra = try? HarborAgentGateway(httpPort: other.port) {
            extra.refresh(snapshot)
            migrationGateway = extra
            if let route = other.route, route.primaryID != entry.route?.primaryID {
                drainingBackend = residentBackend(route)
            }
        }
        gatewayBackend = entry.route.flatMap { residentBackend($0) }
        if entry.route != nil && gatewayBackend == nil { return false }
        running = gatewayBackend != nil
        if let backend = gatewayBackend {
            let matches = nodes.contains { $0.id == backend.nodeID && $0.endpointSignature == backend.endpointSignature }
            activeNodeID = matches ? backend.nodeID : nil
            configPath = backend.primary.configuration
            underlayConfigPath = backend.underlay?.configuration
            underlayPort = backend.underlay?.port
            activeWARPProfile = backend.warp
            activePolicy = backend.policy
            vpnGateUnderlayNodeID = backend.underlayID
            healthy = matches && backend.alive && entry.healthy && entry.ready
                && entry.routingBackendID == backend.primary.id
            lastSuccessfulHealthCheckAt = healthy ? entry.lastHealth : nil
            lastActiveHealthCheckAt = entry.lastHealth
            warpExitIP = healthy ? backend.warpExitIP : nil
        } else { healthy = false }
        connectionGeneration &+= 1
        connectionPhase = running ? (healthy ? .connected : .degraded) : .stopped
        status = healthy ? "已连接" : "独立代理入口已保留"
        detail = "已核对独立代理服务 HTTP 127.0.0.1:\(entry.port)"
        refreshSystemProxyState(synchronizeOwnership: true)
        return true
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

    /// Exit network classification is intentionally separate from entry
    /// screening. An observed IP is required; subscription remarks or the
    /// VPN Gate publisher country cannot populate this field.
    func exitNetworkEvidence(for node: HarborProxyNode) -> HarborProxyNetworkEvidence? {
        let ip = HarborIndependentWARP.isBuiltIn(node) && node.id == activeNodeID
            ? warpExitIP : observedExit(for: node)?.ip
        guard let ip, let evidence = nodeExitNetworkEvidence[node.id], evidence.isFresh(),
              let evidenceIP = evidence.observedIP, HarborIPAddress.equivalent(ip, evidenceIP) else { return nil }
        if node.id == activeNodeID {
            guard healthy, evidence.networkEpoch == connectionCoordinator.networkEpoch,
                  evidence.probeRouteID == activeExitEvidenceRouteID else { return nil }
        }
        return evidence
    }

    private var activeExitEvidenceRouteID: String? {
        activeWARPProfile?.routeID ?? currentVPNGateRouteID
    }

    private func cancelActiveExitClassification() {
        exitObservationCancellation?.cancel()
        exitObservationTask?.cancel()
        exitObservationCancellation = nil
        exitObservationTask = nil
        exitClassificationCancellation?.cancel()
        exitClassificationTask?.cancel()
        exitClassificationCancellation = nil
        exitClassificationTask = nil
        exitClassificationKey = nil
    }

    private func scheduleActiveExitClassification() {
        guard networkOnline, running, healthy, !shuttingDownConnection,
              let node = activeNode, let port = localPort else { return }
        let isWarp = HarborIndependentWARP.isBuiltIn(node)
        if !isWarp, let backend = gatewayBackend, backend.observedExitIP == nil {
            observeActiveGatewayExit(node: node, port: port, backendID: backend.primary.id)
            return
        }
        let ip = isWarp ? warpExitIP : (gatewayBackend?.observedExitIP ?? observedExit(for: node)?.ip)
        guard let ip, HarborNodeGeoIPResolver.isPublic(ip) else { return }
        let epoch = connectionCoordinator.networkEpoch
        let generation = connectionGeneration
        let route = activeExitEvidenceRouteID
        let key = "\(generation):\(epoch):\(node.id):\(ip)"
        if exitNetworkEvidence(for: node) != nil || exitClassificationKey == key { return }
        cancelActiveExitClassification()
        // Classification can reuse evidence for the same explicit IP, but
        // the per-node association remains scoped to this observed route.
        if let existing = nodeExitNetworkEvidence.values.first(where: {
            $0.isFresh() && $0.observedIP.map { HarborIPAddress.equivalent($0, ip) } == true
        }) {
            nodeExitNetworkEvidence[node.id] = HarborProxyNetworkEvidence(
                kind: existing.kind, isp: existing.isp, checkedAt: existing.checkedAt,
                sources: existing.sources, confidence: existing.confidence, countryCode: existing.countryCode,
                observedIP: ip, networkEpoch: epoch, probeRouteID: route)
            persist()
            return
        }
        let cancellation = HarborLatencyCancellation()
        exitClassificationCancellation = cancellation
        exitClassificationKey = key
        exitClassificationTask = Task(priority: .utility) { [weak self] in
            let evidence = await HarborVPNGateNetworkClassifier.lookup(ip: ip, proxyPort: port,
                    cancellation: cancellation, networkEpoch: epoch, probeRouteID: route)
            guard let self, self.exitClassificationCancellation === cancellation else { return }
            defer {
                self.exitClassificationCancellation = nil
                self.exitClassificationTask = nil
                self.exitClassificationKey = nil
            }
            guard !cancellation.isCancelled, !Task.isCancelled, self.running, self.healthy,
                  self.connectionGeneration == generation, self.connectionCoordinator.networkEpoch == epoch,
                  self.activeNodeID == node.id, let evidence else { return }
            let actual = self.currentVerifiedExitIP
            guard let actual, HarborIPAddress.equivalent(actual, ip) else { return }
            self.nodeExitNetworkEvidence[node.id] = evidence
            self.persist()
        }
    }

    /// Ordinary connections become usable before optional IP services answer.
    /// Record their result only for the exact live route tested.
    private func observeActiveGatewayExit(node: HarborProxyNode, port: Int, backendID: UUID) {
        guard exitObservationTask == nil else { return }
        let cancellation = HarborLatencyCancellation()
        exitObservationCancellation = cancellation
        let generation = connectionGeneration
        let epoch = connectionCoordinator.networkEpoch
        exitObservationTask = Task(priority: .utility) { [weak self] in
            guard let self else { return }
            defer {
                if self.exitObservationCancellation === cancellation {
                    self.exitObservationCancellation = nil
                    self.exitObservationTask = nil
                }
            }
            @MainActor func isCurrent() -> Bool {
                !Task.isCancelled && !cancellation.isCancelled && !self.shuttingDownConnection
                    && self.healthy && self.connectionGeneration == generation
                    && self.connectionCoordinator.networkEpoch == epoch && self.localPort == port
                    && self.activeNodeID == node.id && self.gatewayBackend?.primary.id == backendID
            }
            guard let ip = await self.gatewayObservedExit(socksPort: port + 1, cancellation: cancellation,
                                                          priority: .geoIP),
                  isCurrent(),
                  (try? await HarborProxyAgentClient.shared.call(.recordExit(port: port, backendID: backendID, ip: ip))) != nil,
                  isCurrent() else { return }
            self.gatewayBackend?.observedExitIP = ip
            let existing = self.nodeExitLocations[node.id]?.location
            let measured = existing.flatMap { $0.ip == ip ? $0 : nil }
                ?? HarborProxyIPLocation(ip: ip, countryCode: "ZZ")
            self.nodeExitLocations[node.id] = HarborProxyExitLocation(
                location: measured, endpointSignature: node.endpointSignature,
                resolvedServerIP: self.entranceLocation(for: node)?.ip, probeRouteID: self.currentVPNGateRouteID)
            self.persist()
            self.exitObservationTask = nil
            self.exitObservationCancellation = nil
            self.scheduleActiveExitClassification()
        }
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
        let validNodeIDs = Set(nodes.map(\.id))
        nodeExitNetworkEvidence = nodeExitNetworkEvidence.filter { validNodeIDs.contains($0.key) }
        store.nodeExitNetworkEvidence = nodeExitNetworkEvidence
        store.probeResults = probeResults
        store.subscriptions = subscriptions
        store.selectedID = selectedID
        store.vpnGateUnderlayNodeID = vpnGateUnderlayNodeID
        store.routingRules = routingRules
        store.forcedProxyDomains = forcedProxyDomains
        store.httpListenPort = configuredHTTPPort
        store.autoManageSystemProxy = autoManageSystemProxy
        store.resumeConnectionOnLaunch = resumeConnectionOnLaunch
        fallbackPolicy.authorizedEndpoints = fallbackPolicy.authorizedEndpoints.filter { id, signature in
            nodes.contains { $0.id == id && $0.endpointSignature == signature }
        }
        store.fallbackPolicy = fallbackPolicy
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

    func setAutomaticFallback(_ enabled: Bool) {
        guard configurationLoaded else { return }
        fallbackPolicy.enabled = enabled
        persist()
    }

    func isAuthorizedFallback(_ node: HarborProxyNode) -> Bool {
        fallbackPolicy.authorizedEndpoints[node.id] == node.endpointSignature
    }

    func toggleFallbackAuthorization(_ node: HarborProxyNode) {
        guard configurationLoaded, nodes.contains(where: { $0.id == node.id && $0.endpointSignature == node.endpointSignature }) else { return }
        if isAuthorizedFallback(node) {
            fallbackPolicy.authorizedEndpoints.removeValue(forKey: node.id)
        } else {
            fallbackPolicy.authorizedEndpoints[node.id] = node.endpointSignature
        }
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
        var tunnel: HarborWARPDiscoveryPool.Lease?
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
            ranked, cached: nodeNetworkEvidence, proxyPort: usedProxyPort, cancellation: classification,
            networkEpoch: connectionCoordinator.networkEpoch, probeRouteID: source)
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
        if userInitiated {
            cancelGatewayRecovery(reset: true)
            attemptedFallbackIDs = [id]
            lastFallbackAttempt = nil
        }
        activeHealthCancellation?.cancel()
        guard connectionCoordinator.enqueue(id, restart: restart, userInitiated: userInitiated) else { return }
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

        while let request = connectionCoordinator.takeNext() {
            defer { connectionCoordinator.finishRequest(request) }
            // Startup, subscription refresh, and another switch can be in progress.
            // Keep the request queued instead of disabling every node button.
            while busy || installingCore || connectionTransition || (bootstrapping && !bootstrapped) {
                guard !shuttingDownConnection, !Task.isCancelled else { return }
                do { try await Task.sleep(for: .milliseconds(100)) } catch { return }
            }
            // A newer click arrived while waiting for another operation.
            // Do not start an obsolete preflight or stop the active core.
            if shuttingDownConnection || Task.isCancelled { return }
            if !connectionCoordinator.accepts(request) { continue }
            let priority: HarborProbePriority = request.userInitiated ? .switching : .recovery
            await HarborProbeScope.$priority.withValue(priority) {
                await activateOne(request.nodeID, restart: request.restart, userInitiated: request.userInitiated)
            }
        }
    }

    private func activateOne(_ id: String, restart: Bool, userInitiated: Bool,
                             replacementPort: Int? = nil,
                             fallback: HarborProxyFallbackPolicy.ExitConstraint? = nil) async {
        guard !shuttingDownConnection, !connectionTransition else { return }
        guard networkOnline else {
            detail = "当前网络离线，已暂停代理连接"
            return
        }
        guard let requestedNode = nodes.first(where: { $0.id == id }) else {
            detail = "所选节点已不存在"
            return
        }
        connectionTransition = true
        defer { connectionTransition = false }
        let cancellation = HarborLatencyCancellation()
        guard let transaction = connectionCoordinator.begin(nodeID: id, endpointSignature: requestedNode.endpointSignature,
                                                timeout: .seconds(300), source: replacementPort != nil ? .reconfiguration : (userInitiated ? .user : (running ? .recovery : .startup))) else { return }
        activationPreflightCancellation = cancellation
        let deadlineTask = Task {
            do { try await Task.sleep(until: transaction.deadline, clock: .continuous) }
            catch { return }
            cancellation.cancel()
        }
        defer {
            deadlineTask.cancel()
            connectionCoordinator.finish(transaction)
            activationPreflightCancellation = nil
        }
        func transactionValid() -> Bool {
            (fallback == nil || fallbackPolicy.permits(nodeID: id, signature: requestedNode.endpointSignature))
                && !connectionCoordinator.hasPending && !shuttingDownConnection && !cancellation.isCancelled
                && !Task.isCancelled && connectionCoordinator.accepts(transaction, endpointSignature:
                    nodes.first(where: { $0.id == id })?.endpointSignature)
        }
        let previousID = activeNodeID
        let previousPort = localPort ?? configuredHTTPPort
        let wasRunning = running
        let wantsSystemProxy = HarborProxyConnectionIntent.shouldManageSystemProxy(
            persistedPreference: autoManageSystemProxy,
            userInitiated: userInitiated
        )

        // The requested profile is only committed after its Xray listeners
        // and actual outbound identity have been verified.
        proxyAudit("switch_requested", nodeID: id, note: "running=\(wasRunning)")

        if wasRunning && previousID == id && !restart && localGateway != nil {
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
        guard transactionValid() else { return }
        // Pause bulk probing before preflight so activation does not compete
        // with multiple temporary engines for CPU and connection slots.
        if latencyTesting { cancelLatencyTests() }
        // Legacy adopted listeners stay intact until explicitly stopped. New
        // connections and every subsequent switch use a fixed TCP gateway.
        if localGateway != nil || (!wasRunning && child == nil && underlayChild == nil
            && adoptedPID == nil && !FileManager.default.fileExists(atPath: runtimeRecordURL.path)) {
            await activateGateway(requestedNode, policy: policy, replacementPort: replacementPort,
                                  wantsSystemProxy: wantsSystemProxy, userInitiated: userInitiated,
                                  cancellation: cancellation, transactionValid: transactionValid, fallback: fallback)
            return
        }
        guard fallback == nil else { return }
        await migrateLegacyConnection(requestedNode, policy: policy,
            targetPort: replacementPort ?? previousPort, wantsSystemProxy: wantsSystemProxy,
            userInitiated: userInitiated, cancellation: cancellation, transactionValid: transactionValid)
    }

    /// Stage a verified resident route on a separate loopback pair before
    /// touching the old process or its system proxy. The same tested engine
    /// is then attached to the requested fixed port after the legacy pair
    /// becomes free. Persist the migration intent for crash reconciliation.
    private func migrateLegacyConnection(
        _ node: HarborProxyNode, policy: RoutingPolicy, targetPort: Int,
        wantsSystemProxy: Bool, userInitiated: Bool,
        cancellation: HarborLatencyCancellation, transactionValid: () -> Bool
    ) async {
        guard !FileManager.default.fileExists(atPath: legacyMigrationURL.path) else {
            detail = "上次迁移尚未结束，请先断开代理并完成清理"
            return
        }
        guard running, let oldPort = localPort, localGateway == nil else {
            detail = "旧代理状态未确认，请先恢复原系统代理并清理旧内核"
            return
        }
        guard !HarborSystemProxy.otherServiceReferencesListener(oldPort),
              !HarborSystemProxy.referencesListener(oldPort) || HarborSystemProxy.ownedHTTPPort == oldPort else {
            detail = "旧入口仍被其他网络服务使用，已保留原连接；请先处理系统代理冲突"
            return
        }
        guard let stage = (18100...18198).filter({ $0 % 2 == 0 }).first(where: {
            abs($0 - oldPort) > 1 && abs($0 - targetPort) > 1 &&
            !portListening($0) && !portListening($0 + 1) && !HarborSystemProxy.referencesListener($0)
        }), let staging = try? HarborAgentGateway(httpPort: stage) else {
            detail = "没有可安全使用的迁移入口，旧连接未改变"
            return
        }
        let record = LegacyMigration(oldPort: oldPort, stagingPort: stage, targetPort: targetPort,
                                     wasManaged: HarborSystemProxy.ownedHTTPPort == oldPort)
        do { try HarborProbeFiles.replace(JSONEncoder().encode(record), at: legacyMigrationURL) }
        catch { detail = "迁移记录无法写入，旧连接未改变"; return }

        var candidate: GatewayBackend?
        do {
            guard await runtimeSupervisor.reap(excluding: []), transactionValid() else {
                throw HarborProxyError.invalid("残留候选尚未回收")
            }
            try await staging.start()
            var protected = Set([oldPort, oldPort + 1, stage, stage + 1, targetPort, targetPort + 1])
            if let underlayPort { protected.formUnion([underlayPort, underlayPort + 1]) }
            let verified = try await prepareGatewayCandidate(node, policy: policy,
                protectedPorts: protected, cancellation: cancellation)
            candidate = verified
            guard transactionValid(), verified.alive else { throw CancellationError() }
            try await staging.route(to: verified.agentRoute(), cancellation: cancellation)
            guard transactionValid(), verified.alive else { throw CancellationError() }
            if record.wasManaged {
                guard HarborSystemProxy.ownedHTTPPort == oldPort else {
                    throw HarborProxyError.invalid("系统代理所有权已变化")
                }
                try await HarborSystemProxy.enable(port: stage, forcedProxyDomains: policy.forcedDomains,
                                                   automaticBypass: policy.localHosts)
                guard HarborSystemProxy.ownedHTTPPort == stage else {
                    throw HarborProxyError.invalid("迁移入口未确认生效")
                }
            }
            guard !HarborSystemProxy.referencesListener(oldPort), transactionValid() else {
                throw HarborProxyError.invalid("旧入口仍被引用或迁移已取消")
            }
            // Legacy stop is allowed only after the system has ceased using
            // it. Keep the new route even if cleanup cannot be confirmed.
            guard await stopCore() else { throw HarborProxyError.invalid("旧内核尚未完全退出") }
            guard let snapshot = try? await HarborProxyAgentClient.shared.inspect(),
                  adoptResidentProxy(snapshot) else {
                detail = "迁移入口已保留，等待重新核对独立服务"
                return
            }
            autoManageSystemProxy = wantsSystemProxy
            selectedID = node.id
            if userInitiated { resumeConnectionOnLaunch = true }
            await finishLegacyMigration(record, policy: policy)
            if !record.wasManaged, wantsSystemProxy, transactionValid(), healthy {
                await applySystemProxy(interactive: userInitiated, policy: policy)
            }
            startLivenessMonitoring()
            persist()
        } catch {
            if record.wasManaged && HarborSystemProxy.ownedHTTPPort == stage &&
                portListening(oldPort) && portListening(oldPort + 1) {
                // Rollback only while our staging settings remain owned.
                _ = try? await HarborSystemProxy.enable(port: oldPort, forcedProxyDomains: activePolicy?.forcedDomains ?? policy.forcedDomains,
                    automaticBypass: activePolicy?.localHosts ?? policy.localHosts)
            }
            if !HarborSystemProxy.referencesListener(stage), await staging.stop() {
                if let candidate { await disposeGatewayBackend(candidate) }
                try? FileManager.default.removeItem(at: legacyMigrationURL)
                detail = "旧代理迁移未完成，保留原连接：" + error.localizedDescription
            } else {
                detail = "迁移入口可能仍被系统使用，已保留进程和恢复记录：" + error.localizedDescription
            }
        }
    }

    /// Reuse the staged engine. Do not stop it merely to return to the
    /// configured port. A failed final bind leaves the staging route usable.
    private func finishLegacyMigration(_ record: LegacyMigration, policy: RoutingPolicy) async {
        guard let staging = localGateway, staging.port == record.stagingPort,
              let backend = gatewayBackend, backend.alive,
              !FileManager.default.fileExists(atPath: runtimeRecordURL.path),
              let target = try? HarborAgentGateway(httpPort: record.targetPort) else { return }
        do {
            try await target.start()
            try await target.route(to: backend.agentRoute())
            if record.wasManaged {
                guard HarborSystemProxy.ownedHTTPPort == record.stagingPort else {
                    throw HarborProxyError.invalid("迁移入口所有权已变化")
                }
                try await HarborSystemProxy.enable(port: record.targetPort,
                    forcedProxyDomains: policy.forcedDomains, automaticBypass: policy.localHosts)
                guard HarborSystemProxy.ownedHTTPPort == record.targetPort else {
                    throw HarborProxyError.invalid("固定入口未确认生效")
                }
            }
            localGateway = target
            localPort = record.targetPort
            configuredHTTPPort = record.targetPort
            if await staging.stop() {
                migrationGateway = nil
                try? FileManager.default.removeItem(at: legacyMigrationURL)
                detail = "旧代理已迁移至固定入口"
            } else {
                migrationGateway = staging
                detail = "固定入口已迁移，旧迁移入口仍被引用"
            }
        } catch {
            if !HarborSystemProxy.referencesListener(record.targetPort) {
                _ = await target.stop()
            } else {
                migrationGateway = target
            }
            detail = "暂时使用已验证迁移入口，原固定端口尚未恢复：" + error.localizedDescription
        }
        refreshSystemProxyState(synchronizeOwnership: true)
    }

    /// Fixed-listener path. Candidate engines are never discarded and
    /// recreated after validation; the exact tested instance becomes active.
    private func activateGateway(
        _ node: HarborProxyNode, policy: RoutingPolicy, replacementPort: Int?,
        wantsSystemProxy: Bool, userInitiated: Bool,
        cancellation: HarborLatencyCancellation, transactionValid: () -> Bool,
        fallback: HarborProxyFallbackPolicy.ExitConstraint? = nil
    ) async {
        connectionPhase = gatewayBackend == nil ? .preparing : .switching
        defer {
            if [.preparing, .validating, .switching].contains(connectionPhase) {
                connectionPhase = !networkOnline ? .offline : (healthy ? .connected : .failed)
            }
        }
        if FileManager.default.fileExists(atPath: legacyMigrationURL.path) {
            guard let data = try? Data(contentsOf: legacyMigrationURL), data.count <= 4096,
                  let record = try? JSONDecoder().decode(LegacyMigration.self, from: data),
                  let backend = gatewayBackend else {
                detail = "旧代理迁移记录尚未确认，请先恢复系统代理"; return
            }
            if localPort == record.stagingPort && migrationGateway == nil {
                await finishLegacyMigration(record, policy: backend.policy)
            }
            guard !FileManager.default.fileExists(atPath: legacyMigrationURL.path) else {
                detail = "旧代理迁移尚未完成，当前已验证入口保持运行"; return
            }
        }
        guard migrationGateway == nil else {
            detail = "上次端口迁移需要恢复系统代理，恢复完成后才能切换"
            return
        }
        let entryPort = replacementPort ?? localPort ?? configuredHTTPPort
        let previousGateway = localGateway
        let previousBackend = gatewayBackend
        let previousPort = localPort
        if let previousPort, entryPort != previousPort,
           HarborSystemProxy.otherServiceReferencesListener(previousPort) {
            detail = "其他网络服务仍使用当前端口，请先恢复系统代理后再更改端口"
            return
        }
        let retained = (previousBackend?.engineIDs ?? []).union(drainingBackend?.engineIDs ?? [])
        guard await runtimeSupervisor.reap(excluding: retained), transactionValid() else {
            detail = "上次候选内核清理尚未完成，原连接保持不变"
            return
        }

        let gateway: HarborAgentGateway
        do {
            if let previousGateway, entryPort == previousPort {
                gateway = previousGateway
            } else {
                gateway = try HarborAgentGateway(httpPort: entryPort)
            }
            if !gateway.isReady { try await gateway.start() }
        } catch {
            detail = "固定代理入口启动失败，未更改系统代理"
            return
        }

        let isNewGateway = previousGateway !== gateway
        func retainOrStopUncommittedGateway() async {
            guard isNewGateway else { return }
            if previousGateway == nil, HarborSystemProxy.referencesListener(entryPort) {
                // An interrupted previous session still points here. Keep the
                // entry bound, with no route, rather than silently bypassing.
                localGateway = gateway
                localPort = entryPort
            } else if !(await gateway.stop()) {
                if previousGateway == nil { localGateway = gateway; localPort = entryPort }
                else { migrationGateway = gateway }
            }
        }

        guard transactionValid() else {
            await retainOrStopUncommittedGateway()
            return
        }

        connectionPhase = .validating
        let candidate: GatewayBackend
        do {
            var protectedPorts = Set([entryPort, entryPort + 1])
            if let previousPort { protectedPorts.formUnion([previousPort, previousPort + 1]) }
            if let previousBackend {
                protectedPorts.formUnion([previousBackend.primary.port, previousBackend.primary.port + 1])
                if let base = previousBackend.underlay { protectedPorts.formUnion([base.port, base.port + 1]) }
            }
            candidate = try await prepareGatewayCandidate(node, policy: policy, protectedPorts: protectedPorts,
                                                          cancellation: cancellation, requiresObservedExit: fallback != nil)
        } catch {
            await retainOrStopUncommittedGateway()
            guard transactionValid() else { return }
            status = previousBackend?.alive == true && previousGateway?.isReady == true ? "已连接" : "连接失败"
            detail = "候选后端验证失败，未切换路由：" + error.localizedDescription
            proxyAudit("gateway_candidate_failed", nodeID: node.id, note: "code=\((error as NSError).code)")
            return
        }

        guard transactionValid(), candidate.alive, gateway.isReady else {
            await disposeGatewayBackend(candidate)
            await retainOrStopUncommittedGateway()
            return
        }

        if let fallback {
            guard let ip = candidate.observedExitIP,
                  let evidence = await HarborVPNGateNetworkClassifier.lookup(ip: ip,
                      proxyPort: candidate.primary.port, cancellation: cancellation,
                      networkEpoch: connectionCoordinator.networkEpoch),
                  transactionValid(), fallback.matches(evidence: evidence, observedIP: ip) else {
                await disposeGatewayBackend(candidate)
                await retainOrStopUncommittedGateway()
                detail = "备用节点实际出口与原连接不一致或证据不足，未切换"
                return
            }
            nodeExitNetworkEvidence[node.id] = evidence
        }

        guard let wasManaged = await prepareSystemProxyForActivation(),
              transactionValid(), candidate.alive else {
            await disposeGatewayBackend(candidate)
            await retainOrStopUncommittedGateway()
            return
        }

        // Bound the number of draining generations. Normal switches keep
        // existing connections on their original engine; a third generation
        // may close the oldest flows to avoid unbounded resource growth.
        if let oldest = drainingBackend {
            _ = await previousGateway?.closeConnections(backendID: oldest.primary.id)
            let disposed = await disposeGatewayBackend(oldest)
            if disposed { drainingBackend = nil }
            let keep = retained.subtracting(oldest.engineIDs).union(candidate.engineIDs)
            guard disposed, await runtimeSupervisor.reap(excluding: keep), transactionValid() else {
                await disposeGatewayBackend(candidate)
                await retainOrStopUncommittedGateway()
                detail = "旧后端尚未回收，未切换路由"
                return
            }
        }

        guard transactionValid(), candidate.alive else {
            await disposeGatewayBackend(candidate)
            await retainOrStopUncommittedGateway()
            return
        }

        // During the fixed-entry trial, a request sent to the old public
        // port can reach the candidate even if the switch later rolls back.
        // Retire all in-flight observations of that port first.
        if !isNewGateway {
            connectionGeneration &+= 1
            activeHealthCancellation?.cancel()
            checkingConnectivity = false
            websiteCancellation?.cancel()
            cancelActiveExitClassification()
        }
        do {
            try await gateway.route(to: candidate.agentRoute(), cancellation: cancellation)
        } catch {
            await disposeGatewayBackend(candidate)
            await retainOrStopUncommittedGateway()
            if gateway === previousGateway, gateway.routingBackendID != previousBackend?.primary.id {
                healthy = false
                connectionPhase = .degraded
            }
            if !cancellation.isCancelled && !shuttingDownConnection {
                detail = "固定入口未提交新线路：" + error.localizedDescription
                if healthy { scheduleActiveExitClassification() }
            }
            return
        }

        // The RPC may have completed after a stop, network change, or
        // newer click. The previous listener is still intact: do not let
        // an obsolete port-change transaction take over system proxy.
        if isNewGateway, previousGateway != nil, !transactionValid() {
            if !HarborSystemProxy.referencesListener(entryPort), await gateway.stop() {
                await disposeGatewayBackend(candidate)
            } else {
                migrationGateway = gateway
                drainingBackend = candidate
                detail = "过期切换的入口尚未安全释放，已保留恢复记录"
            }
            return
        }

        // A port change is the only case that requires changing the owned
        // system listener while a healthy old gateway is still running.
        if isNewGateway, previousGateway != nil, wasManaged {
            do {
                try await HarborSystemProxy.enable(port: entryPort, forcedProxyDomains: policy.forcedDomains,
                                                   automaticBypass: policy.localHosts)
                for _ in 0..<10 where HarborSystemProxy.ownedHTTPPort != entryPort {
                    try? await Task.sleep(for: .milliseconds(60))
                }
            } catch {
                proxyAudit("gateway_port_migration_failed", nodeID: node.id, note: "code=\((error as NSError).code)")
            }
            if HarborSystemProxy.ownedHTTPPort != entryPort {
                // Preserve both listeners if a partial system transaction
                // might still refer to the new port. Explicit restoration
                // will retire the extra listener.
                if let previousBackend, previousBackend.alive {
                    _ = try? await gateway.route(to: previousBackend.agentRoute(), closeOldConnections: true)
                } else {
                    await gateway.suspendRouting(closeExisting: true)
                }
                if HarborSystemProxy.referencesListener(entryPort) {
                    migrationGateway = gateway
                } else {
                    if !(await gateway.stop()) { migrationGateway = gateway }
                }
                await disposeGatewayBackend(candidate)
                refreshSystemProxyState(synchronizeOwnership: true)
                detail = "系统代理端口迁移未确认，已保留原连接；请检查恢复状态"
                return
            }
        }

        // No suspension between route commit and publishing the actual
        // runtime identity. Once a system transaction has taken effect it
        // must be reflected even if a newer user request arrived meanwhile.
        connectionGeneration &+= 1
        localGateway = gateway
        gatewayBackend = candidate
        child = candidate.primary.process
        configPath = candidate.primary.configuration
        underlayChild = candidate.underlay?.process
        underlayConfigPath = candidate.underlay?.configuration
        underlayPort = candidate.underlay?.port
        if node.protocolName == "openvpn" { vpnGateUnderlayNodeID = candidate.underlayID }
        activeWARPProfile = candidate.warp
        if let endpoint = candidate.warp?.endpoint {
            if HarborIndependentWARP.isBuiltIn(node) {
                store.warpEndpoint = endpoint
            } else if node.protocolName == "openvpn" {
                if store.warpProbeEndpoints == nil { store.warpProbeEndpoints = [:] }
                store.warpProbeEndpoints?[node.id] = endpoint
            }
        }
        activePolicy = policy
        localPort = entryPort
        configuredHTTPPort = entryPort
        activeNodeID = node.id
        selectedID = node.id
        running = true
        healthy = candidate.alive && gateway.isReady && gateway.routingBackendID == candidate.primary.id
        if healthy {
            cancelGatewayRecovery(reset: true)
            connectionPhase = .connected
        } else {
            connectionPhase = .degraded
        }
        checkingConnectivity = false
        lastActiveHealthCheckAt = .now
        lastSuccessfulHealthCheckAt = healthy ? .now : nil
        warpExitIP = candidate.warpExitIP
        if let ip = candidate.observedExitIP, !HarborIndependentWARP.isBuiltIn(node) {
            let existing = nodeExitLocations[node.id]?.location
            let location = existing.flatMap { $0.ip == ip ? $0 : nil }
                ?? HarborProxyIPLocation(ip: ip, countryCode: "ZZ")
            nodeExitLocations[node.id] = HarborProxyExitLocation(location: location,
                endpointSignature: node.endpointSignature, resolvedServerIP: entranceLocation(for: node)?.ip,
                probeRouteID: currentVPNGateRouteID)
        }
        autoManageSystemProxy = wantsSystemProxy
        status = healthy ? "已连接" : "代理连接异常"
        detail = "HTTP 127.0.0.1:\(entryPort) · SOCKS5 \(entryPort + 1)"
        if userInitiated, transactionValid() { resumeConnectionOnLaunch = true }
        if let previousBackend {
            if isNewGateway {
                if let previousPort, HarborSystemProxy.referencesListener(previousPort), let previousGateway {
                    // An inactive service changed during the migration. Keep
                    // that listener alive and route it to the committed backend.
                    do {
                        try await previousGateway.route(to: candidate.agentRoute(), closeOldConnections: true)
                        migrationGateway = previousGateway
                        detail = "新端口已连接，旧端口仍被系统网络服务引用；恢复系统代理后释放"
                        await disposeGatewayBackend(previousBackend)
                    } catch {
                        migrationGateway = previousGateway
                        drainingBackend = previousBackend
                        detail = "旧端口仍被系统引用，已保留其后端，请恢复系统代理"
                    }
                } else {
                    if let previousGateway, !(await previousGateway.stop()) {
                        migrationGateway = previousGateway
                        drainingBackend = previousBackend
                    } else { await disposeGatewayBackend(previousBackend) }
                }
            } else {
                drainingBackend = previousBackend
            }
        }

        startLivenessMonitoring()
        cancelActiveExitClassification()
        scheduleActiveExitClassification()
        persist()
        proxyAudit("gateway_route_committed", nodeID: node.id, note: "backend=\(candidate.primary.id.uuidString)")
        if transactionValid(), wantsSystemProxy {
            if !wasManaged || (!isNewGateway && previousBackend.map {
                $0.policy.forcedDomains != policy.forcedDomains || $0.policy.localHosts != policy.localHosts
            } == true) {
                await applySystemProxy(interactive: userInitiated, policy: policy, reconfigure: wasManaged)
            }
        }
        refreshSystemProxyState(synchronizeOwnership: true)
        if let activeNode, !HarborIndependentWARP.isBuiltIn(activeNode) {
            enqueueExitGeoRefresh(for: [activeNode])
        }
        await reapDrainedGatewayBackend()
    }

    private func prepareGatewayCandidate(
        _ node: HarborProxyNode, policy: RoutingPolicy, protectedPorts: Set<Int>,
        cancellation: HarborLatencyCancellation, requiresObservedExit: Bool = false
    ) async throws -> GatewayBackend {
        if HarborIndependentWARP.isBuiltIn(node) {
            return try await prepareFormalWARPCandidate(node, policy: policy,
                protectedPorts: protectedPorts, cancellation: cancellation, requiresObservedExit: requiresObservedExit)
        }
        guard node.protocolName == "openvpn" else {
            return try await makeGatewayBackend(node, policy: policy, route: .direct,
                protectedPorts: protectedPorts, cancellation: cancellation, requiresObservedExit: requiresObservedExit)
        }
        let previous = probeResults[node.id].flatMap { $0.succeeded && !$0.isStale() ? $0.probeRouteID : nil }
        let base = workingVPNGateUnderlay
        let cached = warpProfile(for: node)
        var routes: [VPNGateRoute] = []
        if let base, previous == base.routeID { routes.append(.underlay(base.nodeID)) }
        if let cached, previous == cached.routeID { routes.append(.warp(cached)) }
        routes.append(.direct)
        if let base, previous != base.routeID { routes.append(.underlay(base.nodeID)) }
        for route in routes {
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
            if let candidate = try? await makeGatewayBackend(node, policy: policy, route: route,
                protectedPorts: protectedPorts, cancellation: cancellation, requiresObservedExit: requiresObservedExit) {
                return candidate
            }
        }
        guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        return try await prepareFormalWARPCandidate(node, policy: policy,
            protectedPorts: protectedPorts, cancellation: cancellation, requiresObservedExit: requiresObservedExit)
    }

    /// Each discovery attempt is a formal agent-owned candidate. On success
    /// retain that same engine and port pair; never restart a verified engine
    /// merely to promote it. The existing screen-only pool stays independent.
    private func prepareFormalWARPCandidate(
        _ node: HarborProxyNode, policy: RoutingPolicy, protectedPorts: Set<Int>,
        cancellation: HarborLatencyCancellation, requiresObservedExit: Bool
    ) async throws -> GatewayBackend {
        let epoch = connectionCoordinator.networkEpoch
        let account = try await ensureWARPAccount(cancellation: cancellation)
        let key = HarborWARPFormalDiscoveryPolicy.Key(accountID: account.id, nodeID: node.id,
            endpointSignature: node.endpointSignature, networkEpoch: epoch)
        guard formalWARPDiscovery.canAttempt(key) else {
            throw HarborProxyError.invalid("独立通道处于失败冷却期，请稍后重试")
        }
        let attempts = HarborLatencyCancellation()
        let observer = cancellation.observe { attempts.cancel() }
        let deadline = ContinuousClock.now + .seconds(HarborWARPEndpoint.discoveryDeadlineSeconds)
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            attempts.cancel()
        }
        defer {
            timer.cancel()
            if let observer { cancellation.removeObserver(observer) }
        }

        let preferred = store.warpProbeEndpoints?[node.id] ?? store.warpEndpoint
        let endpoints = HarborWARPEndpoint.discoveryAttempts(preferred: preferred)
        for endpoint in endpoints {
            guard !attempts.isCancelled, !Task.isCancelled, !shuttingDownConnection,
                  networkOnline, epoch == connectionCoordinator.networkEpoch,
                  ContinuousClock.now < deadline else { break }
            do {
                let profile = HarborWARPProfile(account: account, endpoint: endpoint)
                let candidate = try await makeGatewayBackend(node, policy: policy, route: .warp(profile),
                    protectedPorts: protectedPorts, cancellation: attempts, requiresObservedExit: requiresObservedExit)
                guard !attempts.isCancelled, !Task.isCancelled, !shuttingDownConnection,
                      networkOnline, epoch == connectionCoordinator.networkEpoch else {
                    await disposeGatewayBackend(candidate)
                    throw CancellationError()
                }
                formalWARPDiscovery.recordSuccess(key)
                return candidate
            } catch {
                if cancellation.isCancelled || Task.isCancelled || shuttingDownConnection
                    || epoch != connectionCoordinator.networkEpoch { throw CancellationError() }
                proxyAudit("warp_candidate_failed", nodeID: node.id,
                           note: "transport=\(endpoint.transport.rawValue)")
            }
        }
        guard !cancellation.isCancelled, !Task.isCancelled, !shuttingDownConnection,
              networkOnline, epoch == connectionCoordinator.networkEpoch else { throw CancellationError() }
        formalWARPDiscovery.recordFailure(key)
        throw HarborProxyError.invalid("正式 WARP 候选验证未通过，已保留原连接")
    }

    private func makeGatewayBackend(
        _ node: HarborProxyNode, policy: RoutingPolicy, route: VPNGateRoute,
        protectedPorts: Set<Int>, cancellation: HarborLatencyCancellation, requiresObservedExit: Bool
    ) async throws -> GatewayBackend {
        var base: HarborRuntimeEngineSupervisor.Engine?
        var baseID: String?
        var warp: HarborWARPProfile?
        var main: HarborRuntimeEngineSupervisor.Engine?
        let isWarp = HarborIndependentWARP.isBuiltIn(node)
        let isOpenVPN = node.protocolName == "openvpn"
        let aliases = policy.localHostAddresses.filter { $0.value.contains(where: HarborGatewayConfiguration.isLoopback) }.keys.sorted()
        guard !(await gatewayEndpointLoops(node, protectedPorts: protectedPorts)) else {
            throw HarborProxyError.invalid("节点入口指向本地代理端口，已拒绝递归连接")
        }
        do {
            switch route {
            case .direct: break
            case .warp(let profile): warp = profile
            case .underlay(let id):
                guard isOpenVPN, let profile = nodes.first(where: {
                    $0.id == id && $0.protocolName != "openvpn" && !HarborIndependentWARP.isBuiltIn($0)
                }) else { throw HarborProxyError.invalid("底座节点不可用") }
                guard !(await gatewayEndpointLoops(profile, protectedPorts: protectedPorts)) else {
                    throw HarborProxyError.invalid("底座入口指向本地代理端口")
                }
                baseID = id
                base = try await runtimeSupervisor.start(kind: .xray, root: root, cancellation: cancellation) { port in
                    let ports = protectedPorts.union([port, port + 1])
                    guard !(ports.contains(profile.port) && HarborGatewayConfiguration.isLoopback(profile.host)) else {
                        throw HarborProxyError.invalid("底座入口与内部监听端口冲突")
                    }
                    let config = try HarborXrayConfig.make(node: profile, httpPort: port, ruleMode: false, routeAllViaProxy: true)
                    return try HarborGatewayConfiguration.protectXray(config, ports: ports, aliases: aliases)
                }
            }
            let engine = try await runtimeSupervisor.start(
                kind: isWarp || isOpenVPN ? .mihomo : .xray, root: root,
                cancellation: cancellation, dependencies: base.map { [$0] } ?? []
            ) { port in
                if isWarp {
                    guard let warp else { throw HarborProxyError.invalid("WARP 通道配置尚未就绪") }
                    let config = try HarborWARPConfig.make(profile: warp, httpPort: port)
                    return try HarborGatewayConfiguration.protectMihomo(config,
                        ports: protectedPorts.union([port, port + 1]), aliases: aliases, verificationOutbound: "warp")
                }
                var ports = protectedPorts.union([port, port + 1])
                if let base { ports.formUnion([base.port, base.port + 1]) }
                guard !(ports.contains(node.port) && HarborGatewayConfiguration.isLoopback(node.host)) else {
                    throw HarborProxyError.invalid("节点入口与内部监听端口冲突")
                }
                let config = try policy.configuration(for: node, port: port, underlayPort: base?.port, warp: warp)
                return try isOpenVPN
                    ? HarborGatewayConfiguration.protectMihomo(config, ports: ports, aliases: aliases)
                    : HarborGatewayConfiguration.protectXray(config, ports: ports, aliases: aliases)
            }
            main = engine
            var warpExit: String?
            if isWarp {
                let report = await HarborWARPConnectivity.check(httpPort: engine.port)
                guard report.verified else { throw HarborProxyError.invalid("WARP 出口验证失败") }
                warpExit = report.exitIP
            }

            // Verify both protocols against the actual candidate, with
            // multiple HTTPS targets and no environment proxy fallback.
            var protocolsReady = await gatewayProtocolsReachable(port: engine.port, openVPN: isOpenVPN,
                                                                 cancellation: cancellation)
            if !protocolsReady, isOpenVPN, !cancellation.isCancelled, !Task.isCancelled {
                // Allow a cold OpenVPN handshake another bounded verification wave.
                protocolsReady = await gatewayProtocolsReachable(port: engine.port, openVPN: true,
                                                                 cancellation: cancellation)
            }
            guard protocolsReady, !cancellation.isCancelled, !Task.isCancelled else {
                throw HarborProxyError.invalid("候选 HTTP/SOCKS5 双协议验证未通过")
            }
            let exitIP: String?
            if let warpExit { exitIP = warpExit }
            else if requiresObservedExit {
                exitIP = await gatewayObservedExit(socksPort: engine.port + 1, cancellation: cancellation)
                guard exitIP != nil else { throw HarborProxyError.invalid("备用节点实际出口 IP 未验证") }
            } else { exitIP = nil }
            let candidate = GatewayBackend(nodeID: node.id, endpointSignature: node.endpointSignature,
                                           observedExitIP: exitIP, primary: engine, underlay: base,
                                           underlayID: baseID, warp: warp, warpExitIP: warpExit, policy: policy)
            guard candidate.alive else { throw HarborProxyError.invalid("候选运行配置或进程身份已变化") }
            return candidate
        } catch {
            if let main { _ = await runtimeSupervisor.stop(main) }
            if let base { _ = await runtimeSupervisor.stop(base) }
            throw error
        }
    }

    private func gatewayEndpointLoops(_ node: HarborProxyNode, protectedPorts: Set<Int>) async -> Bool {
        guard protectedPorts.contains(node.port) else { return false }
        if HarborGatewayConfiguration.isLoopback(node.host) { return true }
        if let resolved = await HarborNodeGeoIPResolver.resolvedIP(for: node.host) {
            return HarborGatewayConfiguration.isLoopback(resolved)
        }
        return false
    }

    private func gatewayObservedExit(socksPort: Int, cancellation: HarborLatencyCancellation,
                                     priority: HarborProbePriority? = nil) async -> String? {
        for target in ["https://checkip.amazonaws.com/", "https://api.ipify.org/"] {
            guard !cancellation.isCancelled, !Task.isCancelled else { return nil }
            guard let lease = await HarborProbeBudget.requests.acquire(cancellation,
                priority: priority ?? max(.health, HarborProbeScope.priority)) else { return nil }
            let result = try? await HarborProxyCommand.run(URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["--disable", "--silent", "--fail", "--max-time", "7", "--max-filesize", "256",
                            "--proto", "=https", "--proxy", "socks5h://127.0.0.1:\(socksPort)", "--noproxy", "", "--url", target],
                timeout: 8, outputLimit: 256, cancelled: { cancellation.isCancelled })
            await HarborProbeBudget.requests.release(lease)
            if let result, result.status == 0, !cancellation.isCancelled,
               let ip = HarborIPAddress.normalizedLiteral(String(decoding: result.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)), HarborNodeGeoIPResolver.isPublic(ip) {
                return ip
            }
        }
        return nil
    }

    private func gatewayProtocolsReachable(
        port: Int, openVPN: Bool, cancellation: HarborLatencyCancellation
    ) async -> Bool {
        let primary = HarborNodeLatencyTester.verificationURL(openVPN: openVPN)
        var targets = [primary, HarborNodeLatencyTester.openVPNVerificationURL,
                       URL(string: "https://example.com/")!]
        targets = targets.filter { $0.scheme?.lowercased() == "https" }
        var unique: [URL] = []
        for target in targets where !unique.contains(target) { unique.append(target) }
        // Test the two entry protocols independently. A failed website does
        // not by itself invalidate an otherwise working connection.
        async let http = gatewayAnyHTTPSProbe(port: port, socks: false, targets: unique,
                                              cancellation: cancellation)
        async let socks = gatewayAnyHTTPSProbe(port: port + 1, socks: true, targets: unique,
                                               cancellation: cancellation)
        let (httpOK, socksOK) = await (http, socks)
        return httpOK && socksOK
    }

    private func gatewayAnyHTTPSProbe(
        port: Int, socks: Bool, targets: [URL], cancellation: HarborLatencyCancellation
    ) async -> Bool {
        for target in targets {
            guard !cancellation.isCancelled, !Task.isCancelled else { return false }
            if await gatewayHTTPSProbe(port: port, socks: socks, target: target, cancellation: cancellation) {
                return true
            }
        }
        return false
    }

    private func gatewayHTTPSProbe(
        port: Int, socks: Bool, target: URL, cancellation: HarborLatencyCancellation
    ) async -> Bool {
        guard target.scheme?.lowercased() == "https", !cancellation.isCancelled, !Task.isCancelled else { return false }
        guard let lease = await HarborProbeBudget.requests.acquire(cancellation, priority: max(.health, HarborProbeScope.priority)) else { return false }
        let scheme = socks ? "socks5h" : "http"
        let result = try? await HarborProxyCommand.run(
            URL(fileURLWithPath: "/usr/bin/curl"),
            arguments: ["--disable", "--silent", "--fail", "--max-time", "6", "--max-filesize", "16384",
                        "--proto", "=https", "--proxy", "\(scheme)://127.0.0.1:\(port)", "--noproxy", "",
                        "--output", "/dev/null", "--write-out", "%{http_code}", "--url", target.absoluteString],
            timeout: 7, outputLimit: 32, cancelled: { cancellation.isCancelled }
        )
        await HarborProbeBudget.requests.release(lease)
        guard let result, result.status == 0, !cancellation.isCancelled, !Task.isCancelled,
              let code = Int(String(decoding: result.data, as: UTF8.self)),
              (200..<400).contains(code) else { return false }
        return target.path != "/generate_204" || code == 204
    }

    @discardableResult
    private func disposeGatewayBackend(_ backend: GatewayBackend) async -> Bool {
        guard await runtimeSupervisor.stop(backend.primary) else { return false }
        if let base = backend.underlay, !(await runtimeSupervisor.stop(base)) { return false }
        return true
    }

    private func reapDrainedGatewayBackend() async {
        guard let backend = drainingBackend, let localGateway, migrationGateway == nil,
              !shuttingDownConnection else { return }
        // Serialize cleanup against switching and explicit stop, including the
        // suspension points in the agent's connection-count and stop calls.
        let previousTransition = connectionTransition
        connectionTransition = true
        defer { connectionTransition = previousTransition }
        guard await localGateway.connectionCount(backendID: backend.primary.id) == 0,
              drainingBackend?.primary.id == backend.primary.id else { return }
        if await disposeGatewayBackend(backend) {
            drainingBackend = nil
        } else {
            proxyAudit("old_stop_failed", nodeID: backend.nodeID)
        }
    }

    /// The visible 'clear proxy' action never silently deletes another
    /// application's system settings or node/subscription configurations.
    func clearProxy(interactive: Bool = false) async {
        setResumeConnectionOnLaunch(false)
        if running || child != nil || underlayChild != nil || adoptedPID != nil
            || HarborSystemProxy.hasBackup || connectionTransition || activationInProgress
            || localGateway != nil || runtimeSupervisor.hasEngines
            || FileManager.default.fileExists(atPath: runtimeRecordURL.path)
            || FileManager.default.fileExists(atPath: legacyMigrationURL.path) {
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
        (running && (id == activeNodeID || (underlayPort != nil && id == vpnGateUnderlayNodeID)))
            || drainingBackend?.nodeID == id || drainingBackend?.underlayID == id
    }

    /// Recheck HTTPS over the running route, independently of website tests.
    private func finishHealthCheck(
        port: Int,
        generation: UInt64,
        systemProxyInteractive: Bool,
        publishConnection: Bool = true,
        cancellation: HarborLatencyCancellation? = nil
    ) async {
        let probeCancellation = cancellation ?? HarborLatencyCancellation()
        activeHealthCancellation = probeCancellation
        let epoch = connectionCoordinator.networkEpoch
        defer {
            if activeHealthCancellation === probeCancellation {
                activeHealthCancellation = nil
                if generation == connectionGeneration { checkingConnectivity = false }
            }
        }
        guard networkOnline else { return }
        let isOpenVPN = activeNode?.protocolName == "openvpn"
        let isWarp = activeNode.map(HarborIndependentWARP.isBuiltIn) ?? false
        let throughGateway = localGateway != nil
        let warpReport = isWarp ? await HarborWARPConnectivity.check(httpPort: port) : nil
        let reachable: Bool
        if throughGateway {
            let protocols = await gatewayProtocolsReachable(port: port, openVPN: isOpenVPN,
                                                             cancellation: probeCancellation)
            reachable = protocols && (!isWarp || warpReport?.verified == true)
        } else if let warpReport {
            reachable = warpReport.verified
        } else if isOpenVPN {
            reachable = await HarborMihomoLatencyTester.checkActiveSOCKS(
                port: port + 1, cancellation: probeCancellation)
        } else {
            reachable = await HarborNodeLatencyTester.checkActiveHTTP(port: port, cancellation: probeCancellation)
        }
        guard generation == connectionGeneration, epoch == connectionCoordinator.networkEpoch,
              running, localPort == port, !probeCancellation.isCancelled,
              networkOnline, !shuttingDownConnection, !Task.isCancelled else { return }
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
            if throughGateway {
                connectionPhase = .degraded
                await localGateway?.suspendRouting(closeExisting: true)
                scheduleGatewayRecovery(gatewayHealthPolicy.recordFailure(engineUnavailable: true))
            }
            return
        }
        checkingConnectivity = false
        healthy = reachable
        warpExitIP = isWarp ? warpReport?.exitIP : nil
        proxyAudit(reachable ? "health_success" : "health_failed",
                   nodeID: activeNodeID, note: isOpenVPN ? "method=socks_https" : "method=http_proxy_https")
        if reachable {
            if throughGateway { cancelGatewayRecovery(reset: true) }
            lastSuccessfulHealthCheckAt = .now
            scheduleActiveExitClassification()
            connectionPhase = .connected
            status = "已连接"
            detail = isWarp
                ? "WARP 出口已验证 \(warpExitIP ?? "IP 待识别") · HTTP \(port) / SOCKS5 \(port + 1)"
                : "HTTP 127.0.0.1:\(port) · SOCKS5 \(port + 1)"
            guard publishConnection else { return }
            if let activeNode, !isWarp { enqueueExitGeoRefresh(for: [activeNode]) }
            if !throughGateway, autoManageSystemProxy && !systemManaged {
                await enableSystemProxy(interactive: systemProxyInteractive)
            }
        } else {
            connectionPhase = .degraded
            if throughGateway { scheduleGatewayRecovery(gatewayHealthPolicy.recordFailure()) }
            // Inbound identity and node selection remain committed; a probe
            // failure does not mean the Xray outbound changed to another node.
            status = isWarp ? "WARP 出口验证失败" : "代理仍在运行 · 连通性检查未通过"
            detail = isWarp
                ? (warpReport?.reason ?? "WARP 真实出口验证失败，未接管系统代理")
                : "当前代理未能完成 HTTPS 验证请求。可以重试网站检测或选择其他节点。"
            if isWarp && systemManaged && localGateway == nil {
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
        await HarborProbeScope.$priority.withValue(.health) {
            await finishHealthCheck(port: port, generation: connectionGeneration, systemProxyInteractive: false)
        }
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
        await HarborProbeScope.$priority.withValue(.manual) {
            await testLatency(ids, finalization: finalization)
        }
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
            await HarborProbeScope.$priority.withValue(.geoIP) {
                await self?.runExitGeoQueue(generation: generation)
            }
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
                && !exitGeoManualIDs.contains(due[0].id) && running && healthy && !connectionTransition
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
            if let migrationGateway, await migrationGateway.stop() { self.migrationGateway = nil }
            systemManaged = false
            autoManageSystemProxy = false
            persist()
            detail = "原系统代理设置已恢复"
        } catch { detail = error.localizedDescription }
        refreshSystemProxyState()
    }

    /// Quitting the UI is not an explicit disconnect. When the user has
    /// opted to resume the connection, leave the resident route and system
    /// settings intact; the agent takes over health/recovery after XPC closes.
    /// Legacy in-process connections and opted-out sessions retain stop-on-quit.
    func prepareForApplicationQuit() async {
        guard localGateway != nil, resumeConnectionOnLaunch else {
            _ = await stop(interactive: false)
            return
        }
        shuttingDownConnection = true
        cancelGatewayRecovery(reset: true)
        connectionCoordinator.beginStop()
        activeHealthCancellation?.cancel()
        activationPreflightCancellation?.cancel()
        vpnGateDownloadCancellation?.cancel()
        warpRegistrationTask?.cancel()
        warpDiscoveryPool.invalidate()
        cancelActiveExitClassification()
        cancelLatencyTests()
        cancelAllExitGeoWork()
        websiteCancellation?.cancel()
        geoRefreshTask?.cancel()
        livenessTask?.cancel()
        healthTask?.cancel()
        // Do not block UI termination indefinitely, or send a stop command
        // to a route whose commit acknowledgement may still be in flight.
        let deadline = ContinuousClock.now + .seconds(8)
        while (activationInProgress || connectionTransition || latencyTesting || exitGeoCleaningUp || websiteChecking),
              ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
        // Delegate only the remaining explicitly allowed alternatives, bound
        // to the current live route. A failed handoff never authorizes a
        // wider selection. No standby engine is launched at quit.
        if !activationInProgress, !connectionTransition, let grant = detachedFallbackGrant() {
            _ = try? await HarborProxyAgentClient.shared.call(.grantDetachedFallback(grant))
        }
        HarborProxyAgentClient.shared.disconnect()
    }

    private func detachedFallbackGrant() -> HarborDetachedFallbackGrant? {
        guard fallbackPolicy.enabled, configurationLoaded, networkOnline,
              migrationGateway == nil, let original = activeNode,
              let backend = gatewayBackend, original.id == backend.nodeID,
              original.endpointSignature == backend.endpointSignature,
              let ip = backend.observedExitIP,
              let evidence = nodeExitNetworkEvidence[original.id],
              evidence.networkEpoch == connectionCoordinator.networkEpoch,
              HarborProxyFallbackPolicy.ExitConstraint(evidence: evidence, observedIP: ip) != nil
        else { return nil }
        let remaining = max(0, 3 - attemptedFallbackIDs.subtracting([original.id]).count)
        let candidates = Array(nodes.filter {
            $0.id != original.id && !attemptedFallbackIDs.contains($0.id)
                && fallbackPolicy.permits(nodeID: $0.id, signature: $0.endpointSignature)
                && $0.protocolName == original.protocolName && supportsCore(for: $0)
        }.sorted { $0.id < $1.id }.prefix(remaining))
        guard !candidates.isEmpty else { return nil }
        // Do not delegate an unverified or altered subscription underlay.
        var underlayNode: HarborProxyNode?
        if let id = backend.underlayID {
            guard let base = nodes.first(where: { $0.id == id }), let engine = backend.underlay,
                  engine.configurationUnchanged,
                  let bytes = try? Data(contentsOf: engine.configuration),
                  let expected = try? HarborXrayConfig.make(node: base, httpPort: engine.port,
                      ruleMode: false, routeAllViaProxy: true),
                  let actual = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let originalConfig = try? JSONSerialization.jsonObject(with: expected) as? [String: Any],
                  let actualOutbounds = actual["outbounds"] as? [[String: Any]],
                  let expectedOutbounds = originalConfig["outbounds"] as? [[String: Any]],
                  let a = actualOutbounds.first(where: { $0["tag"] as? String == "proxy" }),
                  let b = expectedOutbounds.first(where: { $0["tag"] as? String == "proxy" }),
                  NSDictionary(dictionary: a).isEqual(to: b)
            else { return nil }
            underlayNode = base
        }
        return HarborDetachedFallbackGrant(primaryID: backend.primary.id, sourceNode: original,
            sourceEvidence: evidence, candidates: candidates, underlayNode: underlayNode,
            warpAccount: backend.warp?.account)
    }

    @discardableResult
    func stop(interactive: Bool = false) async -> Bool {
        guard !shuttingDownConnection else { return false }
        shuttingDownConnection = true
        connectionPhase = .stopping
        cancelGatewayRecovery(reset: true)
        defer {
            shuttingDownConnection = false
            connectionCoordinator.endStop()
            if connectionPhase == .stopping { connectionPhase = running ? (healthy ? .connected : .degraded) : .stopped }
        }
        connectionCoordinator.beginStop()
        activeHealthCancellation?.cancel()
        activationPreflightCancellation?.cancel()
        vpnGateDownloadCancellation?.cancel()
        warpRegistrationTask?.cancel()
        warpDiscoveryPool.invalidate()
        cancelActiveExitClassification()
        cancelLatencyTests()
        cancelAllExitGeoWork()
        websiteCancellation?.cancel()
        let shutdownDeadline = ContinuousClock.now + .seconds(35)
        while activationInProgress || connectionTransition || latencyTesting || exitGeoCleaningUp || websiteChecking {
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
        await warpDiscoveryPool.shutdown()
        if HarborProxyRecoveryPolicy.mustRestoreBeforeStop(hasBackup: HarborSystemProxy.hasBackup) {
            do { try await HarborSystemProxy.restore() }
            catch {
                detail = "系统代理未恢复，已保留代理内核运行：" + error.localizedDescription
                refreshSystemProxyState()
                return false
            }
        }
        systemManaged = false
        // Before stopping the legacy process, recover any unadopted staging
        // handles left by a lost IPC reply. All system references were restored above.
        if FileManager.default.fileExists(atPath: legacyMigrationURL.path),
           FileManager.default.fileExists(atPath: HarborProxyAgentConstants.journalURL.path) {
            guard let snapshot = try? await HarborProxyAgentClient.shared.inspect(),
                  snapshot.operationInProgress != true else {
                detail = "迁移服务状态未确认，保留恢复记录"; return false
            }
            runtimeSupervisor.adoptSnapshot(snapshot)
            for entry in snapshot.gateways {
                guard let handle = try? HarborAgentGateway(httpPort: entry.port),
                      await handle.stop() else {
                    detail = "迁移入口仍被使用或尚未回收"; return false
                }
            }
        }
        let stopped = await stopCore()
        if stopped, FileManager.default.fileExists(atPath: legacyMigrationURL.path) {
            // Explicit disconnect also retires an unadopted staging gateway.
            // The agent refuses any listener that remains referenced by macOS.
            if FileManager.default.fileExists(atPath: HarborProxyAgentConstants.journalURL.path) {
                guard let snapshot = try? await HarborProxyAgentClient.shared.inspect() else {
                    detail = "迁移服务状态未确认，保留恢复记录"; return false
                }
                runtimeSupervisor.adoptSnapshot(snapshot)
                for entry in snapshot.gateways {
                    guard let gateway = try? HarborAgentGateway(httpPort: entry.port),
                          await gateway.stop() else {
                        detail = "迁移入口尚未回收，保留恢复记录"; return false
                    }
                }
                guard await runtimeSupervisor.reap(excluding: []) else {
                    detail = "迁移内核尚未回收"; return false
                }
                HarborProxyAgentClient.shared.disconnect()
            }
            try? FileManager.default.removeItem(at: legacyMigrationURL)
        }
        refreshSystemProxyState()
        return stopped
    }

    /// Stop only our Xray child. Node switching keeps the fixed macOS proxy
    /// address and the ownership/recovery snapshot intact; no authorization.
    private var coreProcessAlive: Bool {
        if let gatewayBackend {
            return gatewayBackend.alive && localGateway?.isReady == true
                && localGateway?.routingBackendID == gatewayBackend.primary.id
        }
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
                do { try await Task.sleep(for: .seconds(HarborProxyHealthPolicy.livenessInterval)) }
                catch { return }
                guard let self, !Task.isCancelled else { return }
                if !self.connectionTransition && !self.shuttingDownConnection {
                    await self.reapDrainedGatewayBackend()
                }
                await self.reconcileXrayLiveness()
                if self.running, self.networkOnline, self.gatewayRecoveryTask == nil,
                   !self.connectionTransition, !self.shuttingDownConnection,
                   !self.checkingConnectivity, let port = self.localPort,
                   Date().timeIntervalSince(self.lastActiveHealthCheckAt ?? .distantPast)
                    >= HarborProxyHealthPolicy.healthInterval {
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
        guard running, !connectionTransition, !shuttingDownConnection, !activationInProgress else { return }
        if let localGateway {
            guard let snapshot = try? await HarborProxyAgentClient.shared.inspect() else {
                healthy = false
                connectionPhase = networkOnline ? .degraded : .offline
                status = "独立代理服务暂不可达"
                return
            }
            guard !connectionTransition, !shuttingDownConnection, !activationInProgress else { return }
            runtimeSupervisor.adoptSnapshot(snapshot)
            localGateway.refresh(snapshot)
            migrationGateway?.refresh(snapshot)
            if let entry = snapshot.gateways.first(where: { $0.port == localGateway.port }),
               entry.route?.primaryID != gatewayBackend?.primary.id {
                // A lost commit reply may hide a completed agent transaction.
                // Never report the previous node or destroy the committed core.
                guard adoptResidentProxy(snapshot) else {
                    healthy = false
                    detail = "代理服务路由状态尚未确认，保留内核"
                    return
                }
                healthy = false
                lastActiveHealthCheckAt = nil
                detail = "已重新同步代理服务实际路由，等待健康验证"
            }
        }
        if coreProcessAlive {
            if let activeNodeID, !runningConfigMatches(activeNodeID, path: configPath) {
                healthy = false
                status = "代理运行配置与选中节点不一致"
                detail = "运行配置发生变化，已取消已连接状态；请重新选择节点"
                proxyAudit("periodic_identity_mismatch", nodeID: activeNodeID)
                if localGateway != nil, !connectionTransition, !activationInProgress, gatewayRecoveryTask == nil {
                    await localGateway?.suspendRouting(closeExisting: true)
                    connectionPhase = .degraded
                    scheduleGatewayRecovery(gatewayHealthPolicy.recordFailure(engineUnavailable: true))
                }
            }
            return
        }
        await handleUnexpectedXrayExit(pid: child?.processIdentifier ?? adoptedPID)
    }

    private func handleUnexpectedXrayExit(pid: Int32?) async {
        guard !connectionTransition, !shuttingDownConnection, !intentionallyStoppingCore, running else { return }
        if let localGateway {
            guard !coreProcessAlive else { return }
            // The stable entry survives backend failure. Fail closed and
            // retain system ownership; an explicit reconnect can rebuild it.
            await localGateway.suspendRouting(closeExisting: true)
            await migrationGateway?.suspendRouting(closeExisting: true)
            healthy = false
            checkingConnectivity = false
            if gatewayRecoveryTask == nil || !networkOnline {
                connectionPhase = networkOnline ? .degraded : .offline
                status = networkOnline ? "代理后端异常 · 等待恢复" : "网络离线"
                detail = "固定入口已保留，未绕过代理"
            }
            if networkOnline, gatewayRecoveryTask == nil, !activationInProgress {
                proxyAudit("gateway_backend_unavailable", nodeID: activeNodeID)
                scheduleGatewayRecovery(gatewayHealthPolicy.recordFailure(engineUnavailable: true))
            }
            return
        }
        guard let pid, HarborProxyLivenessPolicy.shouldHandleUnexpectedExit(
            running: running, intentionallyStopping: intentionallyStoppingCore,
            processMatches: pid == child?.processIdentifier || pid == adoptedPID,
            coreAlive: coreProcessAlive) else { return }
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
        if localGateway != nil || (runtimeSupervisor.hasEngines && child == nil && adoptedPID == nil) {
            return await stopGatewayCore()
        }
        if let localPort, HarborSystemProxy.referencesListener(localPort) {
            detail = "旧入口仍被系统网络服务引用，已保留内核"
            return false
        }
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

    private func stopGatewayCore() async -> Bool {
        guard !HarborSystemProxy.currentUsesManagedListener else {
            detail = "系统代理仍使用固定入口，已保留监听服务"
            return false
        }
        connectionGeneration &+= 1
        livenessTask?.cancel()
        livenessTask = nil
        healthTask?.cancel()
        healthTask = nil
        if let localGateway, !(await localGateway.stop()) {
            detail = "固定入口停止尚未确认，已保留内核记录"; return false
        }
        if let migrationGateway, !(await migrationGateway.stop()) {
            detail = "旧固定入口停止尚未确认，已保留内核记录"; return false
        }
        migrationGateway = nil
        // An interrupted migration may still own a legacy process record.
        if FileManager.default.fileExists(atPath: runtimeRecordURL.path) {
            guard let data = try? Data(contentsOf: legacyMigrationURL),
                  let migration = try? JSONDecoder().decode(LegacyMigration.self, from: data),
                  !HarborSystemProxy.referencesListener(migration.oldPort) else {
                detail = "旧代理仍被引用或迁移记录未确认，保留旧内核"
                return false
            }
            await cleanupOrphan()
            guard !FileManager.default.fileExists(atPath: runtimeRecordURL.path) else {
                detail = "旧代理尚未清理"; return false
            }
        }
        let cleaned = await runtimeSupervisor.reap(excluding: [])
        running = false
        healthy = false
        checkingConnectivity = false
        if !cleaned {
            status = "代理清理未完成"
            detail = "内核未完全退出，保留进程记录与端口许可"
            return false
        }
        localGateway = nil
        gatewayBackend = nil
        drainingBackend = nil
        child = nil
        configPath = nil
        underlayChild = nil
        underlayConfigPath = nil
        underlayPort = nil
        activeWARPProfile = nil
        activePolicy = nil
        warpExitIP = nil
        lastSuccessfulHealthCheckAt = nil
        activeNodeID = nil
        localPort = nil
        status = "已关闭"
        try? FileManager.default.removeItem(at: legacyMigrationURL)
        HarborProxyAgentClient.shared.disconnect()
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
            guard let identity = HarborProcessIdentity.capture(pid: record.pid),
                  identity.executablePath == URL(fileURLWithPath: record.executablePath).resolvingSymlinksInPath().path,
                  await recordedXrayIsOrphan(record), identity.isCurrent else {
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
                guard identity.isCurrent, await recordedXrayIsOrphan(record), identity.isCurrent else {
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
                guard let identity = HarborProcessIdentity.capture(pid: underlay.pid),
                      identity.executablePath == URL(fileURLWithPath: underlay.executablePath).resolvingSymlinksInPath().path,
                      await recordedUnderlayIsOrphan(underlay), identity.isCurrent else {
                    detail = "底座代理仍由其他进程管理，已停止自动清理"
                    return
                }
                _ = Darwin.kill(underlay.pid, SIGTERM)
                for _ in 0..<20 where Darwin.kill(underlay.pid, 0) == 0 {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                if Darwin.kill(underlay.pid, 0) == 0 {
                    guard identity.isCurrent, await recordedUnderlayIsOrphan(underlay), identity.isCurrent else { return }
                    _ = Darwin.kill(underlay.pid, SIGKILL)
                    for _ in 0..<20 where identity.isCurrent {
                        try? await Task.sleep(for: .milliseconds(50))
                    }
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

    /// Check for a real listening socket instead of probing with bind(). A
    /// recently closed TCP connection can keep a port in TIME_WAIT and make a
    /// bind preflight fail even though Xray can immediately listen again.
    private func portListening(_ port: Int) -> Bool {
        HarborNodeLatencyTester.canConnect(port)
    }
}
