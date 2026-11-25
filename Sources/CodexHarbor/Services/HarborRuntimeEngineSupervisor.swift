import CodexHarborCore
import CryptoKit
import Foundation

/// Owns the live engine handles for fixed-gateway connections. Formal
/// connections have their own bounded budget, independent of background probes.
@MainActor
final class HarborRuntimeEngineSupervisor {
    typealias Kind = HarborProxyAgentEngineKind

    final class Engine {
        let id: UUID
        let kind: Kind
        let port: Int
        var process: Process?
        let configuration: URL
        let digest: Data
        let dependencyIDs: Set<UUID>
        var identity: HarborProcessIdentity?
        var promotedDirectory: URL?
        let createdAt: Date
        var managedByAgent = false

        init(kind: Kind, port: Int, process: Process, configuration: URL, data: Data, dependencies: [Engine]) {
            self.id = UUID()
            self.createdAt = Date()
            self.kind = kind
            self.port = port
            self.process = process
            self.configuration = configuration
            self.digest = Data(SHA256.hash(data: data))
            self.dependencyIDs = Set(dependencies.map(\.id))
        }

        init(record: HarborProxyAgentEngineRecord) {
            id = record.id; kind = record.kind; port = record.port
            process = nil; configuration = URL(fileURLWithPath: record.configurationPath)
            digest = record.configurationDigest; dependencyIDs = record.dependencyIDs
            identity = record.identity; createdAt = record.createdAt
            promotedDirectory = record.promotedWARP ? URL(fileURLWithPath: record.directoryPath) : nil
            managedByAgent = true
        }

        var agentRecord: HarborProxyAgentEngineRecord? {
            guard let identity else { return nil }
            return .init(id: id, kind: kind, port: port, identity: identity,
                configurationPath: configuration.path, configurationDigest: digest,
                directoryPath: (promotedDirectory ?? configuration.deletingPathExtension().appendingPathExtension("data")).path,
                dependencyIDs: dependencyIDs, createdAt: createdAt, promotedWARP: promotedDirectory != nil)
        }

        var isAlive: Bool { (process?.isRunning ?? true) && identity?.isCurrent == true }

        var configurationUnchanged: Bool {
            guard let data = try? Data(contentsOf: configuration) else { return false }
            return Data(SHA256.hash(data: data)) == digest
        }
    }

    private var engines: [UUID: Engine] = [:]
    private var stoppingIDs = Set<UUID>()
    private let limit = 6
    var hasEngines: Bool { !engines.isEmpty || !uncertainPorts.isEmpty }

    func adopt(_ records: [HarborProxyAgentEngineRecord]) {
        for record in records {
            HarborNodeLatencyTester.retainResidentPortPair(record.port)
            if let existing = engines[record.id] {
                if existing.identity != record.identity { existing.process = nil }
                existing.identity = record.identity
                existing.managedByAgent = true
            } else {
                engines[record.id] = Engine(record: record)
            }
        }
    }

    func adoptSnapshot(_ snapshot: HarborProxyAgentSnapshot) {
        adopt(snapshot.engines)
        for (id, port) in snapshot.pendingLaunchPorts ?? [:] where engines[id] == nil {
            HarborNodeLatencyTester.retainResidentPortPair(port)
            uncertainPorts[id] = port
        }
        reconcileUncertain(snapshot)
    }

    func engine(_ id: UUID) -> Engine? { engines[id] }

    private var uncertainPorts: [UUID: Int] = [:]

    func start(kind: Kind, root: URL, cancellation: HarborLatencyCancellation,
               dependencies: [Engine] = [], configuration: (Int) throws -> Data) async throws -> Engine {
        guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        guard dependencies.allSatisfy({ engines[$0.id] != nil && $0.isAlive }),
              engines.count + uncertainPorts.count < limit,
              let port = HarborNodeLatencyTester.reservePortPair() else {
            throw HarborProxyError.invalid("正式连接资源已达上限")
        }
        let id = UUID()
        let data: Data
        do { data = try configuration(port) }
        catch {
            HarborNodeLatencyTester.releasePortPair(port)
            throw error
        }
        uncertainPorts[id] = port
        let command = HarborProxyAgentCommand.startEngine(id: id, kind: kind, port: port,
            configuration: data, dependencies: Set(dependencies.map(\.id)))
        let snapshot: HarborProxyAgentSnapshot
        do {
            guard let result = try await HarborProxyAgentClient.shared.call(command).snapshot else {
                throw HarborProxyAgentClient.Failure.invalidReply
            }
            snapshot = result
        } catch {
            // The launch could have reached the service before the reply
            // was lost. Never release a possibly resident port on timeout.
            if let actual = try? await HarborProxyAgentClient.shared.inspect() {
                adopt(actual.engines)
                reconcileUncertain(actual)
                if actual.operationInProgress != true,
                   let engine = engines[id], engine.isAlive, engine.configurationUnchanged,
                   HarborLoopbackTCP.isListening(port), HarborLoopbackTCP.isListening(port + 1) {
                    if cancellation.isCancelled || Task.isCancelled {
                        _ = await stop(engine)
                        throw CancellationError()
                    }
                    return engine
                }
            }
            throw error
        }
        adopt(snapshot.engines)
        uncertainPorts.removeValue(forKey: id)
        guard let engine = engines[id], engine.isAlive, engine.configurationUnchanged else {
            // A malformed/missing success record is not permission to free the port.
            if engines[id] == nil { uncertainPorts[id] = port }
            throw HarborProxyError.invalid("正式连接内核身份或配置未确认")
        }
        guard !cancellation.isCancelled, !Task.isCancelled else {
            _ = await stop(engine)
            throw CancellationError()
        }
        return engine
    }

