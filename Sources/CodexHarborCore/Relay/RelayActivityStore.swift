import Foundation
import SQLite3

public struct RelayActivityBatch: Sendable {
    public let records: [RelayRequestRecord]
    public let nextCursor: Int64

    public init(records: [RelayRequestRecord], nextCursor: Int64) {
        self.records = records
        self.nextCursor = nextCursor
    }
}

public struct RelayActivityStore: Sendable {
    private static let retentionSeconds: TimeInterval = 30 * 24 * 60 * 60
    private static let maximumRecords = 5_000

    private let paths: CodexPaths

    public init(paths: CodexPaths = .live()) {
        self.paths = paths
    }

    private var fileManager: FileManager { .default }

    public func load() throws -> [RelayRequestRecord] {
        try ensureDatabase()
        return try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) { database in
            try migrateLegacyJSONIfNeeded(database: database)
            return try queryRecords(database: database, afterRowID: nil, limit: Self.maximumRecords).records
        }
    }

    public func load(afterRowID cursor: Int64, limit: Int = 1_000) throws -> RelayActivityBatch {
        try ensureDatabase()
        return try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) { database in
            try migrateLegacyJSONIfNeeded(database: database)
            return try queryRecords(
                database: database,
                afterRowID: max(0, cursor),
                limit: max(1, min(limit, Self.maximumRecords))
            )
        }
    }

    public func append(_ record: RelayRequestRecord, now: Date = Date()) throws {
        try ensureDatabase()
        try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) { database in
            try migrateLegacyJSONIfNeeded(database: database)
            try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
            do {
                try upsert(record, database: database)
                let cutoff = now.addingTimeInterval(-Self.retentionSeconds).timeIntervalSince1970
                try deleteOlderThan(cutoff, database: database)
                try trimToMaximumRecords(database: database)
                try execute(database, sql: "COMMIT")
            } catch {
                try? execute(database, sql: "ROLLBACK")
                throw error
            }
        }
    }

    public func billedTokenTotal(
        profileID: UUID? = nil,
        since: Date? = nil
    ) throws -> Int {
        try ensureDatabase()
        return try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) { database in
            try migrateLegacyJSONIfNeeded(database: database)
            var conditions = ["billed_tokens IS NOT NULL"]
            if profileID != nil { conditions.append("profile_id = ?") }
            if since != nil { conditions.append("started_at >= ?") }
            let sql = "SELECT COALESCE(SUM(billed_tokens), 0) FROM relay_requests WHERE " + conditions.joined(separator: " AND ")

            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw databaseError(database, operation: "汇总 Relay Token")
            }
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            if let profileID {
                sqlite3_bind_text(statement, index, profileID.uuidString, -1, sqliteTransient)
                index += 1
            }
            if let since {
                sqlite3_bind_double(statement, index, since.timeIntervalSince1970)
            }
            guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    private func queryRecords(
        database: OpaquePointer,
        afterRowID: Int64?,
        limit: Int
    ) throws -> RelayActivityBatch {
        let hasCursor = afterRowID != nil
        let sql = """
            SELECT
                rowid,
                id,
                profile_id,
                started_at,
                completed_at,
                duration_ms,
                succeeded,
                status_code,
                model,
                upstream_protocol,
                input_tokens,
                cached_input_tokens,
                output_tokens,
                reasoning_output_tokens,
                total_tokens,
                billed_tokens,
                token_source,
                error
            FROM relay_requests
            \(hasCursor ? "WHERE rowid > ?" : "")
            ORDER BY rowid ASC
            LIMIT ?
            """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, operation: "读取 Relay 活动")
        }
        defer { sqlite3_finalize(statement) }

        var bindIndex: Int32 = 1
        if let afterRowID {
            sqlite3_bind_int64(statement, bindIndex, sqlite3_int64(afterRowID))
            bindIndex += 1
        }
        sqlite3_bind_int(statement, bindIndex, Int32(limit))

        var records: [RelayRequestRecord] = []
        records.reserveCapacity(limit)
        var nextCursor = afterRowID ?? 0

        while sqlite3_step(statement) == SQLITE_ROW {
            nextCursor = max(nextCursor, Int64(sqlite3_column_int64(statement, 0)))
            guard let id = text(statement, 1),
                  let profileRaw = text(statement, 2),
                  let profileID = UUID(uuidString: profileRaw),
                  let protocolRaw = text(statement, 9),
                  let upstreamProtocol = HarborRelayProtocol(rawValue: protocolRaw),
                  let sourceRaw = text(statement, 16),
                  let source = RelayTokenSource(rawValue: sourceRaw) else {
                continue
            }

            let billedTokens: Int?
            if sqlite3_column_type(statement, 15) == SQLITE_NULL {
                billedTokens = nil
            } else {
                billedTokens = Int(sqlite3_column_int64(statement, 15))
            }

            records.append(RelayRequestRecord(
                id: id,
                profileID: profileID,
                startedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 3)),
                completedAt: Date(timeIntervalSince1970: sqlite3_column_double(statement, 4)),
                durationMilliseconds: Int(sqlite3_column_int64(statement, 5)),
                succeeded: sqlite3_column_int(statement, 6) != 0,
                statusCode: Int(sqlite3_column_int(statement, 7)),
                model: text(statement, 8),
                upstreamProtocol: upstreamProtocol,
                usage: RelayUsage(
                    inputTokens: Int(sqlite3_column_int64(statement, 10)),
                    cachedInputTokens: Int(sqlite3_column_int64(statement, 11)),
                    outputTokens: Int(sqlite3_column_int64(statement, 12)),
                    reasoningOutputTokens: Int(sqlite3_column_int64(statement, 13)),
                    totalTokens: Int(sqlite3_column_int64(statement, 14)),
                    billedTokens: billedTokens,
                    source: source
                ),
                error: text(statement, 17)
            ))
        }

        return RelayActivityBatch(records: records, nextCursor: nextCursor)
    }

    private func ensureDatabase() throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try withDatabase(flags: SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX) { database in
            try execute(database, sql: "PRAGMA journal_mode=WAL")
            try execute(database, sql: "PRAGMA synchronous=NORMAL")
            try execute(database, sql: """
                CREATE TABLE IF NOT EXISTS relay_requests (
                    id TEXT PRIMARY KEY NOT NULL,
                    profile_id TEXT NOT NULL,
                    started_at REAL NOT NULL,
                    completed_at REAL NOT NULL,
                    duration_ms INTEGER NOT NULL,
                    succeeded INTEGER NOT NULL,
                    status_code INTEGER NOT NULL,
                    model TEXT,
                    upstream_protocol TEXT NOT NULL,
                    input_tokens INTEGER NOT NULL,
                    cached_input_tokens INTEGER NOT NULL,
                    output_tokens INTEGER NOT NULL,
                    reasoning_output_tokens INTEGER NOT NULL,
                    total_tokens INTEGER NOT NULL,
                    billed_tokens INTEGER,
                    token_source TEXT NOT NULL,
                    error TEXT
                )
                """)
            try execute(database, sql: "CREATE INDEX IF NOT EXISTS idx_relay_requests_started_at ON relay_requests(started_at)")
            try execute(database, sql: "CREATE INDEX IF NOT EXISTS idx_relay_requests_profile_started ON relay_requests(profile_id, started_at)")
        }
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.relayEventsDatabaseURL.path)
    }

    private func migrateLegacyJSONIfNeeded(database: OpaquePointer) throws {
        guard fileManager.fileExists(atPath: paths.relayEventsURL.path) else { return }
        guard try recordCount(database: database) == 0 else {
            try? fileManager.removeItem(at: paths.relayEventsURL)
            return
        }

        let data = try Data(contentsOf: paths.relayEventsURL)
        let records = try JSONDecoder().decode([RelayRequestRecord].self, from: data)
        guard !records.isEmpty else {
            try? fileManager.removeItem(at: paths.relayEventsURL)
            return
        }

        try execute(database, sql: "BEGIN IMMEDIATE TRANSACTION")
        do {
            for record in records.suffix(Self.maximumRecords) {
                try upsert(record, database: database)
            }
            try execute(database, sql: "COMMIT")
            try? fileManager.removeItem(at: paths.relayEventsURL)
        } catch {
            try? execute(database, sql: "ROLLBACK")
            throw error
        }
    }

    private func upsert(_ record: RelayRequestRecord, database: OpaquePointer) throws {
        let sql = """
            INSERT INTO relay_requests (
                id, profile_id, started_at, completed_at, duration_ms, succeeded,
                status_code, model, upstream_protocol, input_tokens,
                cached_input_tokens, output_tokens, reasoning_output_tokens,
                total_tokens, billed_tokens, token_source, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO UPDATE SET
                profile_id = excluded.profile_id,
                started_at = excluded.started_at,
                completed_at = excluded.completed_at,
                duration_ms = excluded.duration_ms,
                succeeded = excluded.succeeded,
                status_code = excluded.status_code,
                model = excluded.model,
                upstream_protocol = excluded.upstream_protocol,
                input_tokens = excluded.input_tokens,
                cached_input_tokens = excluded.cached_input_tokens,
                output_tokens = excluded.output_tokens,
                reasoning_output_tokens = excluded.reasoning_output_tokens,
                total_tokens = excluded.total_tokens,
                billed_tokens = excluded.billed_tokens,
                token_source = excluded.token_source,
                error = excluded.error
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, operation: "写入 Relay 活动")
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, record.id, -1, sqliteTransient)
        sqlite3_bind_text(statement, 2, record.profileID.uuidString, -1, sqliteTransient)
        sqlite3_bind_double(statement, 3, record.startedAt.timeIntervalSince1970)
        sqlite3_bind_double(statement, 4, record.completedAt.timeIntervalSince1970)
        sqlite3_bind_int64(statement, 5, sqlite3_int64(record.durationMilliseconds))
        sqlite3_bind_int(statement, 6, record.succeeded ? 1 : 0)
        sqlite3_bind_int(statement, 7, Int32(record.statusCode))
        bindOptionalText(statement, index: 8, value: record.model)
        sqlite3_bind_text(statement, 9, record.upstreamProtocol.rawValue, -1, sqliteTransient)
        sqlite3_bind_int64(statement, 10, sqlite3_int64(record.usage.inputTokens))
        sqlite3_bind_int64(statement, 11, sqlite3_int64(record.usage.cachedInputTokens))
        sqlite3_bind_int64(statement, 12, sqlite3_int64(record.usage.outputTokens))
        sqlite3_bind_int64(statement, 13, sqlite3_int64(record.usage.reasoningOutputTokens))
        sqlite3_bind_int64(statement, 14, sqlite3_int64(record.usage.totalTokens))
        if let billed = record.usage.billedTokens {
            sqlite3_bind_int64(statement, 15, sqlite3_int64(billed))
        } else {
            sqlite3_bind_null(statement, 15)
        }
        sqlite3_bind_text(statement, 16, record.usage.source.rawValue, -1, sqliteTransient)
        bindOptionalText(statement, index: 17, value: record.error)

        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database, operation: "写入 Relay 活动")
        }
    }

    private func deleteOlderThan(_ cutoff: TimeInterval, database: OpaquePointer) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "DELETE FROM relay_requests WHERE started_at < ?", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, operation: "清理 Relay 历史")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_double(statement, 1, cutoff)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database, operation: "清理 Relay 历史")
        }
    }

    private func trimToMaximumRecords(database: OpaquePointer) throws {
        let sql = """
            DELETE FROM relay_requests
            WHERE id IN (
                SELECT id FROM relay_requests
                ORDER BY started_at DESC, rowid DESC
                LIMIT -1 OFFSET ?
            )
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, operation: "裁剪 Relay 历史")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(Self.maximumRecords))
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw databaseError(database, operation: "裁剪 Relay 历史")
        }
    }

    private func recordCount(database: OpaquePointer) throws -> Int {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT COUNT(*) FROM relay_requests", -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw databaseError(database, operation: "检查 Relay 数据")
        }
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { return 0 }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private func withDatabase<T>(
        flags: Int32,
        _ body: (OpaquePointer) throws -> T
    ) throws -> T {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(paths.relayEventsDatabaseURL.path, &pointer, flags, nil) == SQLITE_OK,
              let database = pointer else {
            if let pointer { sqlite3_close(pointer) }
            throw HarborError.invalidConfiguration("无法打开 Relay 活动数据库")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 1_000)
        return try body(database)
    }

    private func execute(_ database: OpaquePointer, sql: String) throws {
        var errorMessage: UnsafeMutablePointer<Int8>?
        guard sqlite3_exec(database, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown error"
            sqlite3_free(errorMessage)
            throw HarborError.invalidConfiguration("Relay SQLite 操作失败：\(message)")
        }
    }

    private func databaseError(_ database: OpaquePointer, operation: String) -> HarborError {
        HarborError.invalidConfiguration("\(operation)失败：\(String(cString: sqlite3_errmsg(database)))")
    }

    private func text(_ statement: OpaquePointer, _ index: Int32) -> String? {
        guard sqlite3_column_type(statement, index) != SQLITE_NULL,
              let raw = sqlite3_column_text(statement, index) else {
            return nil
        }
        return String(cString: raw)
    }

    private func bindOptionalText(_ statement: OpaquePointer, index: Int32, value: String?) {
        if let value {
            sqlite3_bind_text(statement, index, value, -1, sqliteTransient)
        } else {
            sqlite3_bind_null(statement, index)
        }
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
