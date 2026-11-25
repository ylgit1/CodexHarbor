import CodexHarborCore
import Foundation

/// One discovery per account/network epoch. A caller owns a lease, not the
/// shared process; canceling a screening request cannot kill another caller's
/// verified tunnel. A standalone connection may take ownership when exclusive.
@MainActor
final class HarborWARPDiscoveryPool {
    struct Key: Equatable, Sendable {
        let accountID: String
        let networkEpoch: UInt64
    }

    @MainActor
    final class Lease {
        let id: UUID
        let tunnel: HarborWARPTunnel
        private weak var pool: HarborWARPDiscoveryPool?
        var profile: HarborWARPProfile { tunnel.profile }
        var httpPort: Int { tunnel.httpPort }
        var socksPort: Int { tunnel.socksPort }
        var canPromote: Bool { pool?.canPromote(id) == true }

        fileprivate init(id: UUID, tunnel: HarborWARPTunnel, pool: HarborWARPDiscoveryPool) {
            self.id = id
            self.tunnel = tunnel
            self.pool = pool
        }

        func close() async {
            guard let pool else { return }
            self.pool = nil
            await pool.release(id)
        }

        func promote() async -> HarborWARPTunnel.PromotedRuntime? {
            guard let pool, pool.canPromote(id) else { return nil }
            self.pool = nil
            return await pool.promote(id)
        }
    }

    private struct Waiter {
        let cancellation: HarborLatencyCancellation
        let continuation: CheckedContinuation<Lease, any Error>
    }

    private struct Flight {
        let id: UUID
        let key: Key
        let cancellation: HarborLatencyCancellation
        let task: Task<Void, Never>
    }

    private struct Active {
        let key: Key
        let tunnel: HarborWARPTunnel
        var leases: Set<UUID>
    }

    private var flight: Flight?
    private var active: Active?
    private var waiters: [UUID: Waiter] = [:]
    private var failureKey: Key?
    private var failureCount = 0
    private var retryAfter: ContinuousClock.Instant?
    private var cleanupTasks: [UUID: Task<Void, Never>] = [:]
    private let waiterLimit = 32

