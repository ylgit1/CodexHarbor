import Foundation

/// Codex account rate limits, independent of tokens and request totals.
/// Values are percentages of the current time window, not lifetime plan balances.
public struct CodexQuotaWindow: Codable, Equatable, Sendable {
    public let durationMinutes: Int
    public let usedPercent: Double
    public let resetDate: Date?

    public var remainingPercent: Double {
        max(0, min(100, 100 - usedPercent))
    }

    public init(durationMinutes: Int, usedPercent: Double, resetDate: Date?) {
        self.durationMinutes = durationMinutes
        self.usedPercent = max(0, min(100, usedPercent))
        self.resetDate = resetDate
    }
}

public struct CodexQuotaSnapshot: Codable, Equatable, Sendable {
    public let fiveHours: CodexQuotaWindow?
    public let weekly: CodexQuotaWindow?
    public let capturedAt: Date
    public let planType: String?
    public let resetCreditsAvailable: Int?
    public let resetCreditsExpiry: Date?

    public init(
        fiveHours: CodexQuotaWindow?,
        weekly: CodexQuotaWindow?,
        capturedAt: Date = Date(),
        planType: String? = nil,
        resetCreditsAvailable: Int? = nil,
        resetCreditsExpiry: Date? = nil
    ) {
        self.fiveHours = fiveHours
        self.weekly = weekly
        self.capturedAt = capturedAt
        self.planType = planType
        self.resetCreditsAvailable = resetCreditsAvailable
        self.resetCreditsExpiry = resetCreditsExpiry
    }

    public static func parse(data: Data, capturedAt: Date = Date()) -> CodexQuotaSnapshot? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        return parse(root, capturedAt: capturedAt)
    }

    public static func parse(_ root: [String: Any], capturedAt: Date = Date()) -> CodexQuotaSnapshot? {
        let envelope = (root["result"] as? [String: Any]) ?? root
        // A keyed "codex" snapshot has priority: other limit IDs (e.g. Spark)
        // are not equivalent to the Codex 5-hour / weekly subscription limits.
        let keyed = envelope["rateLimitsByLimitId"] as? [String: Any]
        let record: [String: Any]?
        if let codex = keyed?["codex"] as? [String: Any] {
            record = codex
        } else if let simple = envelope["rateLimits"] as? [String: Any] {
            let limitID = simple["limitId"] as? String
            record = limitID == nil || limitID == "codex" ? simple : nil
        } else if keyed == nil {
            record = envelope
        } else {
            record = nil
        }
        guard let record else { return nil }

        let candidates = ["primary", "secondary"]
            .compactMap { record[$0] as? [String: Any] }
            .compactMap { item -> CodexQuotaWindow? in
                guard let duration = (item["windowDurationMins"] as? NSNumber)?.intValue,
                      let used = (item["usedPercent"] as? NSNumber)?.doubleValue,
                      duration > 0, used.isFinite, used >= 0, used <= 100 else { return nil }
                let timestamp = (item["resetsAt"] as? NSNumber)?.doubleValue
                let reset = timestamp.flatMap { $0 > 0 && $0.isFinite ? Date(timeIntervalSince1970: $0) : nil }
                return CodexQuotaWindow(durationMinutes: duration, usedPercent: used, resetDate: reset)
            }

        let five = candidates.first { $0.durationMinutes == 300 }
        let weekly = candidates.first { $0.durationMinutes >= 10_080 && $0.durationMinutes % 10_080 == 0 }
        guard five != nil || weekly != nil else { return nil }
        let plan = (record["planType"] as? String) ?? (envelope["planType"] as? String)
        // These credits are optional; don't mistake missing metadata for zero.
        let credits = envelope["rateLimitResetCredits"] as? [String: Any]
        let availableItems = (credits?["credits"] as? [[String: Any]])?.filter {
            ($0["status"] as? String) == "available" &&
            ($0["resetType"] as? String) == "codexRateLimits"
        }
        let count = (credits?["availableCount"] as? NSNumber)?.intValue ??
            availableItems?.count
        let expiry = availableItems?
            .compactMap { ($0["expiresAt"] as? NSNumber)?.doubleValue }
            .filter { $0.isFinite && $0 > 0 }
            .min()
            .map { Date(timeIntervalSince1970: $0) }
        return CodexQuotaSnapshot(
            fiveHours: five, weekly: weekly, capturedAt: capturedAt,
            planType: plan, resetCreditsAvailable: count, resetCreditsExpiry: expiry
        )
    }
}
