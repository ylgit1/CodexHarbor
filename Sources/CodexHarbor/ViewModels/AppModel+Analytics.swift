import CodexHarborCore
import Foundation

extension AppModel {
    func activitySummary(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?
    ) -> ConnectionActivitySummary {
        return ConnectionActivitySummary.make(
            from: activityEvents,
            connectionKind: connectionKind,
            profileID: profileID
        )
    }

    func codexRequestSummary(for connectionKind: CodexConnectionKind) -> ConnectionActivitySummary {
        ConnectionActivitySummary.make(
            from: activityEvents,
            connectionKind: connectionKind,
            profileID: nil,
            eventKinds: [.codexRequest]
        )
    }

    func codexRequestSummary(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        since: Date? = nil
    ) -> ConnectionActivitySummary {
        let source = since.map { start in
            activityEvents.filter { $0.timestamp >= start }
        } ?? activityEvents
        return ConnectionActivitySummary.make(
            from: source,
            connectionKind: connectionKind,
            profileID: profileID,
            eventKinds: [.codexRequest]
        )
    }

    struct CodexRequestMetrics: Equatable, Sendable {
        let count: Int
        let successfulCount: Int
        let averageDurationMilliseconds: Int?
        let p95DurationMilliseconds: Int?

        var successRate: Double? {
            guard count > 0 else { return nil }
            return Double(successfulCount) / Double(count)
        }
    }

    func codexRequestMetrics(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        since: Date?,
        now: Date = Date()
    ) -> CodexRequestMetrics {
        let events = activityEvents.filter {
            $0.kind == .codexRequest
                && $0.connectionKind == connectionKind
                && (profileID == nil || $0.profileID == profileID)
                && (since == nil || $0.timestamp >= since!)
                && $0.timestamp <= now
        }
        let durations = events.compactMap(\.durationMilliseconds).sorted()
        let p95: Int?
        if durations.isEmpty {
            p95 = nil
        } else {
            let index = min(durations.count - 1, max(0, Int(ceil(Double(durations.count) * 0.95)) - 1))
            p95 = durations[index]
        }
        return CodexRequestMetrics(
            count: events.count,
            successfulCount: events.filter(\.succeeded).count,
            averageDurationMilliseconds: durations.isEmpty ? nil : durations.reduce(0, +) / durations.count,
            p95DurationMilliseconds: p95
        )
    }

    func codexWorkDurationMilliseconds(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        since: Date? = nil,
        until: Date? = nil
    ) -> Int? {
        let durations = activityEvents.compactMap { event -> Int? in
            guard event.kind == .codexRequest,
                  event.connectionKind == connectionKind,
                  (profileID == nil || event.profileID == profileID),
                  (since == nil || event.timestamp >= since!),
                  (until == nil || event.timestamp <= until!) else { return nil }
            return event.durationMilliseconds
        }
        guard !durations.isEmpty else { return nil }
        return durations.reduce(0, +)
    }

    func codexTokenSummary(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        since: Date? = nil,
        until: Date? = nil
    ) -> CodexTokenUsageSummary {
        let events = activityEvents.filter {
            $0.connectionKind == connectionKind
                && (profileID == nil || $0.profileID == profileID)
                && $0.kind == .codexRequest
                && (since == nil || $0.timestamp >= since!)
                && (until == nil || $0.timestamp <= until!)
        }
        let tokenByTurn = Dictionary(uniqueKeysWithValues: codexTokenUsageRecords.map { ($0.id, $0) })
        let matched = events.compactMap { event -> CodexTokenUsageRecord? in
            guard let sourceID = event.sourceID else { return nil }
            return tokenByTurn[sourceID]
        }
        return CodexTokenUsageSummary(
            requestCount: matched.count,
            inputTokens: matched.reduce(0) { $0 + $1.inputTokens },
            cachedInputTokens: matched.reduce(0) { $0 + $1.cachedInputTokens },
            outputTokens: matched.reduce(0) { $0 + $1.outputTokens },
            reasoningOutputTokens: matched.reduce(0) { $0 + $1.reasoningOutputTokens },
            totalTokens: matched.reduce(0) { $0 + $1.totalTokens }
        )
    }

    func codexSuccessHourlyRates(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        since: Date? = nil
    ) -> [Int] {
        requestHourlyBuckets(for: connectionKind, profileID: profileID, now: now, since: since)
            .map { bucket in
                guard !bucket.isEmpty else { return 0 }
                return Int((Double(bucket.filter(\.succeeded).count) / Double(bucket.count) * 100).rounded())
            }
    }

    func codexWorkDurationHourlyTotals(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        since: Date? = nil
    ) -> [Int] {
        requestHourlyBuckets(for: connectionKind, profileID: profileID, now: now, since: since)
            .map { $0.compactMap(\.durationMilliseconds).reduce(0, +) }
    }

    func codexSuccessDailyRates(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        days: Int,
        now: Date = Date()
    ) -> [Int] {
        requestDailyBuckets(for: connectionKind, profileID: profileID, days: days, now: now)
            .map { bucket in
                guard !bucket.isEmpty else { return 0 }
                return Int((Double(bucket.filter(\.succeeded).count) / Double(bucket.count) * 100).rounded())
            }
    }

