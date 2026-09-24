import Foundation
import SQLite3

/// A read-only projection of one Codex turn. Codex creates one row for every
/// user submission and updates it when the turn finishes, which makes it a
/// better source for request counts than Harbor's own button/health events.
public struct CodexTurnRecord: Equatable, Sendable {
    public let id: String
    public let status: String
    public let startedAt: Date?
    public let completedAt: Date?
    public let durationMilliseconds: Int?

    public init(
        id: String,
        status: String,
        startedAt: Date?,
        completedAt: Date?,
        durationMilliseconds: Int?
    ) {
        self.id = id
        self.status = status
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.durationMilliseconds = durationMilliseconds
    }

    public var isTerminal: Bool {
        completedAt != nil || status == "completed" || status == "failed" || status == "cancelled"
    }
}

public struct CodexRequestMonitor: Sendable {
    private let paths: CodexPaths

    public init(paths: CodexPaths = .live()) {
        self.paths = paths
    }

    /// Reads recent rows without taking a write lock. A missing database or
    /// an older Codex schema is treated as an unavailable monitor, not as a
    /// fatal Harbor error.
    public func recentTurns(limit: Int = 256) throws -> [CodexTurnRecord] {
        guard FileManager.default.fileExists(atPath: paths.threadHistoryDatabaseURL.path) else { return [] }

        var pointer: OpaquePointer?
        guard sqlite3_open_v2(
            paths.threadHistoryDatabaseURL.path,
            &pointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK,
        let database = pointer else {
            if let pointer { sqlite3_close(pointer) }
            return []
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 250)

        guard tableExists("thread_turns", in: database) else { return [] }
        let sql = """
            SELECT thread_id, turn_id, status, started_at, completed_at, duration_ms
            FROM thread_turns
            ORDER BY COALESCE(completed_at, started_at) DESC
            LIMIT ?
            """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, Int32(max(1, min(limit, 2_000))))

        var records: [CodexTurnRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            guard let threadRaw = sqlite3_column_text(statement, 0),
                  let turnRaw = sqlite3_column_text(statement, 1),
                  let statusRaw = sqlite3_column_text(statement, 2) else { continue }

            let threadID = String(cString: threadRaw)
            let turnID = String(cString: turnRaw)
            let status = String(cString: statusRaw)
            let startedAt = dateValue(statement, index: 3)
            let completedAt = dateValue(statement, index: 4)
            let durationMilliseconds: Int?
            if sqlite3_column_type(statement, 5) == SQLITE_NULL {
                durationMilliseconds = nil
            } else {
                durationMilliseconds = Int(sqlite3_column_int64(statement, 5))
            }
            records.append(CodexTurnRecord(
                id: "\(threadID)/\(turnID)",
                status: status,
                startedAt: startedAt,
                completedAt: completedAt,
                durationMilliseconds: durationMilliseconds
            ))
        }
        return records
    }

    private func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK,
        let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func dateValue(_ statement: OpaquePointer?, index: Int32) -> Date? {
        guard let statement, sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
        return Date(timeIntervalSince1970: Double(sqlite3_column_int64(statement, index)))
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
