import Foundation

/// Single isolation domain for connection requests and transaction fencing.
/// MainActor is intentional: the UI and system-proxy commit checks must
/// observe an intent change synchronously, without another actor hop.
@MainActor
public final class HarborConnectionCoordinator {
    public struct Request: Sendable, Equatable {
        public let nodeID: String
        public let restart: Bool
        public let userInitiated: Bool
        fileprivate let generation: UInt64
    }

    private var fence = HarborConnectionTransactionFence()
    private var pending: Request?
    private var claimed: Request?
    private var requestGeneration: UInt64 = 0
    public private(set) var stopping = false

    public init() {}

    public var networkEpoch: UInt64 { fence.networkEpoch }
    public var current: HarborConnectionTransactionFence.Transaction? { fence.current }
    public var hasPending: Bool { pending != nil }

    @discardableResult
    public func enqueue(_ nodeID: String, restart: Bool, userInitiated: Bool) -> Bool {
        guard !stopping else { return false }
        // Recovery cannot replace a waiting explicit user action.
        if !userInitiated && (pending?.userInitiated == true || claimed?.userInitiated == true || current?.source == .user) {
            return false
        }
        requestGeneration &+= 1
        pending = Request(nodeID: nodeID, restart: restart, userInitiated: userInitiated,
                          generation: requestGeneration)
        fence.invalidate()
        return true
    }

    public func takeNext() -> Request? {
        guard !stopping else { return nil }
        guard let next = pending else { return nil }
        claimed = next
        pending = nil
        return next
    }

    public func accepts(_ request: Request) -> Bool {
        !stopping && claimed == request && request.generation == requestGeneration
    }

    public func finishRequest(_ request: Request) {
        if claimed == request { claimed = nil }
    }

    public func begin(nodeID: String, endpointSignature: String, timeout: Duration,
                      source: HarborConnectionTransactionFence.Source) -> HarborConnectionTransactionFence.Transaction? {
        guard !stopping, pending == nil, fence.current == nil,
              claimed == nil || (claimed?.nodeID == nodeID && claimed?.generation == requestGeneration && (claimed?.userInitiated != true || source == .user))
        else { return nil }
        return fence.begin(nodeID: nodeID, endpointSignature: endpointSignature, timeout: timeout, source: source)
    }

    public func accepts(_ transaction: HarborConnectionTransactionFence.Transaction,
                        endpointSignature: String?) -> Bool {
        !stopping && pending == nil && fence.accepts(transaction, endpointSignature: endpointSignature)
    }

    public func finish(_ transaction: HarborConnectionTransactionFence.Transaction) {
        fence.finish(transaction)
    }

    public func networkChanged() {
        requestGeneration &+= 1
        pending = nil
        claimed = nil
        fence.networkChanged()
    }

    public func beginStop() {
        stopping = true
        requestGeneration &+= 1
        pending = nil
        claimed = nil
        fence.invalidate()
    }

    public func endStop() { stopping = false }
}