    func codexWorkDurationDailyTotals(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        days: Int,
        now: Date = Date()
    ) -> [Int] {
        requestDailyBuckets(for: connectionKind, profileID: profileID, days: days, now: now)
            .map { $0.compactMap(\.durationMilliseconds).reduce(0, +) }
    }

    private func requestHourlyBuckets(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date,
        since: Date?
    ) -> [[ConnectionActivityEvent]] {
        let calendar = Calendar.current
        let currentHour = calendar.dateInterval(of: .hour, for: now)?.start ?? now
        let firstHour = since.flatMap { calendar.dateInterval(of: .hour, for: $0)?.start }
            ?? calendar.date(byAdding: .hour, value: -23, to: currentHour)
        guard let firstHour else { return Array(repeating: [], count: 24) }
        var buckets = Array(repeating: [ConnectionActivityEvent](), count: 24)
        for event in activityEvents where
            event.kind == .codexRequest &&
            event.connectionKind == connectionKind &&
            (profileID == nil || event.profileID == profileID) &&
            event.timestamp >= firstHour && event.timestamp <= now {
            let index = calendar.dateComponents([.hour], from: firstHour, to: event.timestamp).hour ?? -1
            if buckets.indices.contains(index) { buckets[index].append(event) }
        }
        return buckets
    }

    private func requestDailyBuckets(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        days: Int,
        now: Date
    ) -> [[ConnectionActivityEvent]] {
        let calendar = Calendar.current
        let count = max(days, 1)
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: today) else {
            return Array(repeating: [], count: count)
        }
        var buckets = Array(repeating: [ConnectionActivityEvent](), count: count)
        for event in activityEvents where
            event.kind == .codexRequest &&
            event.connectionKind == connectionKind &&
            (profileID == nil || event.profileID == profileID) &&
            event.timestamp >= firstDay && event.timestamp <= now {
            let index = calendar.dateComponents([.day], from: firstDay, to: event.timestamp).day ?? -1
            if buckets.indices.contains(index) { buckets[index].append(event) }
        }
        return buckets
    }

    func codexRequestHourlyCounts(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        since: Date? = nil
    ) -> [Int] {
        requestHourlyBuckets(
            for: connectionKind,
            profileID: profileID,
            now: now,
            since: since
        ).map(\.count)
    }

    /// Average Codex request duration for each of the last 24 clock hours.
    /// The profile is optional on purpose: detail charts are mode-level views,
    /// so switching between profiles does not make the chart appear to reset.
    func codexResponseHourlyAverages(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        since: Date? = nil
    ) -> [Int] {
        requestHourlyBuckets(
            for: connectionKind,
            profileID: profileID,
            now: now,
            since: since
        ).map(Self.averageDuration)
    }

    func codexRequestDailyCounts(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        days: Int,
        now: Date = Date()
    ) -> [Int] {
        requestDailyBuckets(
            for: connectionKind,
            profileID: profileID,
            days: days,
            now: now
        ).map(\.count)
    }

    func codexResponseDailyAverages(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        days: Int,
        now: Date = Date()
    ) -> [Int] {
        requestDailyBuckets(
            for: connectionKind,
            profileID: profileID,
            days: days,
            now: now
        ).map(Self.averageDuration)
    }

    /// Average Codex request duration for each of the last seven calendar days.
    func codexResponseDailyAverages(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date()
    ) -> [Int] {
        codexResponseDailyAverages(
            for: connectionKind,
            profileID: profileID,
            days: 7,
            now: now
        )
    }

    func codexTokenHourlyCounts(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        since: Date? = nil
    ) -> [Int] {
        let tokenByID = Dictionary(uniqueKeysWithValues: codexTokenUsageRecords.map { ($0.id, $0) })
        return requestHourlyBuckets(
            for: connectionKind,
            profileID: profileID,
            now: now,
            since: since
        ).map { bucket in
            bucket.reduce(0) { total, event in
                guard let sourceID = event.sourceID, let record = tokenByID[sourceID] else { return total }
                return total + record.totalTokens
            }
        }
    }

    func codexTokenDailyCounts(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date()
    ) -> [Int] {
        codexTokenDailyCounts(
            for: connectionKind,
            profileID: profileID,
            days: 7,
            now: now
        )
    }

    func codexTokenDailyCounts(
        for connectionKind: CodexConnectionKind,
        profileID: UUID?,
        days: Int,
        now: Date = Date()
    ) -> [Int] {
        let tokenByID = Dictionary(uniqueKeysWithValues: codexTokenUsageRecords.map { ($0.id, $0) })
        return requestDailyBuckets(
            for: connectionKind,
            profileID: profileID,
            days: days,
            now: now
        ).map { bucket in
            bucket.reduce(0) { total, event in
                guard let sourceID = event.sourceID, let record = tokenByID[sourceID] else { return total }
                return total + record.totalTokens
            }
        }
    }
    private nonisolated static func averageDuration(_ events: [ConnectionActivityEvent]) -> Int {
        let durations = events.compactMap(\.durationMilliseconds)
        guard !durations.isEmpty else { return 0 }
        return durations.reduce(0, +) / durations.count
    }

}
