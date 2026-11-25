import Foundation

/// A bounded cooldown for formal candidates, separate from the temporary
/// screening tunnel's failure cache. Neither a different network epoch nor
/// a changed node configuration can inherit negative discovery evidence.
public struct HarborWARPFormalDiscoveryPolicy: Sendable {
    public struct Key: Hashable, Sendable {
        public let accountID: String
        public let nodeID: String
        public let endpointSignature: String
        public let networkEpoch: UInt64

        public init(accountID: String, nodeID: String, endpointSignature: String, networkEpoch: UInt64) {
            self.accountID = accountID
            self.nodeID = nodeID
            self.endpointSignature = endpointSignature
            self.networkEpoch = networkEpoch
        }
    }

    private struct Failure: Sendable {
        let count: Int
        let nextAttempt: ContinuousClock.Instant
    }

    private var failures: [Key: Failure] = [:]
    private let capacity = 32

    public init() {}

    public func canAttempt(_ key: Key, now: ContinuousClock.Instant = .now) -> Bool {
        failures[key].map { now >= $0.nextAttempt } ?? true
    }

    public mutating func recordSuccess(_ key: Key) {
        failures.removeValue(forKey: key)
    }

    public mutating func recordFailure(_ key: Key, now: ContinuousClock.Instant = .now) {
        failures = failures.filter { $0.key.networkEpoch == key.networkEpoch }
        let count = min(6, (failures[key]?.count ?? 0) + 1)
        if failures[key] == nil && failures.count >= capacity,
           let oldest = failures.min(by: { $0.value.nextAttempt < $1.value.nextAttempt })?.key {
            failures.removeValue(forKey: oldest)
        }
        failures[key] = Failure(count: count, nextAttempt: now + .seconds(min(300, 15 * (1 << (count - 1)))))
    }

    public mutating func invalidate() { failures.removeAll(keepingCapacity: true) }
}
