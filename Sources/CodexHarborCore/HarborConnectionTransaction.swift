import Foundation

/// Monotonic transaction fence. The owner must serialize access (the current
/// runtime manager is MainActor-isolated), so checking and advancing a token
/// does not introduce another suspension point.
public struct HarborConnectionTransactionFence: Sendable {
    public enum Source: String, Sendable, Codable { case user, recovery, startup, reconfiguration }

    public struct Transaction: Sendable, Equatable {
        public let id: UUID
        public let generation: UInt64
        public let nodeID: String
        public let endpointSignature: String
        public let networkEpoch: UInt64
        public let source: Source
        public let startedAt: ContinuousClock.Instant
        public let deadline: ContinuousClock.Instant
    }

    private var generation: UInt64 = 0
    public private(set) var networkEpoch: UInt64 = 0
    public private(set) var current: Transaction?
    public init() {}

    public mutating func begin(nodeID: String, endpointSignature: String,
                               timeout: Duration, source: Source = .user) -> Transaction {
        generation &+= 1
        let now = ContinuousClock.now
        let transaction = Transaction(id: UUID(), generation: generation,
                                      nodeID: nodeID, endpointSignature: endpointSignature,
                                      networkEpoch: networkEpoch, source: source,
                                      startedAt: now, deadline: now + timeout)
        current = transaction
        return transaction
    }

    public func accepts(_ transaction: Transaction, endpointSignature: String?,
                        now: ContinuousClock.Instant = .now) -> Bool {
        current == transaction && networkEpoch == transaction.networkEpoch
            && endpointSignature == transaction.endpointSignature && now < transaction.deadline
    }

    public mutating func invalidate() {
        generation &+= 1
        current = nil
    }

    public mutating func networkChanged() {
        networkEpoch &+= 1
        invalidate()
    }

    public mutating func finish(_ transaction: Transaction) {
        guard current == transaction else { return }
        current = nil
    }
}