    func acquire(account: HarborWARPAccount, preferred: HarborWARPEndpoint?, root: URL,
                 networkEpoch: UInt64, cancellation: HarborLatencyCancellation) async throws -> Lease {
        let key = Key(accountID: account.id, networkEpoch: networkEpoch)
        guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
        if (flight.map { $0.key != key } ?? false) || (active.map { $0.key != key } ?? false) {
            invalidate()
        }
        if let current = active, current.key == key, current.tunnel.isUsable {
            let id = UUID()
            active?.leases.insert(id)
            return Lease(id: id, tunnel: current.tunnel, pool: self)
        }
        if let current = active {
            active = nil
            retire(current.tunnel)
        }
        if failureKey == key, let retryAfter, .now < retryAfter {
            throw HarborProxyError.invalid("独立 WARP 通道暂处冷却期，请稍后重试")
        }

        let request = UUID()
        let observer = cancellation.observe { [weak self] in
            Task { @MainActor [weak self] in self?.cancelWaiter(request) }
        }
        defer { if let observer { cancellation.removeObserver(observer) } }
        let lease = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Lease, any Error>) in
                guard !Task.isCancelled, !cancellation.isCancelled else {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                guard waiters.count < waiterLimit else {
                    continuation.resume(throwing: HarborProxyError.invalid("独立通道等待队列已满"))
                    return
                }
                waiters[request] = Waiter(cancellation: cancellation, continuation: continuation)
                guard flight == nil else { return }
                let id = UUID()
                let sharedCancellation = HarborLatencyCancellation()
                let priority = HarborProbeScope.priority
                let task = Task { [weak self] in
                    let result: Result<HarborWARPTunnel, any Error>
                    do {
                        let tunnel = try await HarborProbeScope.$priority.withValue(priority) {
                            try await HarborWARPTunnel.prepare(account: account, preferred: preferred,
                                                              root: root, cancellation: sharedCancellation)
                        }
                        result = .success(tunnel)
                    } catch {
                        result = .failure(error)
                    }
                    guard let self else {
                        if case .success(let tunnel) = result { await tunnel.close() }
                        return
                    }
                    await self.complete(id: id, key: key, result: result)
                }
                flight = Flight(id: id, key: key, cancellation: sharedCancellation, task: task)
            }
        } onCancel: {
            Task { @MainActor [weak self] in self?.cancelWaiter(request) }
        }
        if cancellation.isCancelled || Task.isCancelled {
            await lease.close()
            throw CancellationError()
        }
        return lease
    }

    private func complete(id: UUID, key: Key, result: Result<HarborWARPTunnel, any Error>) async {
        guard flight?.id == id else {
            if case .success(let tunnel) = result { await tunnel.close() }
            return
        }
        flight = nil
        let pending = waiters
        waiters.removeAll()
        switch result {
        case .success(let tunnel):
            failureCount = 0
            failureKey = nil
            retryAfter = nil
            let granted = pending.filter { !$0.value.cancellation.isCancelled }
            if granted.isEmpty {
                await tunnel.close()
            } else {
                active = Active(key: key, tunnel: tunnel, leases: Set(granted.keys))
            }
            for (id, waiter) in pending {
                if granted[id] != nil {
                    waiter.continuation.resume(returning: Lease(id: id, tunnel: tunnel, pool: self))
                } else {
                    waiter.continuation.resume(throwing: CancellationError())
                }
            }
        case .failure(let error):
            if !(error is CancellationError), !pending.isEmpty {
                failureCount = failureKey == key ? min(failureCount + 1, 5) : 1
                failureKey = key
                retryAfter = .now + .seconds(min(300, 15 * (1 << (failureCount - 1))))
            }
            for waiter in pending.values { waiter.continuation.resume(throwing: error) }
        }
    }

    private func cancelWaiter(_ id: UUID) {
        guard let waiter = waiters.removeValue(forKey: id) else { return }
        waiter.continuation.resume(throwing: CancellationError())
        if waiters.isEmpty { cancelFlight() }
    }

    private func cancelFlight() {
        guard let current = flight else { return }
        flight = nil
        current.cancellation.cancel()
        current.task.cancel()
        let id = current.id
        cleanupTasks[id] = Task { [weak self] in
            await current.task.value
            self?.cleanupTasks.removeValue(forKey: id)
        }
    }

    private func retire(_ tunnel: HarborWARPTunnel) {
        let id = UUID()
        cleanupTasks[id] = Task { [weak self] in
            await tunnel.close()
            self?.cleanupTasks.removeValue(forKey: id)
        }
    }

    fileprivate func release(_ id: UUID) async {
        guard var current = active, current.leases.remove(id) != nil else { return }
        if current.leases.isEmpty {
            active = nil
            await current.tunnel.close()
        } else {
            active = current
        }
    }

    fileprivate func canPromote(_ id: UUID) -> Bool {
        active?.leases == [id] && active?.tunnel.isUsable == true
    }

    fileprivate func promote(_ id: UUID) async -> HarborWARPTunnel.PromotedRuntime? {
        guard canPromote(id), let current = active else { return nil }
        active = nil
        if let runtime = await current.tunnel.promote() { return runtime }
        await current.tunnel.close()
        return nil
    }

    /// Network change invalidates all old evidence immediately. Work that
    /// completes late is disposed by its own flight identity.
    func invalidate() {
        cancelFlight()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending.values { waiter.continuation.resume(throwing: CancellationError()) }
        if let current = active {
            active = nil
            retire(current.tunnel)
        }
        failureKey = nil
        failureCount = 0
        retryAfter = nil
    }

    func shutdown() async {
        invalidate()
        let tasks = Array(cleanupTasks.values)
        for task in tasks { await task.value }
    }
}
