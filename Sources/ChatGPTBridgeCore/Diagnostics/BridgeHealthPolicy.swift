import Foundation

/// Runtime health policy. Keeps background work cheap and reserves protocol checks for demand-driven diagnostics.
public enum BridgeHealthPolicy {
    public static let runtimeHeartbeatInterval: TimeInterval = 5
    public static let normalHealthInterval: TimeInterval = 300
    public static let recoveryHealthInterval: TimeInterval = 10
    public static let remoteHealthInterval = normalHealthInterval
    public static let controlPlaneFreshnessInterval: TimeInterval = 75
    public static let deepDiagnosticsEnabledByDefault = false

    private static let tunnelSelfHealDelays: [TimeInterval] = [90, 180, 300, 600]

    public static func healthInterval(for diagnostics: BridgePipelineDiagnostics) -> TimeInterval {
        diagnostics.requiresFastRecoveryCheck ? recoveryHealthInterval : normalHealthInterval
    }

    public static func shouldRunRemoteHealth(
        lastCheck: Date?,
        diagnostics: BridgePipelineDiagnostics = BridgePipelineDiagnostics(),
        now: Date = Date()
    ) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= healthInterval(for: diagnostics)
    }

    public static func shouldRunHeartbeat(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        return now.timeIntervalSince(lastCheck) >= runtimeHeartbeatInterval
    }

    public static func isTerminalAuthenticationFailure(_ message: String) -> Bool {
        let normalized = message.lowercased()
        return normalized.contains("key 已失效")
            || normalized.contains("runtime api key") && normalized.contains("没有")
            || normalized.contains("鉴权失败")
            || normalized.contains("拒绝访问")
            || normalized.contains("unauthorized")
            || normalized.contains("forbidden")
            || normalized.contains("401")
            || normalized.contains("403")
    }

    public static func tunnelSelfHealDelay(for attempt: Int) -> TimeInterval {
        let index = min(max(attempt, 0), tunnelSelfHealDelays.count - 1)
        return tunnelSelfHealDelays[index]
    }

    public static func shouldRestartTunnel(
        notReadySince: Date?,
        attempt: Int,
        recoverable: Bool,
        now: Date = Date()
    ) -> Bool {
        guard recoverable, let notReadySince else { return false }
        return now.timeIntervalSince(notReadySince) >= tunnelSelfHealDelay(for: attempt)
    }
}
