import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Relay activity SQLite store")
struct RelayActivityStoreTests {
    @Test("legacy JSON migrates once into SQLite and preserves records")
    func migratesLegacyJSON() throws {
        let fixture = try RelayStoreFixture()
        defer { fixture.cleanup() }

        let legacy = fixture.record(id: "legacy", billedTokens: 7)
        let data = try JSONEncoder().encode([legacy])
        try data.write(to: fixture.paths.relayEventsURL, options: .atomic)

        let records = try fixture.store.load()
        let migrated = try #require(records.first)
        #expect(records.count == 1)
        #expect(migrated.id == legacy.id)
        #expect(migrated.profileID == legacy.profileID)
        #expect(abs(migrated.startedAt.timeIntervalSince(legacy.startedAt)) < 0.001)
        #expect(abs(migrated.completedAt.timeIntervalSince(legacy.completedAt)) < 0.001)
        #expect(migrated.usage == legacy.usage)
        #expect(FileManager.default.fileExists(atPath: fixture.paths.relayEventsDatabaseURL.path))
        #expect(FileManager.default.fileExists(atPath: fixture.paths.relayEventsURL.path) == false)
        #expect(try fixture.store.billedTokenTotal() == 7)
    }

    @Test("append is an upsert and billed token aggregation stays profile scoped")
    func upsertAndAggregate() throws {
        let fixture = try RelayStoreFixture()
        defer { fixture.cleanup() }

        let first = fixture.record(id: "same", billedTokens: 10)
        try fixture.store.append(first, now: first.startedAt)

        let replacement = fixture.record(
            id: "same",
            profileID: first.profileID,
            startedAt: first.startedAt.addingTimeInterval(1),
            billedTokens: 25
        )
        try fixture.store.append(replacement, now: replacement.startedAt)

        let otherProfile = UUID()
        let other = fixture.record(
            id: "other",
            profileID: otherProfile,
            startedAt: replacement.startedAt,
            billedTokens: 5
        )
        try fixture.store.append(other, now: other.startedAt)

        let records = try fixture.store.load()
        #expect(records.count == 2)
        #expect(records.first(where: { $0.id == "same" })?.usage.billedTokens == 25)
        #expect(try fixture.store.billedTokenTotal(profileID: first.profileID) == 25)
        #expect(try fixture.store.billedTokenTotal(profileID: otherProfile) == 5)
        #expect(try fixture.store.billedTokenTotal() == 30)
    }

    @Test("incremental cursor reads only newly appended records")
    func incrementalCursor() throws {
        let fixture = try RelayStoreFixture()
        defer { fixture.cleanup() }

        let first = fixture.record(id: "first", billedTokens: 1)
        try fixture.store.append(first, now: first.startedAt)

        let initial = try fixture.store.load(afterRowID: 0)
        #expect(initial.records.map(\.id) == ["first"])
        #expect(initial.nextCursor > 0)

        let empty = try fixture.store.load(afterRowID: initial.nextCursor)
        #expect(empty.records.isEmpty)
        #expect(empty.nextCursor == initial.nextCursor)

        let second = fixture.record(
            id: "second",
            startedAt: first.startedAt.addingTimeInterval(1),
            billedTokens: 2
        )
        try fixture.store.append(second, now: second.startedAt)

        let incremental = try fixture.store.load(afterRowID: initial.nextCursor)
        #expect(incremental.records.map(\.id) == ["second"])
        #expect(incremental.nextCursor > initial.nextCursor)
    }

    @Test("append prunes records older than thirty days")
    func prunesOldRecords() throws {
        let fixture = try RelayStoreFixture()
        defer { fixture.cleanup() }

        let now = Date()
        let old = fixture.record(
            id: "old",
            startedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            billedTokens: 1
        )
        try fixture.store.append(old, now: now)
        #expect(try fixture.store.load().isEmpty)

        let current = fixture.record(id: "current", startedAt: now, billedTokens: 2)
        try fixture.store.append(current, now: now)
        #expect(try fixture.store.load().map(\.id) == ["current"])
    }
}

private struct RelayStoreFixture {
    let root: URL
    let paths: CodexPaths
    let store: RelayActivityStore
    let defaultProfileID = UUID()

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborRelaySQLite-\(UUID().uuidString)", isDirectory: true)
        paths = CodexPaths(
            codexHome: root.appendingPathComponent(".codex", isDirectory: true),
            appSupport: root.appendingPathComponent("support", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        store = RelayActivityStore(paths: paths)
    }

    func record(
        id: String,
        profileID: UUID? = nil,
        startedAt: Date = Date(),
        billedTokens: Int?
    ) -> RelayRequestRecord {
        RelayRequestRecord(
            id: id,
            profileID: profileID ?? defaultProfileID,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.1),
            durationMilliseconds: 100,
            succeeded: true,
            statusCode: 200,
            model: "test-model",
            upstreamProtocol: .responses,
            usage: RelayUsage(
                inputTokens: 10,
                outputTokens: 5,
                totalTokens: 15,
                billedTokens: billedTokens,
                source: billedTokens == nil ? .responseUsage : .providerBilling
            )
        )
    }

    func cleanup() {
        try? FileManager.default.removeItem(at: root)
    }
}
