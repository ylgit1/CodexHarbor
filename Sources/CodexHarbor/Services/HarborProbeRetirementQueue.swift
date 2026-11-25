import CodexHarborCore
import Foundation

/// Failed stops retain their actual Process, identity, configuration and
/// permits. A bounded retry loop releases them only after the child is gone.
/// At most the engine-budget count can be present at once.
actor HarborProbeRetirementQueue {
    static let shared = HarborProbeRetirementQueue()

    struct Resource: Sendable {
        let process: Process
        let config: URL
        let directory: URL?
        let port: Int
        let portCount: Int
        let lease: UUID

        init(process: Process, config: URL, directory: URL? = nil, port: Int,
             portCount: Int = 2, lease: UUID) {
            self.process = process
            self.config = config
            self.directory = directory
            self.port = port
            self.portCount = portCount
            self.lease = lease
        }
    }

    private struct Pending {
        let resource: Resource
        let identity: HarborProcessIdentity?
        var attempt: Int
    }

    private var pending: [UUID: Pending] = [:]
    private var active: Set<UUID> = []
    private var timer: Task<Void, Never>?

    @discardableResult
    func retire(_ resource: Resource) async -> Bool {
        guard pending[resource.lease] == nil, active.insert(resource.lease).inserted else { return false }
        let identity = resource.process.isRunning
            ? HarborProcessIdentity.capture(pid: resource.process.processIdentifier) : nil
        let item = Pending(resource: resource, identity: identity, attempt: 0)
        let done = await dispose(item)
        active.remove(resource.lease)
        if !done {
            pending[resource.lease] = item
            schedule()
        }
        return done
    }

    private func dispose(_ item: Pending) async -> Bool {
        let resource = item.resource
        if resource.process.isRunning {
            guard item.identity?.isCurrent == true,
                  await HarborProxyCommand.stop(resource.process) else { return false }
        }
        // Do not release port or engine capacity until the child has stopped.
        if let directory = resource.directory {
            try? FileManager.default.removeItem(at: directory)
            guard !FileManager.default.fileExists(atPath: directory.path) else { return false }
        } else {
            HarborProbeFiles.remove(resource.config)
            guard !FileManager.default.fileExists(atPath: resource.config.path),
                  !FileManager.default.fileExists(atPath: resource.config.appendingPathExtension("pid").path) else {
                return false
            }
        }
        HarborNodeLatencyTester.releasePortRange(resource.port, count: resource.portCount)
        await HarborProbeBudget.engines.release(resource.lease)
        return true
    }

    private func schedule() {
        guard timer == nil, !pending.isEmpty else { return }
        let attempt = pending.values.map(\.attempt).min() ?? 0
        let delay = min(300, 3 * (1 << min(7, attempt)))
        timer = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(delay)) } catch { return }
            await self?.retry()
        }
    }

    private func retry() async {
        // Keep the timer marker during the pass so reentrant submissions
        // cannot start a second concurrent sweep.
        for id in Array(pending.keys) {
            guard var item = pending[id] else { continue }
            if await dispose(item) {
                pending.removeValue(forKey: id)
            } else {
                item.attempt = min(8, item.attempt + 1)
                pending[id] = item
            }
        }
        timer = nil
        schedule()
    }

    var pendingCount: Int { pending.count + active.count }
}
