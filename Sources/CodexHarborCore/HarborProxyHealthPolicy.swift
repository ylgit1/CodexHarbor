import Foundation

public enum HarborConnectionPhase: String, Codable, Equatable, Sendable {
    case stopped, preparing, validating, connected, switching, degraded
    case recovering, offline, stopping, failed
}

/// Recovery decisions are independent of UI selection and system proxy
/// ownership. The caller owns all scheduled work and its cancellation fence.
public struct HarborProxyHealthPolicy: Sendable {
    public static let healthInterval: TimeInterval = 120
    public static let livenessInterval: Int = 10
    public static let failureThreshold = 3
    public static let recoveryLimit = 2
    public static let retryDelays = [3, 5, 10]
    public static let cooldownSeconds = 60
    public static let maximumBackoffSeconds = 300

    public enum Action: Equatable, Sendable {
        case recheck(afterSeconds: Int)
        case recover(afterSeconds: Int)
        case cooldown(afterSeconds: Int)
        case none
    }

    public private(set) var failures = 0
    public private(set) var recoveryAttempts = 0
    public private(set) var cooldownLevel = 0
    public private(set) var online = true

    public init() {}

    public mutating func recordHealthy() {
        failures = 0
        recoveryAttempts = 0
        cooldownLevel = 0
    }

    public mutating func networkChanged(online: Bool) {
        self.online = online
        // Evidence and the retry budget belong to the old network.
        recordHealthy()
    }

    public mutating func recordFailure(engineUnavailable: Bool = false) -> Action {
        guard online else { return .none }
        failures = min(Self.failureThreshold, failures + 1)
        if engineUnavailable { failures = Self.failureThreshold }
        if failures < Self.failureThreshold {
            return .recheck(afterSeconds: Self.retryDelays[failures - 1])
        }
        return .recover(afterSeconds: engineUnavailable ? 0 : Self.retryDelays[2])
    }

    /// Call immediately before starting a recovery transaction. Never consume
    /// attempts while offline or while another user transaction has priority.
    public mutating func beginRecovery() -> Bool {
        guard online, recoveryAttempts < Self.recoveryLimit else { return false }
        recoveryAttempts += 1
        return true
    }

    public mutating func recoveryFailed() -> Action {
        guard online else { return .none }
        if recoveryAttempts < Self.recoveryLimit {
            return .recover(afterSeconds: Self.retryDelays[1])
        }
        let multiplier = 1 << min(cooldownLevel, 3)
        let seconds = min(Self.maximumBackoffSeconds, Self.cooldownSeconds * multiplier)
        cooldownLevel = min(3, cooldownLevel + 1)
        return .cooldown(afterSeconds: seconds)
    }

    public mutating func cooldownElapsed() {
        recoveryAttempts = 0
    }
}