    private func reconcileUncertain(_ snapshot: HarborProxyAgentSnapshot) {
        let pending = snapshot.pendingLaunchPorts ?? [:]
        let liveIDs = Set(snapshot.engines.map(\.id))
        for (id, port) in Array(uncertainPorts) {
            if liveIDs.contains(id) {
                uncertainPorts.removeValue(forKey: id)
            } else if snapshot.operationInProgress == false && pending[id] == nil
                      && !HarborLoopbackTCP.isListening(port) && !HarborLoopbackTCP.isListening(port + 1) {
                uncertainPorts.removeValue(forKey: id)
                HarborNodeLatencyTester.releasePortPair(port)
            }
        }
    }

    /// Keep failed stops registered, including their port reservations.
    /// Subsequent cleanup retries must never free a still-running engine.
    @discardableResult
    func stop(_ engine: Engine) async -> Bool {
        guard engines[engine.id] != nil else { return true }
        guard !stoppingIDs.contains(engine.id),
              !engines.values.contains(where: { $0.dependencyIDs.contains(engine.id) }) else { return false }
        stoppingIDs.insert(engine.id)
        defer { stoppingIDs.remove(engine.id) }
        // A live PID that no longer identifies our child must not be signaled.
        if engine.managedByAgent {
            let snapshot = (try? await HarborProxyAgentClient.shared.call(.stopEngine(id: engine.id)).snapshot)
            let actual: HarborProxyAgentSnapshot?
            if let snapshot { actual = snapshot }
            else { actual = try? await HarborProxyAgentClient.shared.inspect() }
            guard let actual, !actual.engines.contains(where: { $0.id == engine.id }),
                  actual.pendingLaunchPorts?[engine.id] == nil,
                  engine.identity?.isCurrent != true,
                  !HarborLoopbackTCP.isListening(engine.port),
                  !HarborLoopbackTCP.isListening(engine.port + 1) else { return false }
            engines.removeValue(forKey: engine.id)
            uncertainPorts.removeValue(forKey: engine.id)
            HarborNodeLatencyTester.releasePortPair(engine.port)
            return true
        }
        if let process = engine.process, process.isRunning {
            guard engine.identity?.isCurrent == true,
                  await HarborProxyCommand.stop(process) else { return false }
        } else if engine.identity?.isCurrent == true { return false }
        guard engines.removeValue(forKey: engine.id) != nil else { return true }
        if let directory = engine.promotedDirectory {
            try? FileManager.default.removeItem(at: directory)
        } else {
            HarborProbeFiles.remove(engine.configuration)
        }
        HarborNodeLatencyTester.releasePortPair(engine.port)
        return true
    }

    @discardableResult
    func reap(excluding retained: Set<UUID>) async -> Bool {
        // Reconcile lost launch replies and resident records before retiring
        // dependent engines. No local process signals for resident candidates.
        if hasEngines {
            guard let snapshot = try? await HarborProxyAgentClient.shared.inspect(),
                  snapshot.operationInProgress == false else { return false }
            adopt(snapshot.engines)
            reconcileUncertain(snapshot)
            for id in (snapshot.pendingLaunchPorts ?? [:]).keys where !retained.contains(id) {
                _ = try? await HarborProxyAgentClient.shared.call(.stopEngine(id: id))
            }
            if let refreshed = try? await HarborProxyAgentClient.shared.inspect() {
                adopt(refreshed.engines)
                reconcileUncertain(refreshed)
                guard (refreshed.pendingLaunchPorts ?? [:]).isEmpty else { return false }
            } else { return false }
        }
        // Stop dependents before their bases; failed stops retain both.
        for _ in 0..<limit {
            let removable = engines.values.filter { engine in
                !retained.contains(engine.id) && !engines.values.contains {
                    $0.dependencyIDs.contains(engine.id)
                }
            }
            guard !removable.isEmpty else { break }
            let count = engines.count
            for engine in removable { _ = await stop(engine) }
            if engines.count == count { break }
        }
        return uncertainPorts.isEmpty && engines.keys.allSatisfy { retained.contains($0) }
    }
}
