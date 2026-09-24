import CodexHarborCore
import CryptoKit
import Foundation

struct CodexTelemetryConnectionSnapshot: Equatable, Sendable {
    let kind: CodexConnectionKind
    let profileID: UUID?
}

struct CodexTelemetryUpdate: Sendable {
    let tokenUsageRecords: [CodexTokenUsageRecord]
    let activityEvents: [ConnectionActivityEvent]
    let authenticationChanged: Bool
}

actor CodexTelemetryCoordinator {
    private let paths: CodexPaths
    private let requestMonitor: CodexRequestMonitor
    private let tokenUsageMonitor: CodexTokenUsageMonitor
    private let relayActivityStore: RelayActivityStore
    private let stateStore: CodexRequestMonitorStateStore

    private var observedAuthenticationDigest: String?
    private var observedTurnIDs: Set<String>
    private var activeTurnSnapshots: [String: CodexTelemetryConnectionSnapshot] = [:]
    private var relayCursor: Int64 = 0
    private var relaySeeded = false
    private var relayTokenRecordsByID: [String: CodexTokenUsageRecord] = [:]
    private let startedAt: Date

    init(
        paths: CodexPaths = .live(),
        requestMonitor: CodexRequestMonitor? = nil,
        tokenUsageMonitor: CodexTokenUsageMonitor? = nil,
        relayActivityStore: RelayActivityStore? = nil,
        stateStore: CodexRequestMonitorStateStore? = nil,
        startedAt: Date = Date()
    ) {
        self.paths = paths
        self.requestMonitor = requestMonitor ?? CodexRequestMonitor(paths: paths)
        self.tokenUsageMonitor = tokenUsageMonitor ?? CodexTokenUsageMonitor(paths: paths)
        self.relayActivityStore = relayActivityStore ?? RelayActivityStore(paths: paths)
        self.stateStore = stateStore ?? CodexRequestMonitorStateStore(url: paths.requestMonitorStateURL)
        self.startedAt = startedAt
        self.observedAuthenticationDigest = Self.authenticationDigest(at: paths.authURL)
        self.observedTurnIDs = (stateStore ?? CodexRequestMonitorStateStore(url: paths.requestMonitorStateURL)).load()
    }

    var shouldSeedRequests: Bool {
        observedTurnIDs.isEmpty
    }

    func markAuthenticationCurrent() {
        observedAuthenticationDigest = Self.authenticationDigest(at: paths.authURL)
    }

    func poll(
        connection: CodexTelemetryConnectionSnapshot?,
        existingActivitySourceIDs: Set<String>,
        seedRequests: Bool
    ) async -> CodexTelemetryUpdate {
        let originalObservedTurnIDs = observedTurnIDs
        let authenticationChanged = detectAuthenticationChange()
        let codexTokenRecords = await tokenUsageMonitor.recentUsage()

        // Relay history is capped at 5,000 records. Seed that complete retained
        // baseline in one read after App launch, then switch to small cursor
        // reads so the dashboard does not refill historical usage over several
        // 10-second polling cycles.
        let relayLimit = relaySeeded ? 1_000 : 5_000
        let relayBatch: RelayActivityBatch
        if let loaded = try? relayActivityStore.load(afterRowID: relayCursor, limit: relayLimit) {
            relayBatch = loaded
            relayCursor = loaded.nextCursor
            relaySeeded = true
        } else {
            relayBatch = RelayActivityBatch(records: [], nextCursor: relayCursor)
        }

        var sourceIDs = existingActivitySourceIDs
        var newEvents: [ConnectionActivityEvent] = []

        for record in relayBatch.records {
            if !sourceIDs.contains(record.id) {
                newEvents.append(ConnectionActivityEvent(
                    timestamp: record.startedAt,
                    connectionKind: .apiKey,
                    profileID: record.profileID,
                    kind: .codexRequest,
                    succeeded: record.succeeded,
                    durationMilliseconds: record.durationMilliseconds,
                    sourceID: record.id
                ))
                sourceIDs.insert(record.id)
            }

            guard record.usage.source != .unavailable else { continue }
            relayTokenRecordsByID[record.id] = CodexTokenUsageRecord(
                id: record.id,
                timestamp: record.startedAt,
                inputTokens: record.usage.inputTokens,
                cachedInputTokens: record.usage.cachedInputTokens,
                outputTokens: record.usage.outputTokens,
                reasoningOutputTokens: record.usage.reasoningOutputTokens,
                totalTokens: record.usage.totalTokens
            )
        }

        let relayCutoff = Date().addingTimeInterval(-30 * 24 * 60 * 60)
        let retainedRelayTokens = relayTokenRecordsByID.values
            .filter { $0.timestamp >= relayCutoff }
            .sorted { $0.timestamp < $1.timestamp }
            .suffix(5_000)
        relayTokenRecordsByID = Dictionary(
            uniqueKeysWithValues: retainedRelayTokens.map { ($0.id, $0) }
        )

        if let connection, connection.kind != .apiKey {
            for record in codexTokenRecords where
                record.timestamp >= startedAt &&
                !sourceIDs.contains(record.id) &&
                !observedTurnIDs.contains(record.id) {
                observedTurnIDs.insert(record.id)
                sourceIDs.insert(record.id)
                newEvents.append(ConnectionActivityEvent(
                    timestamp: record.timestamp,
                    connectionKind: connection.kind,
                    profileID: connection.profileID,
                    kind: .codexRequest,
                    succeeded: true,
                    durationMilliseconds: nil,
                    sourceID: record.id
                ))
            }
        }

        let turnRecords = await recentTurns()
        if seedRequests {
            let terminalIDs = turnRecords.filter(\.isTerminal).map(\.id)
            observedTurnIDs.formUnion(terminalIDs)
            for record in turnRecords where !record.isTerminal {
                observedTurnIDs.remove(record.id)
            }
        } else {
            if let connection {
                for record in turnRecords where !record.isTerminal {
                    if activeTurnSnapshots[record.id] == nil {
                        activeTurnSnapshots[record.id] = connection
                    }
                    observedTurnIDs.remove(record.id)
                }
            }

            for record in turnRecords.reversed() where record.isTerminal {
                guard !observedTurnIDs.contains(record.id) else { continue }
                observedTurnIDs.insert(record.id)
                let snapshot = activeTurnSnapshots.removeValue(forKey: record.id) ?? connection
                guard let snapshot, snapshot.kind != .apiKey else { continue }

                let startedAt = record.startedAt ?? record.completedAt ?? Date()
                sourceIDs.insert(record.id)
                newEvents.append(ConnectionActivityEvent(
                    timestamp: startedAt,
                    connectionKind: snapshot.kind,
                    profileID: snapshot.profileID,
                    kind: .codexRequest,
                    succeeded: record.status == "completed",
                    durationMilliseconds: record.durationMilliseconds,
                    sourceID: record.id
                ))
            }
        }

        if observedTurnIDs != originalObservedTurnIDs {
            stateStore.save(observedTurnIDs)
        }

        let mergedTokenRecords = Dictionary(
            (codexTokenRecords + Array(relayTokenRecordsByID.values)).map { ($0.id, $0) },
            uniquingKeysWith: { _, newest in newest }
        ).values.sorted { $0.timestamp < $1.timestamp }

        return CodexTelemetryUpdate(
            tokenUsageRecords: mergedTokenRecords,
            activityEvents: newEvents,
            authenticationChanged: authenticationChanged
        )
    }

    private func recentTurns() async -> [CodexTurnRecord] {
        let monitor = requestMonitor
        return (try? await Task.detached(priority: .utility) {
            try monitor.recentTurns()
        }.value) ?? []
    }

    private func detectAuthenticationChange() -> Bool {
        let latest = Self.authenticationDigest(at: paths.authURL)
        guard latest != observedAuthenticationDigest else { return false }
        observedAuthenticationDigest = latest
        return latest != nil
    }

    private nonisolated static func authenticationDigest(at url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
