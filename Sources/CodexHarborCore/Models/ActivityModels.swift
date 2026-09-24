import Foundation

public enum ConnectionActivityKind: String, Codable, Sendable {
    case codexRequest
    case healthCheck
    case usageQuery
    case connectionSwitch
    case profileCreate
    case modelRefresh
    case codexReload

    public var title: String {
        switch self {
        case .codexRequest: "Codex 请求"
        case .healthCheck: "状态检查"
        case .usageQuery: "用量查询"
        case .connectionSwitch: "连接切换"
        case .profileCreate: "新增档案"
        case .modelRefresh: "模型更新"
        case .codexReload: "重载 Codex"
        }
    }
}

public struct ConnectionActivityEvent: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public let timestamp: Date
    public let connectionKind: CodexConnectionKind
    public let profileID: UUID?
    public let kind: ConnectionActivityKind
    public let succeeded: Bool
    public let durationMilliseconds: Int?
    public let sourceID: String?

    public init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        connectionKind: CodexConnectionKind,
        profileID: UUID?,
        kind: ConnectionActivityKind,
        succeeded: Bool,
        durationMilliseconds: Int? = nil,
        sourceID: String? = nil
    ) {
        self.id = id
        self.timestamp = timestamp
        self.connectionKind = connectionKind
        self.profileID = profileID
        self.kind = kind
        self.succeeded = succeeded
        self.durationMilliseconds = durationMilliseconds
        self.sourceID = sourceID
    }
}

public struct ConnectionActivityDay: Equatable, Sendable {
    public let date: Date
    public let count: Int

    public init(date: Date, count: Int) {
        self.date = date
        self.count = count
    }
}

public struct CodexTokenUsageSummary: Equatable, Sendable {
    public let requestCount: Int
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int
    public let totalTokens: Int

    public init(
        requestCount: Int = 0,
        inputTokens: Int = 0,
        cachedInputTokens: Int = 0,
        outputTokens: Int = 0,
        reasoningOutputTokens: Int = 0,
        totalTokens: Int = 0
    ) {
        self.requestCount = requestCount
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
        self.totalTokens = totalTokens
    }
}

public struct ConnectionActivitySummary: Equatable, Sendable {
    public let eventsLast24Hours: Int
    public let eventsLast7Days: Int
    public let successfulEventsLast7Days: Int
    public let failedEventsLast7Days: Int
    public let averageDurationMilliseconds: Int?
    public let p95DurationMilliseconds: Int?
    public let lastObservedAt: Date?
    public let dailyCounts: [ConnectionActivityDay]

    public var successRate: Double? {
        guard eventsLast7Days > 0 else { return nil }
        return Double(successfulEventsLast7Days) / Double(eventsLast7Days)
    }

    public init(
        eventsLast24Hours: Int,
        eventsLast7Days: Int,
        successfulEventsLast7Days: Int,
        failedEventsLast7Days: Int,
        averageDurationMilliseconds: Int?,
        p95DurationMilliseconds: Int?,
        lastObservedAt: Date?,
        dailyCounts: [ConnectionActivityDay]
    ) {
        self.eventsLast24Hours = eventsLast24Hours
        self.eventsLast7Days = eventsLast7Days
        self.successfulEventsLast7Days = successfulEventsLast7Days
        self.failedEventsLast7Days = failedEventsLast7Days
        self.averageDurationMilliseconds = averageDurationMilliseconds
        self.p95DurationMilliseconds = p95DurationMilliseconds
        self.lastObservedAt = lastObservedAt
        self.dailyCounts = dailyCounts
    }

    public static func empty(now: Date = Date(), calendar: Calendar = .current) -> ConnectionActivitySummary {
        ConnectionActivitySummary(
            eventsLast24Hours: 0,
            eventsLast7Days: 0,
            successfulEventsLast7Days: 0,
            failedEventsLast7Days: 0,
            averageDurationMilliseconds: nil,
            p95DurationMilliseconds: nil,
            lastObservedAt: nil,
            dailyCounts: Self.emptyDays(now: now, calendar: calendar)
        )
    }

    public static func make(
        from events: [ConnectionActivityEvent],
        connectionKind: CodexConnectionKind,
        profileID: UUID?,
        now: Date = Date(),
        calendar: Calendar = .current,
        eventKinds: Set<ConnectionActivityKind>? = nil
    ) -> ConnectionActivitySummary {
        let dayStarts = emptyDays(now: now, calendar: calendar).map(\.date)
        guard let oldestDay = dayStarts.first else { return .empty(now: now, calendar: calendar) }
        let twentyFourHoursAgo = now.addingTimeInterval(-24 * 60 * 60)
        let relevantEvents = events.filter {
            $0.connectionKind == connectionKind
                && (profileID == nil || $0.profileID == profileID)
                && (eventKinds == nil || eventKinds?.contains($0.kind) == true)
                && $0.timestamp >= oldestDay
                && $0.timestamp <= now
        }
        let durations = relevantEvents.compactMap(\.durationMilliseconds).sorted()
        let averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
        let p95Duration: Int?
        if durations.isEmpty {
            p95Duration = nil
        } else {
            let index = min(durations.count - 1, max(0, Int(ceil(Double(durations.count) * 0.95)) - 1))
            p95Duration = durations[index]
        }
        let countsByDay = Dictionary(grouping: relevantEvents) { event in
            calendar.startOfDay(for: event.timestamp)
        }.mapValues(\.count)
        let dailyCounts = dayStarts.map { dayStart in
            ConnectionActivityDay(date: dayStart, count: countsByDay[dayStart] ?? 0)
        }

        return ConnectionActivitySummary(
            eventsLast24Hours: relevantEvents.filter { $0.timestamp >= twentyFourHoursAgo }.count,
            eventsLast7Days: relevantEvents.count,
            successfulEventsLast7Days: relevantEvents.filter(\.succeeded).count,
            failedEventsLast7Days: relevantEvents.filter { !$0.succeeded }.count,
            averageDurationMilliseconds: averageDuration,
            p95DurationMilliseconds: p95Duration,
            lastObservedAt: relevantEvents.map(\.timestamp).max(),
            dailyCounts: dailyCounts
        )
    }

    private static func emptyDays(now: Date, calendar: Calendar) -> [ConnectionActivityDay] {
        let today = calendar.startOfDay(for: now)
        return (0..<7).reversed().compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: -offset, to: today) else { return nil }
            return ConnectionActivityDay(date: date, count: 0)
        }
    }
}
