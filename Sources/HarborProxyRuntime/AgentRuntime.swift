import CodexHarborCore
import CryptoKit
import Darwin
import Foundation
import Network
import SystemConfiguration

/// The resident data plane retains verified routes if the UI exits
/// unexpectedly. The control connection cannot launch arbitrary commands.
@MainActor
package final class HarborProxyAgentRuntime {
    private struct LaunchIntent: Codable {
        let id: UUID
        let kind: HarborProxyAgentEngineKind
        let port: Int
    }

    private struct Journal: Codable {
        var version = HarborProxyAgentConstants.protocolVersion
        var ports: Set<Int> = []
        var routes: [Int: HarborProxyAgentRoute] = [:]
        var engines: [UUID: HarborProxyAgentEngineRecord] = [:]
        var starts: [Date] = []
        var pendingLaunches: [UUID: LaunchIntent]?
        var suspendedPorts: Set<Int>?
        var pendingRestarts: Set<UUID>?
    }

    private struct Recovery {
        var policy = HarborProxyHealthPolicy()
        var nextAttempt = ContinuousClock.now
        var cooling = false
    }

    private struct DetachedFallback {
        let grant: HarborDetachedFallbackGrant
        let constraint: HarborProxyFallbackPolicy.ExitConstraint
        let epoch: UInt64
        var remaining: [HarborProxyNode]
        var nextAttempt = ContinuousClock.now
    }

    private var detachedFallback: DetachedFallback?
    private let root: URL
    private let isolatedVerification: (@MainActor (Int) async -> Bool)?
    private let isolatedSwitchVerification: (@MainActor (Int, UUID) async -> Bool)?
    private var journalURL: URL { root.appendingPathComponent("proxy-agent-journal.json") }
    private var activeMarker: URL { root.appendingPathComponent("proxy-agent-active") }

    package init() {
        root = HarborProxyAgentConstants.root
        isolatedVerification = nil
        isolatedSwitchVerification = nil
    }

    /// Internal test seam, not exposed by the executable, environment or XPC.
    /// Tests must supply a newly-created private temporary directory.
    init(isolatedRoot: URL, verification: @escaping @MainActor (Int) async -> Bool,
         switchVerification: (@MainActor (Int, UUID) async -> Bool)? = nil) {
        root = isolatedRoot
        isolatedVerification = verification
        isolatedSwitchVerification = switchVerification
    }

    func recoveryCycleForTesting() async {
        guard isolatedVerification != nil else { return }
        await tick()
    }

    /// Model loss of the resident listener while preserving journal/engines.
    /// Unlike actual process death this does not exercise launchd or XPC.
    func releaseListenersForTesting() {
        guard isolatedVerification != nil else { return }
        for gateway in gateways.values { gateway.stop() }
        gateways.removeAll()
    }
    private let fm = FileManager.default
    private var journal = Journal()
    private var gateways: [Int: HarborLocalProxyGateway] = [:]
    private var children: [UUID: Process] = [:]
    private var healthy: [Int: Bool] = [:]
    private var lastHealth: [Int: Date] = [:]
    private var lastProbe: [UUID: Date] = [:]
    private var recovery: [UUID: Recovery] = [:]
    private var controllerLease = HarborProxyControllerLease()
    private var pathMonitor: NWPathMonitor?
    private var networkOnline = true
    private var networkEpoch: UInt64 = 0
    private var pathFingerprint: String?
    private var defaultRouteFingerprint: String?
    private var recoveryGeneration: UInt64 = 0
    private var busy = false
    private var startupError: String?
    private var restartSuppressed = false
    private var idleSince: Date?

    package func start() async {
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            var info = stat()
            guard lstat(root.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
                  info.st_uid == getuid() else { throw Failure.invalidJournal }
            if fm.fileExists(atPath: journalURL.path) {
                let data = try privateRead(journalURL, limit: 1_048_576)
                journal = try JSONDecoder().decode(Journal.self, from: data)
                guard journal.version == HarborProxyAgentConstants.protocolVersion,
                      journal.ports.count <= 2,
                      journal.engines.count + (journal.pendingLaunches?.count ?? 0) <= 6,
                      journal.ports.allSatisfy({ (1024...65534).contains($0) }),
                      (journal.pendingLaunches ?? [:]).allSatisfy({
                          $0.key == $0.value.id && journal.engines[$0.key] == nil
                              && (18200...19398).contains($0.value.port)
                      }),
                      journal.routes.keys.allSatisfy({ journal.ports.contains($0) }),
                      (journal.pendingRestarts ?? []).isSubset(of: Set(journal.engines.keys)),
                      (journal.suspendedPorts ?? []).isSubset(of: journal.ports),
                      journal.engines.allSatisfy({ $0.key == $0.value.id && validPaths($0.value) }) else {
                    throw Failure.invalidJournal
                }
                let allPorts = Array(journal.ports) + journal.engines.values.map(\.port)
                    + (journal.pendingLaunches ?? [:]).values.map(\.port)
                let occupied = allPorts.sorted()
                guard zip(occupied, occupied.dropFirst()).allSatisfy({ $1 - $0 > 1 }) else {
                    throw Failure.invalidJournal
                }
            }
            // A damaged candidate must not prevent a valid committed route
            // from reclaiming its fixed listeners. Keep unresolved intents.
            journal.starts = journal.starts.filter { (0..<300).contains(Date.now.timeIntervalSince($0)) }
            if !journal.ports.isEmpty || !journal.engines.isEmpty || !(journal.pendingLaunches ?? [:]).isEmpty {
                journal.starts.append(.now)
                restartSuppressed = journal.starts.count > 3
            }
            // Count the restart before touching any unresolved child.
            try persist()
            try? await recoverPendingLaunches()
            try? await recoverPendingRestarts()
            for port in journal.ports.sorted() {
                guard (1024...65534).contains(port) else { throw Failure.invalidJournal }
                let gateway = try HarborLocalProxyGateway(httpPort: port)
                gateways[port] = gateway
                do {
                    try await gateway.start()
                    // A recovered process or journal is not proof of a
                    // usable route. Verify again before accepting new flows.
                    healthy[port] = false
                } catch {
                    healthy[port] = false
                }
            }
            try persist()
        } catch {
            startupError = "JOURNAL_RECOVERY_FAILED"
            // Do not repeatedly relaunch a corrupt journal. Leave the
            // records intact for a deliberate recovery operation.
            try? fm.removeItem(at: activeMarker)
        }

        guard isolatedVerification == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            let interfaces = path.availableInterfaces.filter { path.usesInterfaceType($0.type) }
                .map { $0.name }.sorted().joined(separator: ",")
            let fingerprint = "\(online)|\(interfaces)|\(path.supportsIPv4)|\(path.supportsIPv6)|\(path.supportsDNS)|\(path.isExpensive)|\(path.isConstrained)"
            Task { @MainActor [weak self] in self?.networkChanged(online, fingerprint: fingerprint) }
        }
        monitor.start(queue: DispatchQueue(label: "com.codexharbor.proxy-agent.path", qos: .utility))
        pathMonitor = monitor
        Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(10)) } catch { return }
                guard let self else { return }
                await self.tick()
            }
        }
    }

    func clientConnected(_ id: UUID, now: ContinuousClock.Instant = .now) {
        if controllerLease.renew(id, now: now) {
            recoveryGeneration &+= 1
            detachedFallback = nil
        }
        idleSince = nil
    }

    func clientDisconnected(_ id: UUID) { controllerLease.disconnect(id) }
    private var hasLiveController: Bool { controllerLease.liveCount() > 0 }

    private func networkChanged(_ online: Bool, fingerprint: String) {
        let route = currentDefaultRouteFingerprint()
        guard online != networkOnline || fingerprint != pathFingerprint || route != defaultRouteFingerprint else { return }
        networkOnline = online
        pathFingerprint = fingerprint
        defaultRouteFingerprint = route
        detachedFallback = nil
        networkEpoch &+= 1
        recoveryGeneration &+= 1
        recovery.removeAll()
        lastProbe.removeAll()
        for port in journal.ports { healthy[port] = false }
    }

    /// NWPath interface types alone do not distinguish two Wi-Fi networks.
    /// Include the active service and router, without retaining addresses in logs.
    private func currentDefaultRouteFingerprint() -> String? {
        let routes = ["IPv4", "IPv6"].compactMap { family -> String? in
            guard let value = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString) as? [String: Any],
                  let service = value["PrimaryService"] as? String else { return nil }
            return "\(family):\(service):\(value["PrimaryInterface"] as? String ?? ""):\(value["Router"] as? String ?? "")"
        }
        return routes.isEmpty ? nil : routes.joined(separator: "|")
    }

    private func refreshDefaultRoute() {
        if let fingerprint = pathFingerprint { networkChanged(networkOnline, fingerprint: fingerprint) }
    }

    func handle(_ request: HarborProxyAgentRequest, peerPID: Int32, sessionID: UUID? = nil) async -> HarborProxyAgentReply {
        guard request.version == HarborProxyAgentConstants.protocolVersion else {
            return .init(errorCode: "PROTOCOL_VERSION_MISMATCH")
        }
        if let sessionID { clientConnected(sessionID) }
        // Heartbeats require no disk I/O and are answered even while a
        // recovery or switch is awaiting work.
        if case .heartbeat = request.command { return .init(errorCode: startupError) }
        refreshDefaultRoute()
        if case .inspect = request.command {
            if let startupError { return .init(errorCode: startupError, snapshot: snapshot()) }
            return .init(snapshot: snapshot())
        }
        guard startupError == nil else { return .init(errorCode: startupError) }
        guard !busy else { return .init(errorCode: "RUNTIME_BUSY", snapshot: snapshot()) }
        busy = true
        defer { busy = false }
        do {
            switch request.command {
            case .inspect, .heartbeat: break
            case .grantDetachedFallback(let grant): try configureDetachedFallback(grant)
            case .openGateway(let port): try await openGateway(port)
            case .startEngine(let id, let kind, let port, let data, let dependencies):
                try await startEngine(id: id, kind: kind, port: port, data: data, dependencies: dependencies)
            case .commit(let port, let route, let closeOld):
                let controllerGeneration = recoveryGeneration
                try await commit(port: port, route: route, closeOld: closeOld) {
                    self.recoveryGeneration == controllerGeneration &&
                        (sessionID.map { self.controllerLease.isLive($0) } ?? true)
                }
            case .recordExit(let port, let backendID, let ip):
                try recordExit(port: port, backendID: backendID, ip: ip)
            case .suspend(let port, let closeExisting):
                guard let gateway = gateways[port] else { throw Failure.unknownGateway }
                // Fail closed immediately, even if journal persistence fails.
                gateway.suspendRouting(closeExisting: closeExisting)
                healthy[port] = false
                journal.suspendedPorts = (journal.suspendedPorts ?? []).union([port])
                try persist()
            case .connectionCount(let port, let backendID):
                guard let gateway = gateways[port] else { throw Failure.unknownGateway }
                return .init(count: gateway.connectionCount(backendID: backendID))
            case .closeConnections(let port, let backendID):
                guard let gateway = gateways[port] else { throw Failure.unknownGateway }
                gateway.closeConnections(backendID: backendID)
            case .stopGateway(let port):
                detachedFallback = nil
                try stopGateway(port)
            case .stopEngine(let id):
                if journal.pendingLaunches?[id] != nil { try await recoverPendingLaunches() }
                else {
                    if journal.pendingRestarts?.contains(id) == true { try await recoverPendingRestarts() }
                    try await retireEngine(id)
                }
            }
            return .init(snapshot: snapshot())
        } catch let failure as Failure {
            return .init(errorCode: failure.rawValue, snapshot: snapshot())
        } catch {
            return .init(errorCode: "RUNTIME_OPERATION_FAILED", snapshot: snapshot())
        }
    }

    private enum Failure: String, Error {
        case invalidJournal = "JOURNAL_RECOVERY_FAILED"
        case invalidRecord = "ENGINE_IDENTITY_INVALID"
        case unknownGateway = "GATEWAY_NOT_FOUND"
        case resourceLimit = "RESOURCE_EXHAUSTED"
        case portInUse = "PORT_IN_USE"
        case systemProxyReference = "SYSTEM_PROXY_STILL_REFERENCES_PORT"
        case engineInUse = "ENGINE_STILL_REFERENCED"
        case stopFailed = "ENGINE_STOP_FAILED"
        case persistenceFailed = "JOURNAL_WRITE_FAILED"
        case switchUnverified = "SWITCH_VERIFICATION_FAILED"
        case switchRollbackFailed = "SWITCH_ROLLBACK_FAILED"
    }

    private func openGateway(_ port: Int) async throws {
        guard (1024...65534).contains(port) else { throw Failure.portInUse }
        if let gateway = gateways[port] {
            if !gateway.isReady { try await gateway.start() }
            return
        }
        guard gateways.count < 2,
              gateways.keys.allSatisfy({ abs($0 - port) > 1 }),
              journal.engines.values.allSatisfy({ abs($0.port - port) > 1 }),
              (journal.pendingLaunches ?? [:]).values.allSatisfy({ abs($0.port - port) > 1 }) else { throw Failure.resourceLimit }
        let gateway = try HarborLocalProxyGateway(httpPort: port)
        try await gateway.start()
        let previous = journal
        gateways[port] = gateway
        journal.ports.insert(port)
        do { try persist() } catch {
            journal = previous
            if !systemReferences(port) {
                gateways.removeValue(forKey: port)
                gateway.stop()
            }
            throw Failure.persistenceFailed
        }
    }

    private func launchPaths(_ id: UUID) -> (file: URL, directory: URL) {
        let file = root.appendingPathComponent("probe-runtime-\(id.uuidString).json")
        return (file, file.deletingPathExtension().appendingPathExtension("data"))
    }

    /// Journal the intent before any child can start. A disconnected client
    /// may retry the same ID without creating a second engine.
    private func startEngine(id: UUID, kind: HarborProxyAgentEngineKind, port: Int,
                             data: Data, dependencies: Set<UUID>) async throws {
        let digest = Data(SHA256.hash(data: data))
        if let existing = journal.engines[id] {
            guard existing.kind == kind, existing.port == port,
                  existing.configurationDigest == digest, existing.dependencyIDs == dependencies,
                  existing.identity.isCurrent, configurationValid(existing),
                  HarborLoopbackTCP.isListening(port), HarborLoopbackTCP.isListening(port + 1) else {
                throw Failure.invalidRecord
            }
            return
        }
        guard (18200...19398).contains(port), data.count <= 512 * 1024,
              configurationValid(data, kind: kind, port: port),
              dependencies.count <= 1, !dependencies.contains(id),
              dependencies.allSatisfy({ dependency in
                  guard let base = journal.engines[dependency] else { return false }
                  return base.kind == .xray && base.dependencyIDs.isEmpty && base.identity.isCurrent
                      && configurationValid(base)
              }) else { throw Failure.invalidRecord }
        let pending = journal.pendingLaunches ?? [:]
        guard pending[id] == nil, journal.engines.count + pending.count < 6,
              journal.ports.allSatisfy({ abs($0 - port) > 1 }),
              journal.engines.values.allSatisfy({ abs($0.port - port) > 1 }),
              pending.values.allSatisfy({ abs($0.port - port) > 1 }),
              !HarborLoopbackTCP.isListening(port), !HarborLoopbackTCP.isListening(port + 1)
        else { throw Failure.resourceLimit }
        let paths = launchPaths(id)
        guard !fm.fileExists(atPath: paths.file.path), !fm.fileExists(atPath: paths.directory.path) else {
            throw Failure.invalidRecord
        }

        journal.pendingLaunches = pending
        journal.pendingLaunches?[id] = LaunchIntent(id: id, kind: kind, port: port)
        do { try persist() } catch {
            journal.pendingLaunches = pending
            throw Failure.persistenceFailed
        }

        let process = Process()
        do {
            try fm.createDirectory(at: paths.directory, withIntermediateDirectories: false,
                                   attributes: [.posixPermissions: 0o700])
            if kind == .mihomo {
                for (name, asset) in [("GeoIP.dat", "geoip.dat"), ("GeoSite.dat", "geosite.dat")] {
                    try fm.createSymbolicLink(at: paths.directory.appendingPathComponent(name),
                                              withDestinationURL: root.appendingPathComponent(asset))
                }
            }
            try atomicWrite(data, to: paths.file)
            configure(process, kind: kind, file: paths.file, directory: paths.directory)
            try process.run()
            children[id] = process
            guard let identity = HarborProcessIdentity.capture(pid: process.processIdentifier),
                  identity.matchesExecutable(at: executable(kind)) else {
                throw Failure.invalidRecord
            }
            let record = HarborProxyAgentEngineRecord(id: id, kind: kind, port: port, identity: identity,
                configurationPath: paths.file.path, configurationDigest: digest,
                directoryPath: paths.directory.path, dependencyIDs: dependencies)
            journal.engines[id] = record
            journal.pendingLaunches?.removeValue(forKey: id)
            try persist()
            let deadline = ContinuousClock.now + .seconds(8)
            while process.isRunning, ContinuousClock.now < deadline {
                if HarborLoopbackTCP.isListening(port), HarborLoopbackTCP.isListening(port + 1),
                   identity.isCurrent, configurationValid(record) { return }
                try await Task.sleep(for: .milliseconds(75))
            }
            throw Failure.invalidRecord
        } catch {
            // Never drop the intent/record while a process may still exist.
            if let record = journal.engines[id] {
                if !(await stopProcess(record)) { throw Failure.stopFailed }
                do { try await retireEngine(id) } catch { throw Failure.stopFailed }
            } else {
                guard await HarborProxyCommand.stop(process) else { throw Failure.stopFailed }
                try clearPendingLaunch(id)
            }
            throw error
        }
    }

    private func configure(_ process: Process, kind: HarborProxyAgentEngineKind, file: URL, directory: URL) {
        process.executableURL = executable(kind)
        process.currentDirectoryURL = directory
        process.arguments = kind == .xray ? ["run", "-config", file.path] : ["-d", directory.path, "-f", file.path]
        var environment = ProcessInfo.processInfo.environment
        for key in Array(environment.keys) where ["http_proxy", "https_proxy", "all_proxy", "no_proxy"].contains(key.lowercased()) {
            environment.removeValue(forKey: key)
        }
        environment["XRAY_LOCATION_ASSET"] = root.path
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
    }

    private func clearPendingLaunch(_ id: UUID) throws {
        guard let intent = journal.pendingLaunches?[id],
              !HarborLoopbackTCP.isListening(intent.port), !HarborLoopbackTCP.isListening(intent.port + 1)
        else { throw Failure.stopFailed }
        let paths = launchPaths(id)
        for path in [paths.file, paths.directory] where fm.fileExists(atPath: path.path) {
            try fm.removeItem(at: path)
        }
        journal.pendingLaunches?.removeValue(forKey: id)
        do { try persist() } catch {
            journal.pendingLaunches?[id] = intent
            throw error
        }
        children.removeValue(forKey: id)
    }

    /// Resolve the short crash window between launching a child and saving its
    /// full process identity. Unknown ownership is never treated as safe.
    private func recoverPendingLaunches() async throws {
        let pending = journal.pendingLaunches ?? [:]
        guard !pending.isEmpty else { return }
        guard pending.count + journal.engines.count <= 6,
              pending.allSatisfy({ $0.key == $0.value.id && (18200...19398).contains($0.value.port) })
        else { throw Failure.invalidJournal }
        for (id, intent) in pending {
            if let process = children[id] {
                guard await HarborProxyCommand.stop(process) else { throw Failure.stopFailed }
            } else {
                let paths = launchPaths(id)
                let expected = executable(intent.kind).path + (intent.kind == .xray
                    ? " run -config " + paths.file.path
                    : " -d " + paths.directory.path + " -f " + paths.file.path)
                let result = try await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-axww", "-o", "uid=", "-o", "pid=", "-o", "ppid=", "-o", "command="],
                    timeout: 3, outputLimit: 2_000_000)
                guard result.status == 0 else { throw Failure.stopFailed }
                let matches = String(decoding: result.data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).compactMap { line -> HarborProcessIdentity? in
                        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                        guard fields.count == 4, UInt32(fields[0]) == getuid(), fields[2] == "1",
                              fields[3] == expected, let pid = Int32(fields[1]),
                              let identity = HarborProcessIdentity.capture(pid: pid),
                              identity.matchesExecutable(at: executable(intent.kind))
                        else { return nil }
                        return identity
                    }
                guard matches.count <= 1 else { throw Failure.stopFailed }
                if let identity = matches.first, identity.isCurrent {
                    _ = Darwin.kill(identity.pid, SIGTERM)
                    for _ in 0..<20 where identity.isCurrent { try await Task.sleep(for: .milliseconds(50)) }
                    guard !identity.isCurrent else { throw Failure.stopFailed }
                }
            }
            try clearPendingLaunch(id)
        }
    }

    private func commit(port: Int, route: HarborProxyAgentRoute, closeOld: Bool,
                        mayCommit: () -> Bool) async throws {
        guard let gateway = gateways[port], gateway.isReady else { throw Failure.unknownGateway }
        guard !route.nodeID.isEmpty, route.nodeID.utf8.count <= 256,
              route.endpointSignature.utf8.count == 64, route.engines.count == (route.underlayID == nil ? 1 : 2),
              route.forcedDomains.count <= 256, route.localHostAddresses.count <= 256 else {
            throw Failure.invalidRecord
        }
        let records = Dictionary(grouping: route.engines, by: \.id)
        guard records.values.allSatisfy({ $0.count == 1 }),
              let primary = records[route.primaryID]?.first,
              primary.dependencyIDs == Set(route.underlayID.map { [$0] } ?? []),
              route.underlayID == nil || records[route.underlayID!]?.first?.dependencyIDs.isEmpty == true else {
            throw Failure.invalidRecord
        }
        for record in route.engines {
            guard validPaths(record), configurationValid(record), record.identity.isCurrent,
                  record.identity.matchesExecutable(at: executable(record.kind)),
                  HarborLoopbackTCP.isListening(record.port), HarborLoopbackTCP.isListening(record.port + 1),
                  journal.ports.allSatisfy({ abs($0 - record.port) > 1 }) else { throw Failure.invalidRecord }
            if let existing = journal.engines[record.id] {
                guard existing == record else { throw Failure.invalidRecord }
            } else {
                // Only the resident agent may create formal engines now.
                throw Failure.invalidRecord
            }
            // No dependency may be shared by unrelated active routes.
            for other in journal.routes.values where other.primaryID != route.primaryID {
                guard !other.engines.contains(where: { $0.id == record.id }) else { throw Failure.engineInUse }
            }
        }
        let previous = journal.routes[port]
        let previousActive = gateway.activeBackendID
        let previousHealth = healthy[port]
        let epoch = networkEpoch
        let target = try backend(route)
        let observing = previousActive != target.id || healthy[port] != true
        guard networkOnline, mayCommit() else { throw Failure.switchUnverified }

        func revert() throws {
            if let previousActive, let previous, previous.primaryID == previousActive, routeAlive(previous) {
                do {
                    try gateway.route(to: backend(previous), closeOldConnections: true)
                    healthy[port] = epoch == networkEpoch ? previousHealth : false
                } catch {
                    gateway.suspendRouting(closeExisting: true)
                    healthy[port] = false
                    throw Failure.switchRollbackFailed
                }
            } else {
                gateway.suspendRouting(closeExisting: true)
                healthy[port] = false
                if previousActive != nil { throw Failure.switchRollbackFailed }
            }
        }

        // The journal still points to the last verified route during the
        // trial. The previous engine cannot be retired while this RPC is
        // busy, and if the agent dies its journal recovers the previous route.
        if observing {
            try gateway.route(to: target)
            let verified = await observeSwitch(port: port, backendID: target.id)
            refreshDefaultRoute()
            guard verified, !Task.isCancelled, networkOnline, epoch == networkEpoch, mayCommit(),
                  gateway.activeBackendID == target.id, routeAlive(route) else {
                try revert()
                throw Failure.switchUnverified
            }
        }
        let oldJournal = journal
        journal.routes[port] = route
        journal.suspendedPorts?.remove(port)
        do { try persist() } catch {
            journal = oldJournal
            if observing { try revert() }
            throw Failure.persistenceFailed
        }
        if closeOld, let previousActive, previousActive != target.id {
            gateway.closeConnections(backendID: previousActive)
        }
        healthy[port] = true
        lastHealth[port] = .now
        lastProbe[route.primaryID] = .now
        recovery.removeValue(forKey: route.primaryID)
    }

    private func observeSwitch(port: Int, backendID: UUID) async -> Bool {
        if let isolatedSwitchVerification { return await isolatedSwitchVerification(port, backendID) }
        if let isolatedVerification { return await isolatedVerification(port) }
        // Keep both generations alive briefly before exercising the fixed
        // listener itself. Parallel protocols + two 3s targets fit the IPC deadline.
        do { try await Task.sleep(for: .seconds(2)) } catch { return false }
        guard gateways[port]?.activeBackendID == backendID else { return false }
        async let http = probe(port: port, scheme: "http", seconds: 3)
        async let socks = probe(port: port + 1, scheme: "socks5h", seconds: 3)
        let (httpOK, socksOK) = await (http, socks)
        return httpOK && socksOK
    }

    private func recordExit(port: Int, backendID: UUID, ip: String) throws {
        guard var route = journal.routes[port], route.primaryID == backendID,
              gateways[port]?.activeBackendID == backendID,
              let address = HarborIPAddress.normalizedLiteral(ip), !HarborIPAddress.isLocal(address) else {
            throw Failure.invalidRecord
        }
        guard route.observedExitIP != address else { return }
        let previous = journal
        if detachedFallback?.grant.primaryID == backendID { detachedFallback = nil }
        route.observedExitIP = address
        journal.routes[port] = route
        do { try persist() } catch { journal = previous; throw Failure.persistenceFailed }
    }

    private func backend(_ route: HarborProxyAgentRoute) throws -> HarborLocalProxyGateway.Backend {
        guard let primary = journal.engines[route.primaryID], (1024...65534).contains(primary.port) else {
            throw Failure.invalidRecord
        }
        return .init(id: primary.id, httpPort: UInt16(primary.port), socksPort: UInt16(primary.port + 1))
    }

    private func stopGateway(_ port: Int) throws {
        guard !systemReferences(port) else { throw Failure.systemProxyReference }
        let previous = journal
        journal.ports.remove(port)
        journal.routes.removeValue(forKey: port)
        journal.suspendedPorts?.remove(port)
        do { try persist() } catch {
            journal = previous
            throw Failure.persistenceFailed
        }
        gateways.removeValue(forKey: port)?.stop()
        healthy.removeValue(forKey: port)
        lastHealth.removeValue(forKey: port)
    }

    private func retireEngine(_ id: UUID) async throws {
        guard let record = journal.engines[id] else { return }
        guard journal.pendingRestarts?.contains(id) != true else { throw Failure.stopFailed }
        guard !journal.routes.values.contains(where: { $0.engines.contains(where: { $0.id == id }) }),
              !journal.engines.values.contains(where: { $0.dependencyIDs.contains(id) }),
              gateways.values.allSatisfy({ $0.connectionCount(backendID: id) == 0 }) else {
            throw Failure.engineInUse
        }
        guard await stopProcess(record), validPaths(record),
              !HarborLoopbackTCP.isListening(record.port), !HarborLoopbackTCP.isListening(record.port + 1) else {
            throw Failure.stopFailed
        }
        if record.promotedWARP {
            try? fm.removeItem(atPath: record.directoryPath)
            guard !fm.fileExists(atPath: record.directoryPath) else { throw Failure.stopFailed }
        } else {
            try? fm.removeItem(atPath: record.configurationPath)
            try? fm.removeItem(atPath: record.configurationPath + ".pid")
            try? fm.removeItem(atPath: record.directoryPath)
            guard !fm.fileExists(atPath: record.configurationPath),
                  !fm.fileExists(atPath: record.directoryPath) else { throw Failure.stopFailed }
        }
        let previous = journal
        journal.engines.removeValue(forKey: id)
        do { try persist() } catch {
            journal = previous
            throw Failure.persistenceFailed
        }
        children.removeValue(forKey: id)
    }

    private func stopProcess(_ record: HarborProxyAgentEngineRecord) async -> Bool {
        guard record.identity.isCurrent else {
            // A recycled PID is never signaled. The old port must also be
            // free before a restart or removal of its configuration.
            // Process identity can disappear just before the kernel releases
            // its listener sockets. Allow a bounded grace interval without
            // sending any signal to a new or unknown listener owner.
            let deadline = ContinuousClock.now + .seconds(1)
            repeat {
                if !HarborLoopbackTCP.isListening(record.port) && !HarborLoopbackTCP.isListening(record.port + 1) {
                    return true
                }
                if Task.isCancelled { return false }
                try? await Task.sleep(for: .milliseconds(50))
            } while ContinuousClock.now < deadline
            return false
        }
        guard validPaths(record), record.identity.matchesExecutable(at: executable(record.kind)) else { return false }
        if let child = children[record.id], child.processIdentifier == record.identity.pid {
            return await HarborProxyCommand.stop(child)
        }
        let identity = record.identity
        // A recovered record must describe this exact command, not just a
        // process running the same executable. Never signal another owner's
        // engine based only on a PID stored in the journal.
        let expected = executable(record.kind).path + (record.kind == .xray
            ? " run -config " + record.configurationPath
            : " -d " + record.directoryPath + " -f " + record.configurationPath)
        guard parentPID(identity.pid) == 1 || (isolatedVerification != nil && parentPID(identity.pid) == getpid()),
              let command = try? await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
                  arguments: ["-ww", "-p", String(identity.pid), "-o", "command="],
                  timeout: 3, outputLimit: 16_384),
              command.status == 0,
              String(decoding: command.data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == expected,
              identity.isCurrent else { return false }
        _ = Darwin.kill(identity.pid, SIGTERM)
        for _ in 0..<15 where identity.isCurrent {
            try? await Task.sleep(for: .milliseconds(50))
        }
        if identity.isCurrent {
            _ = Darwin.kill(identity.pid, SIGKILL)
            for _ in 0..<20 where identity.isCurrent {
                try? await Task.sleep(for: .milliseconds(50))
            }
        }
        return !identity.isCurrent
    }

    private func executable(_ kind: HarborProxyAgentEngineKind) -> URL {
        root.appendingPathComponent(kind.rawValue)
    }

    private func validPaths(_ record: HarborProxyAgentEngineRecord) -> Bool {
        guard (18200...19398).contains(record.port), record.configurationDigest.count == 32 else { return false }
        let file = URL(fileURLWithPath: record.configurationPath).standardizedFileURL
        let directory = URL(fileURLWithPath: record.directoryPath).standardizedFileURL
        let base = root.standardizedFileURL
        if record.promotedWARP {
            return record.kind == .mihomo && directory.deletingLastPathComponent().path == base.path
                && uuidSuffix(directory.lastPathComponent, prefix: "warp-probe-")
                && file.path == directory.appendingPathComponent("config.json").path
        }
        return file.deletingLastPathComponent().path == base.path && file.pathExtension == "json"
            && file.deletingPathExtension().lastPathComponent == "probe-runtime-\(record.id.uuidString)"
            && directory.path == file.deletingPathExtension().appendingPathExtension("data").path
    }

    private func uuidSuffix(_ name: String, prefix: String) -> Bool {
        name.hasPrefix(prefix) && UUID(uuidString: String(name.dropFirst(prefix.count))) != nil
    }

    private func privateRead(_ url: URL, limit: Int) throws -> Data {
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw Failure.invalidRecord }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              info.st_uid == getuid(), info.st_nlink == 1, info.st_mode & 0o077 == 0,
              info.st_size <= limit,
              let data = try handle.read(upToCount: limit + 1), data.count <= limit else {
            throw Failure.invalidRecord
        }
        return data
    }

    private func configurationValid(_ record: HarborProxyAgentEngineRecord) -> Bool {
        guard validPaths(record) else { return false }
        let file = URL(fileURLWithPath: record.configurationPath)
        let directory = URL(fileURLWithPath: record.directoryPath)
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o077 == 0,
              let data = try? privateRead(file, limit: 1_048_576),
              Data(SHA256.hash(data: data)) == record.configurationDigest else { return false }
        return configurationValid(data, kind: record.kind, port: record.port)
    }

    private func configurationValid(_ data: Data, kind: HarborProxyAgentEngineKind, port: Int) -> Bool {
        guard let document = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return false }
        if kind == .xray {
            let keys: Set<String> = ["log", "dns", "inbounds", "outbounds", "routing"]
            guard Set(document.keys).isSubset(of: keys),
                  let inbounds = document["inbounds"] as? [[String: Any]], inbounds.count == 2,
                  inbounds.allSatisfy({ $0["listen"] as? String == "127.0.0.1" }),
                  inbounds.contains(where: { $0["protocol"] as? String == "http" && $0["port"] as? Int == port }),
                  inbounds.contains(where: { $0["protocol"] as? String == "socks" && $0["port"] as? Int == port + 1 }),
                  let outbounds = document["outbounds"] as? [[String: Any]],
                  outbounds.allSatisfy({ ["vless", "vmess", "trojan", "shadowsocks", "freedom", "blackhole"].contains($0["protocol"] as? String ?? "") })
            else { return false }
        } else {
            let keys: Set<String> = ["port", "socks-port", "allow-lan", "bind-address", "mode", "log-level",
                "dns", "proxies", "rules", "geodata-mode", "hosts"]
            guard Set(document.keys).isSubset(of: keys),
                  document["allow-lan"] as? Bool == false, document["bind-address"] as? String == "127.0.0.1",
                  document["port"] as? Int == port, document["socks-port"] as? Int == port + 1,
                  let proxies = document["proxies"] as? [[String: Any]],
                  proxies.allSatisfy({ ["openvpn", "masque", "socks5"].contains($0["type"] as? String ?? "")
                      && $0["skip-cert-verify"] as? Bool != true }) else { return false }
        }
        return true
    }

    private func parentPID(_ pid: Int32) -> Int32? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard withUnsafeMutablePointer(to: &info, { proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, size) }) == size else {
            return nil
        }
        return Int32(info.pbi_ppid)
    }

    private func routeAlive(_ route: HarborProxyAgentRoute) -> Bool {
        guard route.engines.count == (route.underlayID == nil ? 1 : 2),
              Set(route.engines.map(\.id)) == Set([route.primaryID] + (route.underlayID.map { [$0] } ?? [])),
              let primary = journal.engines[route.primaryID],
              primary.dependencyIDs == Set(route.underlayID.map { [$0] } ?? []) else { return false }
        return route.engines.allSatisfy { item in
            guard let record = journal.engines[item.id], record.identity.isCurrent,
                  configurationValid(record) else { return false }
            return HarborLoopbackTCP.isListening(record.port) && HarborLoopbackTCP.isListening(record.port + 1)
        }
    }

    private func refreshedRoute(_ route: HarborProxyAgentRoute) -> HarborProxyAgentRoute {
        HarborProxyAgentRoute(nodeID: route.nodeID, endpointSignature: route.endpointSignature,
            primaryID: route.primaryID, underlayID: route.underlayID, underlayNodeID: route.underlayNodeID,
            warpEndpoint: route.warpEndpoint, ruleMode: route.ruleMode, forcedDomains: route.forcedDomains,
            localHostAddresses: route.localHostAddresses, observedExitIP: route.observedExitIP,
            engines: route.engines.compactMap { journal.engines[$0.id] })
    }

    private func snapshot() -> HarborProxyAgentSnapshot {
        .init(gateways: journal.ports.sorted().map { port in
            .init(port: port, ready: gateways[port]?.isReady == true,
                  route: journal.routes[port].map(refreshedRoute), healthy: healthy[port] == true,
                  lastHealth: lastHealth[port], routingBackendID: gateways[port]?.activeBackendID)
        }, engines: Array(journal.engines.values),
            pendingLaunchPorts: (journal.pendingLaunches ?? [:]).mapValues(\.port), operationInProgress: busy)
    }

    private func persist() throws {
        for (port, route) in Array(journal.routes) { journal.routes[port] = refreshedRoute(route) }
        let data = try JSONEncoder().encode(journal)
        guard data.count <= 1_048_576 else { throw Failure.persistenceFailed }
        let marker = activeMarker
        let needsKeepAlive = !restartSuppressed &&
            (!journal.ports.isEmpty || !journal.engines.isEmpty || !(journal.pendingLaunches ?? [:]).isEmpty)
        let hadMarker = fm.fileExists(atPath: marker.path)
        // Create the restart marker before the journal commit. After the
        // atomic rename succeeds, marker cleanup is best-effort and cannot
        // falsely report that a durable transaction was rolled back.
        if needsKeepAlive && !hadMarker { try atomicWrite(Data("active".utf8), to: marker) }
        do { try atomicWrite(data, to: journalURL) }
        catch {
            if needsKeepAlive && !hadMarker { try? fm.removeItem(at: marker) }
            throw error
        }
        if !needsKeepAlive && hadMarker { try? fm.removeItem(at: marker) }
    }

    private func atomicWrite(_ data: Data, to destination: URL) throws {
        let staged = root.appendingPathComponent(".agent-\(UUID().uuidString)")
        let fd = Darwin.open(staged.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw Failure.persistenceFailed }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close(); try? fm.removeItem(at: staged) }
        try handle.write(contentsOf: data)
        try handle.synchronize()
        try handle.close()
        guard Darwin.rename(staged.path, destination.path) == 0 else { throw Failure.persistenceFailed }
    }

    /// Check inactive services too: they may become active without warning.
    private func systemReferences(_ port: Int) -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy-agent" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] else { return true }
        if let effective = SCDynamicStoreCopyProxies(nil) as? [String: Any],
           HarborSystemProxyNetworkSetup.usesLoopback(effective, httpPort: port) { return true }
        return services.contains { service in
            guard let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  let values = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] else { return false }
            return HarborSystemProxyNetworkSetup.usesLoopback(values, httpPort: port)
        }
    }

    /// Reconcile the interval between a recovery launch and identity commit.
    /// Restart intents refer to existing configurations, never delete them.
    private func recoverPendingRestarts() async throws {
        for id in journal.pendingRestarts ?? [] {
            guard var record = journal.engines[id], configurationValid(record) else {
                throw Failure.invalidRecord
            }
            let identity: HarborProcessIdentity?
            if let child = children[id], child.isRunning {
                identity = HarborProcessIdentity.capture(pid: child.processIdentifier)
                guard identity != nil else { throw Failure.invalidRecord }
            } else if record.identity.isCurrent {
                identity = record.identity
            } else {
                let expected = executable(record.kind).path + (record.kind == .xray
                    ? " run -config " + record.configurationPath
                    : " -d " + record.directoryPath + " -f " + record.configurationPath)
                let result = try await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
                    arguments: ["-axww", "-o", "uid=", "-o", "pid=", "-o", "ppid=", "-o", "command="],
                    timeout: 3, outputLimit: 2_000_000)
                guard result.status == 0 else { throw Failure.stopFailed }
                let matches = String(decoding: result.data, as: UTF8.self)
                    .split(whereSeparator: \.isNewline).compactMap { line -> HarborProcessIdentity? in
                        let fields = line.split(maxSplits: 3, whereSeparator: \.isWhitespace)
                        guard fields.count == 4, UInt32(fields[0]) == getuid(), fields[2] == "1",
                              fields[3] == expected, let pid = Int32(fields[1]),
                              let found = HarborProcessIdentity.capture(pid: pid),
                              found.matchesExecutable(at: executable(record.kind))
                        else { return nil }
                        return found
                    }
                guard matches.count <= 1 else { throw Failure.invalidRecord }
                identity = matches.first
            }
            if let identity {
                guard identity.isCurrent,
                      identity.matchesExecutable(at: executable(record.kind)) else {
                    throw Failure.invalidRecord
                }
                record.identity = identity
            } else {
                guard !HarborLoopbackTCP.isListening(record.port),
                      !HarborLoopbackTCP.isListening(record.port + 1) else { throw Failure.stopFailed }
            }
            let previous = journal
            journal.engines[id] = record
            journal.pendingRestarts?.remove(id)
            do { try persist() } catch { journal = previous; throw error }
        }
    }

    private func restartEngine(_ id: UUID) async -> Bool {
        guard var record = journal.engines[id], configurationValid(record),
              journal.pendingRestarts?.contains(id) != true, !record.identity.isCurrent,
              !HarborLoopbackTCP.isListening(record.port), !HarborLoopbackTCP.isListening(record.port + 1) else { return false }
        let beforeIntent = journal
        journal.pendingRestarts = (journal.pendingRestarts ?? []).union([id])
        do { try persist() } catch { journal = beforeIntent; return false }
        let process = Process()
        configure(process, kind: record.kind, file: URL(fileURLWithPath: record.configurationPath),
                  directory: URL(fileURLWithPath: record.directoryPath))
        do {
            try process.run()
            children[id] = process
            guard let identity = HarborProcessIdentity.capture(pid: process.processIdentifier),
                  identity.matchesExecutable(at: executable(record.kind)) else {
                throw Failure.invalidRecord
            }
            record.identity = identity
            let previous = journal
            journal.engines[id] = record
            journal.pendingRestarts?.remove(id)
            do { try persist() } catch { journal = previous; throw error }
            let deadline = ContinuousClock.now + .seconds(8)
            while process.isRunning, ContinuousClock.now < deadline {
                if HarborLoopbackTCP.isListening(record.port), HarborLoopbackTCP.isListening(record.port + 1),
                   identity.isCurrent { return true }
                try await Task.sleep(for: .milliseconds(75))
            }
        } catch {}
        if await HarborProxyCommand.stop(process) {
            try? await recoverPendingRestarts()
        }
        return false
    }

    private func verify(_ route: HarborProxyAgentRoute) async -> Bool {
        guard let record = journal.engines[route.primaryID], routeAlive(route), networkOnline else { return false }
        if let isolatedVerification { return await isolatedVerification(record.port) && routeAlive(route) }
        async let http = probe(port: record.port, scheme: "http")
        async let socks = probe(port: record.port + 1, scheme: "socks5h")
        let (a, b) = await (http, socks)
        guard a && b && routeAlive(route) else { return false }
        if route.nodeID == HarborIndependentWARP.nodeID {
            return await HarborWARPConnectivity.check(httpPort: record.port).verified && routeAlive(route)
        }
        return true
    }

    private func probe(port: Int, scheme: String, seconds: Int = 6) async -> Bool {
        for target in ["https://www.gstatic.com/generate_204", "https://example.com/"] {
            let result = try? await HarborProxyCommand.run(URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["--disable", "--silent", "--fail", "--max-time", String(seconds), "--max-filesize", "16384",
                    "--proto", "=https", "--proxy", "\(scheme)://127.0.0.1:\(port)", "--noproxy", "",
                    "--output", "/dev/null", "--write-out", "%{http_code}", "--url", target],
                timeout: TimeInterval(seconds) + 0.5, outputLimit: 32)
            if let result, result.status == 0,
               let code = Int(String(decoding: result.data, as: UTF8.self)),
               (200..<300).contains(code), !target.hasSuffix("generate_204") || code == 204 { return true }
        }
        return false
    }

    private func tick() async {
        guard startupError == nil, !busy else { return }
        busy = true
        defer { busy = false }
        if !hasLiveController && journal.ports.isEmpty && journal.engines.isEmpty && (journal.pendingLaunches ?? [:]).isEmpty {
            if let idleSince, Date.now.timeIntervalSince(idleSince) >= 60 { exit(0) }
            if idleSince == nil { idleSince = .now }
            return
        }
        idleSince = nil
        guard !hasLiveController else { return } // The responsive UI coordinates live switching.
        refreshDefaultRoute()
        let generation = recoveryGeneration
        let epoch = networkEpoch
        func valid() -> Bool {
            refreshDefaultRoute()
            return !hasLiveController && networkOnline && generation == recoveryGeneration && epoch == networkEpoch
        }
        try? await recoverPendingLaunches()
        try? await recoverPendingRestarts()
        guard !hasLiveController, generation == recoveryGeneration else { return }
        // Retire abandoned candidates/old drained backends, dependents first.
        for _ in 0..<6 {
            let removable = journal.engines.values.filter { record in
                !journal.routes.values.contains(where: { $0.engines.contains(where: { $0.id == record.id }) })
                    && !journal.engines.values.contains(where: { $0.dependencyIDs.contains(record.id) })
                    && gateways.values.allSatisfy { $0.connectionCount(backendID: record.id) == 0 }
            }
            guard !removable.isEmpty else { break }
            let count = journal.engines.count
            for record in removable {
                guard !hasLiveController, generation == recoveryGeneration else { return }
                try? await retireEngine(record.id)
            }
            if journal.engines.count == count { break }
        }
        guard valid() else { return }
        for port in journal.ports.sorted() {
            guard valid() else { return }
            guard let gateway = gateways[port] else { continue }
            if !gateway.isReady {
                healthy[port] = false
                try? await gateway.start()
            }
            if journal.routes[port] == nil, !systemReferences(port) { try? stopGateway(port) }
        }
        var handled = Set<UUID>()
        for route in Array(journal.routes.values) where handled.insert(route.primaryID).inserted {
            guard valid() else { return }
            let id = route.primaryID
            let ports = journal.routes.filter { $0.value.primaryID == id }.map(\.key)
            var state = recovery[id] ?? Recovery()
            guard .now >= state.nextAttempt else { continue }
            let alive = routeAlive(route)
            let due = Date.now.timeIntervalSince(lastProbe[id] ?? .distantPast) >= HarborProxyHealthPolicy.healthInterval
            if alive && !due && ports.allSatisfy({ healthy[$0] == true && gateways[$0]?.isReady == true && gateways[$0]?.activeBackendID == id }) { continue }
            lastProbe[id] = .now
            let verified = alive ? await verify(route) : false
            guard valid() else { return }
            if verified {
                if publishRecoveredRoute(route, ports: ports) {
                    recovery.removeValue(forKey: id)
                } else {
                    state.nextAttempt = .now + .seconds(10)
                    recovery[id] = state
                }
                continue
            }
            if state.cooling { state.policy.cooldownElapsed(); state.cooling = false }
            let action = state.policy.recordFailure(engineUnavailable: !alive)
            if case .recheck(let delay) = action {
                for port in ports { healthy[port] = false }
                state.nextAttempt = .now + .seconds(delay)
                recovery[id] = state
                continue
            }
            guard state.policy.beginRecovery() else {
                scheduleFailure(&state)
                recovery[id] = state
                continue
            }
            for port in ports {
                gateways[port]?.suspendRouting(closeExisting: true)
                healthy[port] = false
            }
            // Recovery uses the same verified configuration and ports; no
            // unapproved node, different network class or direct fallback.
            let ids = [route.primaryID] + (route.underlayID.map { [$0] } ?? [])
            var stopped = true
            for engineID in ids {
                guard valid() else { return }
                guard journal.pendingRestarts?.contains(engineID) != true,
                      let record = journal.engines[engineID], await stopProcess(record) else { stopped = false; break }
                guard valid() else { return }
            }
            var rebuilt = stopped
            if rebuilt {
                for engineID in ids.reversed() {
                    guard valid() else { return }
                    if !(await restartEngine(engineID)) { rebuilt = false; break }
                    guard valid() else { return }
                }
            }
            let verifiedRebuild = rebuilt ? await verify(route) : false
            guard valid() else { return }
            if verifiedRebuild && publishRecoveredRoute(route, ports: ports) {
                recovery.removeValue(forKey: id)
            } else {
                if state.policy.recoveryAttempts >= HarborProxyHealthPolicy.recoveryLimit,
                   await tryDetachedFallback(route: route, ports: ports, valid: valid) {
                    recovery.removeValue(forKey: id)
                    continue
                }
                guard valid() else { return }
                scheduleFailure(&state)
                recovery[id] = state
            }
        }
    }

    /// A detached grant is never written to disk. Reconnection, network
    /// change, or an explicit stop revokes it synchronously.
    private func configureDetachedFallback(_ grant: HarborDetachedFallbackGrant?) throws {
        detachedFallback = nil
        guard let grant else { return }
        guard controllerLease.liveCount() == 1, networkOnline, pathFingerprint != nil, defaultRouteFingerprint != nil,
              journal.ports.count == 1, journal.routes.count == 1,
              let route = journal.routes.values.first, route.primaryID == grant.primaryID,
              route.nodeID == grant.sourceNode.id,
              route.endpointSignature == grant.sourceNode.endpointSignature,
              let ip = route.observedExitIP,
              let constraint = HarborProxyFallbackPolicy.ExitConstraint(evidence: grant.sourceEvidence, observedIP: ip),
              !grant.candidates.isEmpty, grant.candidates.count <= 3,
              Set(grant.candidates.map(\.id)).count == grant.candidates.count,
              grant.candidates.allSatisfy({
                  $0.id != route.nodeID && $0.protocolName == grant.sourceNode.protocolName
                    && !HarborIndependentWARP.isBuiltIn($0)
              }),
              (route.underlayID == nil) == (grant.underlayNode == nil),
              (route.warpEndpoint == nil) == (grant.warpAccount == nil)
        else { throw Failure.invalidRecord }
        if let base = grant.underlayNode {
            guard let id = route.underlayID, route.underlayNodeID == base.id,
                  let record = journal.engines[id], configurationValid(record),
                  let bytes = try? privateRead(URL(fileURLWithPath: record.configurationPath), limit: 512 * 1024),
                  let expected = try? HarborXrayConfig.make(node: base, httpPort: record.port,
                      ruleMode: false, routeAllViaProxy: true),
                  let actual = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  let template = try? JSONSerialization.jsonObject(with: expected) as? [String: Any],
                  let a = (actual["outbounds"] as? [[String: Any]])?.first(where: { $0["tag"] as? String == "proxy" }),
                  let b = (template["outbounds"] as? [[String: Any]])?.first(where: { $0["tag"] as? String == "proxy" }),
                  NSDictionary(dictionary: a).isEqual(to: b) else { throw Failure.invalidRecord }
        }
        if let account = grant.warpAccount { try account.validate() }
        detachedFallback = DetachedFallback(grant: grant, constraint: constraint,
            epoch: networkEpoch, remaining: grant.candidates)
    }

    private func detachedProtectedPorts() -> Set<Int> {
        let ports = Array(journal.ports) + journal.engines.values.map(\.port)
            + (journal.pendingLaunches ?? [:]).values.map(\.port)
        return Set(ports.flatMap { [$0, $0 + 1] })
    }

    private func detachedPort() -> Int? {
        let occupied = detachedProtectedPorts()
        return stride(from: 18200, through: 19398, by: 2).first {
            !occupied.contains($0) && !occupied.contains($0 + 1)
                && !HarborLoopbackTCP.isListening($0) && !HarborLoopbackTCP.isListening($0 + 1)
        }
    }

    /// One attempt per cooldown, with no direct or different-underlay
    /// retry. The old route remains journaled until a new route is verified.
    private func tryDetachedFallback(route: HarborProxyAgentRoute, ports: [Int],
                                     valid: () -> Bool) async -> Bool {
        guard valid(), var plan = detachedFallback, plan.epoch == networkEpoch,
              plan.grant.primaryID == route.primaryID, ports.count == 1, let entry = ports.first,
              gateways[entry]?.isReady == true, let ip = route.observedExitIP,
              plan.constraint.matches(evidence: plan.grant.sourceEvidence, observedIP: ip),
              .now >= plan.nextAttempt, !plan.remaining.isEmpty
        else { return false }
        let node = plan.remaining.removeFirst()
        plan.nextAttempt = .now + .seconds(60)
        detachedFallback = plan
        var baseID: UUID?
        var mainID: UUID?
        let aliases = route.localHostAddresses.filter {
            $0.value.contains(where: HarborGatewayConfiguration.isLoopback)
        }.keys.sorted()

        // Conservative recursion boundary: a detached recovery never probes
        // a server on one of our reserved ports, even if DNS is ambiguous.
        func allowedEndpoint(_ node: HarborProxyNode) -> Bool {
            (1...65535).contains(node.port)
                && !(18200...19399).contains(node.port)
                && !detachedProtectedPorts().contains(node.port)
                && !HarborGatewayConfiguration.isLoopback(node.host)
        }

        do {
            guard allowedEndpoint(node) else { throw Failure.invalidRecord }
            var basePort: Int?
            if let base = plan.grant.underlayNode {
                guard allowedEndpoint(base), let port = detachedPort() else { throw Failure.resourceLimit }
                let id = UUID()
                baseID = id
                let data = try HarborGatewayConfiguration.protectXray(
                    HarborXrayConfig.make(node: base, httpPort: port, ruleMode: false, routeAllViaProxy: true),
                    ports: detachedProtectedPorts().union([port, port + 1]), aliases: aliases)
                try await startEngine(id: id, kind: .xray, port: port, data: data, dependencies: [])
                basePort = port
                guard valid() else { throw CancellationError() }
            }
            guard let port = detachedPort() else { throw Failure.resourceLimit }
            let id = UUID()
            mainID = id
            let protected = detachedProtectedPorts().union([port, port + 1])
            let openVPN = node.protocolName == "openvpn"
            let warp = route.warpEndpoint.flatMap { endpoint in
                plan.grant.warpAccount.map { HarborWARPProfile(account: $0, endpoint: endpoint) }
            }
            let data: Data
            if openVPN {
                let config = try HarborMihomoConfig.make(node: node, httpPort: port,
                    underlaySocksPort: basePort.map { $0 + 1 }, warpProfile: warp,
                    ruleMode: route.ruleMode, forcedProxyDomains: route.forcedDomains,
                    localHosts: route.localHostAddresses.keys.sorted(),
                    verificationHost: "www.gstatic.com", localHostAddresses: route.localHostAddresses)
                data = try HarborGatewayConfiguration.protectMihomo(config, ports: protected, aliases: aliases)
            } else {
                guard baseID == nil, warp == nil else { throw Failure.invalidRecord }
                let config = try HarborXrayConfig.make(node: node, httpPort: port,
                    ruleMode: route.ruleMode, forcedProxyDomains: route.forcedDomains,
                    routeVerificationViaProxy: true, verificationHost: "www.gstatic.com",
                    localHosts: route.localHostAddresses.keys.sorted())
                data = try HarborGatewayConfiguration.protectXray(config, ports: protected, aliases: aliases)
            }
            try await startEngine(id: id, kind: openVPN ? .mihomo : .xray, port: port,
                data: data, dependencies: Set(baseID.map { [$0] } ?? []))
            guard valid(), let primary = journal.engines[id] else { throw CancellationError() }
            let records = [primary] + (baseID.flatMap { journal.engines[$0] }.map { [$0] } ?? [])
            // Both protocols must work before accepting the reported exit.
            let http = await probe(port: port, scheme: "http")
            guard valid(), http else { throw Failure.invalidRecord }
            let socks = await probe(port: port + 1, scheme: "socks5h")
            guard valid(), socks, let exit = await HarborDetachedFallbackVerification.observedIP(socksPort: port + 1),
                  valid() else { throw Failure.invalidRecord }
            let evidence = await HarborDetachedFallbackVerification.evidence(ip: exit, httpPort: port)
            guard valid(), detachedFallback?.grant.primaryID == route.primaryID,
                  plan.constraint.matches(evidence: plan.grant.sourceEvidence, observedIP: ip),
                  plan.constraint.matches(evidence: evidence, observedIP: exit),
                  journal.routes[entry]?.primaryID == route.primaryID else { throw Failure.invalidRecord }
            let candidate = HarborProxyAgentRoute(nodeID: node.id, endpointSignature: node.endpointSignature,
                primaryID: id, underlayID: baseID, underlayNodeID: plan.grant.underlayNode?.id,
                warpEndpoint: warp?.endpoint, ruleMode: route.ruleMode, forcedDomains: route.forcedDomains,
                localHostAddresses: route.localHostAddresses, observedExitIP: exit, engines: records)
            guard routeAlive(candidate) else { throw Failure.invalidRecord }
            try await commit(port: entry, route: candidate, closeOld: true, mayCommit: valid)
            // Do not cascade fallback authorization to a different source.
            detachedFallback = nil
            return true
        } catch {
            // If persistence became ambiguous, retirement itself refuses to
            // remove a referenced engine. Keep those records for reconciliation.
            if let mainID { try? await retireEngine(mainID) }
            if let baseID { try? await retireEngine(baseID) }
            return false
        }
    }

    /// Publish only when the forwarding target actually changes successfully.
    /// A failed listener bind or journal write never counts as network health.
    private func publishRecoveredRoute(_ route: HarborProxyAgentRoute, ports: [Int]) -> Bool {
        guard routeAlive(route), let target = try? backend(route) else { return false }
        var recovered = Set<Int>()
        for port in ports {
            guard let gateway = gateways[port], gateway.isReady else {
                healthy[port] = false; continue
            }
            do {
                try gateway.route(to: target)
                guard gateway.activeBackendID == target.id else { throw Failure.invalidRecord }
                recovered.insert(port)
            } catch { healthy[port] = false }
        }
        let oldSuspension = journal.suspendedPorts
        journal.suspendedPorts?.subtract(recovered)
        do { try persist() } catch {
            journal.suspendedPorts = oldSuspension
            for port in recovered {
                gateways[port]?.suspendRouting(closeExisting: true)
                healthy[port] = false
            }
            return false
        }
        for port in recovered {
            healthy[port] = true
            lastHealth[port] = .now
        }
        return recovered.count == ports.count
    }

    private func scheduleFailure(_ state: inout Recovery) {
        switch state.policy.recoveryFailed() {
        case .recover(let delay): state.nextAttempt = .now + .seconds(delay)
        case .cooldown(let delay):
            state.cooling = true
            state.nextAttempt = .now + .seconds(delay)
        default: state.nextAttempt = .now + .seconds(60)
        }
    }
}
