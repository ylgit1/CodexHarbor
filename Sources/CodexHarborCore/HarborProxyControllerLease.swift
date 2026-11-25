import Foundation

/// A connected XPC peer may have a stuck main thread. Only recent activity
/// grants it control of automatic recovery.
public struct HarborProxyControllerLease: Sendable {
    public static let heartbeatInterval: Duration = .seconds(5)
    private let expiry: Duration
    private var deadlines: [UUID: ContinuousClock.Instant] = [:]

    public init(expiry: Duration = .seconds(20)) { self.expiry = expiry }

    /// Returns true when ownership is newly acquired or reacquired.
    @discardableResult
    public mutating func renew(_ session: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        let renewed = !isLive(session, now: now)
        deadlines = deadlines.filter { $0.value > now }
        deadlines[session] = now + expiry
        return renewed
    }

    public mutating func disconnect(_ session: UUID) { deadlines.removeValue(forKey: session) }

    public func isLive(_ session: UUID, now: ContinuousClock.Instant = .now) -> Bool {
        deadlines[session].map { $0 > now } == true
    }

    public func liveCount(now: ContinuousClock.Instant = .now) -> Int {
        deadlines.values.count { $0 > now }
    }
}
