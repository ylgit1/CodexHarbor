import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public enum CodexTaskVisibilityGroup: String, Codable, Hashable, Sendable {
    case account
    case harborKey
    case customAPI
}

public struct CodexTaskVisibilityResult: Equatable, Sendable {
    public let hiddenTaskCount: Int
    public let shownTaskCount: Int

    public init(hiddenTaskCount: Int, shownTaskCount: Int) {
        self.hiddenTaskCount = hiddenTaskCount
        self.shownTaskCount = shownTaskCount
    }
}

/// Keeps each connection kind's task list separate. Tasks are archived in the
/// Codex index only; rollout files remain untouched and can be restored when
/// the same connection kind is selected again.
public struct CodexTaskVisibilityManager {
    private struct Snapshot: Codable {
        var activeGroup: CodexTaskVisibilityGroup
        var taskIDsByGroup: [CodexTaskVisibilityGroup: [String]]
    }

    private let paths: CodexPaths
    private let fileManager: FileManager
    private var catalogURL: URL { paths.codexHome.appendingPathComponent("sqlite/codex-dev.db") }

    public init(paths: CodexPaths = .live(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func switchTo(_ target: CodexTaskVisibilityGroup, externalModelIDs: Set<String> = []) throws -> CodexTaskVisibilityResult {
        var snapshot = try loadSnapshot()
        let currentRecords = try visibleTaskRecords()
        let currentIDs = currentRecords.map(\.id)
        let sourceGroup = snapshot.activeGroup
        let externalIDs = Set(currentRecords.filter { externalModelIDs.contains($0.model ?? "") }.map(\.id))
        let nativeIDs = currentIDs.filter { !externalIDs.contains($0) }
        if target == .customAPI {
            // All sessions visible before entering an external API belong to
            // the native group, even if an older Harbor version rewrote their
            // provider/model fields and made model-based detection unreliable.
            snapshot.taskIDsByGroup[sourceGroup] = currentIDs
        } else if sourceGroup == .customAPI {
            // Sessions visible while in external mode are external sessions.
            snapshot.taskIDsByGroup[.customAPI] = currentIDs
        } else {
            snapshot.taskIDsByGroup[sourceGroup] = nativeIDs
        }
        // Native account and Harbor connections share the Responses session
        // semantics, so their visible tasks remain eligible for migration.
        // External API tasks are isolated from every native connection.
        let mustIsolate = sourceGroup == .customAPI || target == .customAPI
        if mustIsolate {
            try setArchived(true, ids: currentIDs)
            try setCatalogVisible(false, ids: currentIDs)
        }
        let targetIDs = snapshot.taskIDsByGroup[target] ?? []
        try setArchived(false, ids: targetIDs)
        try setCatalogVisible(true, ids: targetIDs)
        snapshot.activeGroup = target
        try saveSnapshot(snapshot)
        return CodexTaskVisibilityResult(
            hiddenTaskCount: mustIsolate ? currentIDs.count : 0,
            shownTaskCount: targetIDs.count
        )
    }

    public func visibleTaskIDs() throws -> [String] {
        let catalogIDs = try visibleCatalogIDs()
        return catalogIDs.isEmpty ? try visibleTaskRecords().map(\.id) : catalogIDs
    }

    /// Archives sessions in Codex's indexes without touching their rollout files.

    private struct TaskRecord {
        let id: String
        let model: String?
    }

    private func visibleTaskRecords() throws -> [TaskRecord] {
        var records: [TaskRecord] = []
        for database in try stateDatabases() {
            records.append(contentsOf: try queryRecords(in: database, archived: false))
        }
        var deduped: [String: TaskRecord] = [:]
        for record in records { deduped[record.id] = record }
        return deduped.values.sorted { $0.id < $1.id }
    }

    private var snapshotURL: URL {
        paths.appSupport.appendingPathComponent("connection-task-visibility.json")
    }

    private func loadSnapshot() throws -> Snapshot {
        guard fileManager.fileExists(atPath: snapshotURL.path) else {
            return Snapshot(activeGroup: .account, taskIDsByGroup: [:])
        }
        return try JSONDecoder().decode(Snapshot.self, from: Data(contentsOf: snapshotURL))
    }

    private func saveSnapshot(_ snapshot: Snapshot) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try JSONEncoder().encode(snapshot).write(to: snapshotURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: snapshotURL.path)
    }

    private func stateDatabases() throws -> [URL] {
        guard fileManager.fileExists(atPath: paths.codexHome.path) else { return [] }
        return try fileManager.contentsOfDirectory(at: paths.codexHome, includingPropertiesForKeys: [.isRegularFileKey], options: [.skipsHiddenFiles])
            .filter { url in
                url.lastPathComponent.hasPrefix("state_") && url.pathExtension == "sqlite"
                    && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            }
            .sorted { $0.path < $1.path }
    }

    private func queryIDs(in url: URL, archived: Bool) throws -> [String] {
        try queryRecords(in: url, archived: archived).map(\.id)
    }

    private func queryRecords(in url: URL, archived: Bool) throws -> [TaskRecord] {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = pointer else {
            defer { if let pointer { sqlite3_close(pointer) } }
            throw HarborError.invalidConfiguration("无法读取 Codex 任务索引")
        }
        defer { sqlite3_close(database) }
        guard tableExists("threads", in: database) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT id, model FROM threads WHERE archived = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { throw HarborError.invalidConfiguration("无法读取 Codex 任务索引") }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int(statement, 1, archived ? 1 : 0)
        var records: [TaskRecord] = []
        while sqlite3_step(statement) == SQLITE_ROW, let rawID = sqlite3_column_text(statement, 0) {
            let model = sqlite3_column_text(statement, 1).map { String(cString: $0) }
            records.append(TaskRecord(id: String(cString: rawID), model: model))
        }
        return records
    }

    private func setArchived(_ archived: Bool, ids: [String]) throws {
        guard !ids.isEmpty else { return }
        for database in try stateDatabases() {
            try setArchived(archived, ids: ids, in: database)
        }
    }

    private func setArchived(_ archived: Bool, ids: [String], in url: URL) throws {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = pointer else {
            defer { if let pointer { sqlite3_close(pointer) } }
            throw HarborError.invalidConfiguration("无法更新 Codex 任务索引")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard tableExists("threads", in: database), sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else {
            throw HarborError.invalidConfiguration("Codex 任务索引正忙，请稍后重试")
        }
        let sql = archived
            ? "UPDATE threads SET archived = 1, archived_at = ? WHERE id = ?"
            : "UPDATE threads SET archived = 0, archived_at = NULL WHERE id = ?"
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw HarborError.invalidConfiguration("无法更新 Codex 任务索引")
        }
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            if archived {
                sqlite3_bind_int64(statement, 1, Int64(Date().timeIntervalSince1970))
                sqlite3_bind_text(statement, 2, id, -1, sqliteTransient)
            } else {
                sqlite3_bind_text(statement, 1, id, -1, sqliteTransient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
                throw HarborError.invalidConfiguration("Codex 任务索引更新失败")
            }
        }
        guard sqlite3_exec(database, "COMMIT", nil, nil, nil) == SQLITE_OK else {
            sqlite3_exec(database, "ROLLBACK", nil, nil, nil)
            throw HarborError.invalidConfiguration("Codex 任务索引提交失败")
        }
    }

    private func visibleCatalogIDs() throws -> [String] {
        guard fileManager.fileExists(atPath: catalogURL.path) else { return [] }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &pointer, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = pointer else { return [] }
        defer { sqlite3_close(database) }
        guard tableExists("local_thread_catalog", in: database) else { return [] }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT thread_id FROM local_thread_catalog WHERE missing_candidate = 0", -1, &statement, nil) == SQLITE_OK,
              let statement else { return [] }
        defer { sqlite3_finalize(statement) }
        var ids: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW, let raw = sqlite3_column_text(statement, 0) {
            ids.append(String(cString: raw))
        }
        return ids
    }

    private func setCatalogVisible(_ visible: Bool, ids: [String]) throws {
        guard !ids.isEmpty, fileManager.fileExists(atPath: catalogURL.path) else { return }
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(catalogURL.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let database = pointer else { return }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard tableExists("local_thread_catalog", in: database), sqlite3_exec(database, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK else { return }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "UPDATE local_thread_catalog SET missing_candidate = ? WHERE thread_id = ?", -1, &statement, nil) == SQLITE_OK,
              let statement else { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); return }
        defer { sqlite3_finalize(statement) }
        for id in ids {
            sqlite3_reset(statement)
            sqlite3_clear_bindings(statement)
            sqlite3_bind_int(statement, 1, visible ? 0 : 1)
            sqlite3_bind_text(statement, 2, id, -1, sqliteTransient)
            guard sqlite3_step(statement) == SQLITE_DONE else { sqlite3_exec(database, "ROLLBACK", nil, nil, nil); return }
        }
        sqlite3_exec(database, "COMMIT", nil, nil, nil)
    }

    private func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1", -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }
}
