import Foundation
import SQLite3

public struct CodexTaskMigrationResult: Equatable, Sendable {
    public let inspectedTaskCount: Int
    public let migratedTaskCount: Int
    public let targetProvider: String
    public let targetModel: String?
    public let backupURL: URL?

    public init(
        inspectedTaskCount: Int,
        migratedTaskCount: Int,
        targetProvider: String,
        targetModel: String?,
        backupURL: URL?
    ) {
        self.inspectedTaskCount = inspectedTaskCount
        self.migratedTaskCount = migratedTaskCount
        self.targetProvider = targetProvider
        self.targetModel = targetModel
        self.backupURL = backupURL
    }
}

public struct CodexTaskMigrationPreview: Equatable, Sendable {
    public let inspectedTaskCount: Int
    public let migratableTaskCount: Int
    public let targetProvider: String
    public let targetModel: String?

    public init(inspectedTaskCount: Int, migratableTaskCount: Int, targetProvider: String, targetModel: String?) {
        self.inspectedTaskCount = inspectedTaskCount
        self.migratableTaskCount = migratableTaskCount
        self.targetProvider = targetProvider
        self.targetModel = targetModel
    }
}

/// Migrates Codex's persisted task routing after Codex has fully stopped.
///
/// Codex stores a task's provider in both the rollout JSONL and the `threads`
/// table. Updating only one side leaves conflicting state. This migrator first
/// validates every rollout, snapshots all affected stores, and then updates both.
public struct CodexTaskConnectionMigrator {
    private struct RolloutChange {
        let sourceURL: URL
        let relativePath: String
        let taskID: String
        let originalData: Data
        let migratedData: Data
    }

    private struct MigrationRecord: Codable {
        let identifier: UUID
        let createdAt: Date
        let targetProvider: String
        let targetModel: String?
        let taskIDs: [String]
        let rolloutPaths: [String]
        let databaseNames: [String]
    }

    private let paths: CodexPaths
    private let fileManager: FileManager

    public init(paths: CodexPaths = .live(), fileManager: FileManager = .default) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func migrateAllTasks(
        toProvider targetProvider: String,
        model targetModel: String?,
        visibleTaskIDs: Set<String>? = nil
    ) throws -> CodexTaskMigrationResult {
        guard !targetProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarborError.invalidConfiguration("当前连接没有有效的模型服务商")
        }

        let rolloutURLs = try discoverRollouts()
        let changes = try rolloutURLs.compactMap {
            try plannedChange(for: $0, targetProvider: targetProvider)
        }.filter { change in
            visibleTaskIDs?.contains(change.taskID) ?? true
        }
        let taskIDs = try rolloutURLs.compactMap { try taskID(in: $0) }.filter {
            visibleTaskIDs?.contains($0) ?? true
        }
        let databaseURLs = try discoverStateDatabases().filter {
            try databaseRequiresMigration(
                at: $0,
                targetProvider: targetProvider,
                targetModel: targetModel,
                visibleOnly: visibleTaskIDs != nil
            )
        }

        guard !changes.isEmpty || !databaseURLs.isEmpty else {
            return CodexTaskMigrationResult(
                inspectedTaskCount: taskIDs.count,
                migratedTaskCount: 0,
                targetProvider: targetProvider,
                targetModel: targetModel,
                backupURL: nil
            )
        }

        let identifier = UUID()
        let backupRoot = paths.taskMigrationsURL
            .appendingPathComponent(identifier.uuidString, isDirectory: true)
        let rolloutBackupRoot = backupRoot.appendingPathComponent("sessions", isDirectory: true)
        let databaseBackupRoot = backupRoot.appendingPathComponent("databases", isDirectory: true)

        do {
            try fileManager.createDirectory(at: rolloutBackupRoot, withIntermediateDirectories: true)
            try fileManager.createDirectory(at: databaseBackupRoot, withIntermediateDirectories: true)
            try setOwnerOnlyDirectoryPermissions(on: backupRoot)
            try setOwnerOnlyDirectoryPermissions(on: rolloutBackupRoot)
            try setOwnerOnlyDirectoryPermissions(on: databaseBackupRoot)

            for change in changes {
                let destination = rolloutBackupRoot.appendingPathComponent(change.relativePath)
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try setOwnerOnlyDirectoryPermissions(on: destination.deletingLastPathComponent())
                try change.originalData.write(to: destination, options: .atomic)
                try setOwnerOnlyPermissions(on: destination)
            }
            for databaseURL in databaseURLs {
                try backupDatabase(
                    at: databaseURL,
                    to: databaseBackupRoot.appendingPathComponent(databaseURL.lastPathComponent)
                )
            }

            for change in changes {
                let permissions = try permissions(of: change.sourceURL)
                try change.migratedData.write(to: change.sourceURL, options: .atomic)
                try fileManager.setAttributes(
                    [.posixPermissions: permissions],
                    ofItemAtPath: change.sourceURL.path
                )
            }
            for databaseURL in databaseURLs {
                try updateThreads(
                    in: databaseURL,
                    targetProvider: targetProvider,
                    targetModel: targetModel,
                    visibleOnly: visibleTaskIDs != nil
                )
            }

            let record = MigrationRecord(
                identifier: identifier,
                createdAt: Date(),
                targetProvider: targetProvider,
                targetModel: targetModel,
                taskIDs: taskIDs,
                rolloutPaths: changes.map(\.relativePath),
                databaseNames: databaseURLs.map(\.lastPathComponent)
            )
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let recordURL = backupRoot.appendingPathComponent("migration.json")
            try encoder.encode(record).write(to: recordURL, options: .atomic)
            try setOwnerOnlyPermissions(on: recordURL)

            return CodexTaskMigrationResult(
                inspectedTaskCount: taskIDs.count,
                migratedTaskCount: Set(changes.map(\.taskID)).count,
                targetProvider: targetProvider,
                targetModel: targetModel,
                backupURL: backupRoot
            )
        } catch {
            for change in changes {
                if fileManager.fileExists(atPath: change.sourceURL.path) {
                    let permissions = (try? permissions(of: change.sourceURL)) ?? 0o600
                    try? change.originalData.write(to: change.sourceURL, options: .atomic)
                    try? fileManager.setAttributes(
                        [.posixPermissions: permissions],
                        ofItemAtPath: change.sourceURL.path
                    )
                }
            }
            for databaseURL in databaseURLs {
                let backupURL = databaseBackupRoot.appendingPathComponent(databaseURL.lastPathComponent)
                if fileManager.fileExists(atPath: backupURL.path) {
                    try? restoreDatabase(at: databaseURL, from: backupURL)
                }
            }
            throw error
        }
    }

    public func previewAllTasks(
        toProvider targetProvider: String,
        model targetModel: String?
    ) throws -> CodexTaskMigrationPreview {
        guard !targetProvider.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw HarborError.invalidConfiguration("当前连接没有有效的模型服务商")
        }
        let rolloutURLs = try discoverRollouts()
        let changes = try rolloutURLs.compactMap {
            try plannedChange(for: $0, targetProvider: targetProvider)
        }
        let taskIDs = try rolloutURLs.compactMap { try taskID(in: $0) }
        let databaseURLs = try discoverStateDatabases().filter {
            try databaseRequiresMigration(at: $0, targetProvider: targetProvider, targetModel: targetModel)
        }
        return CodexTaskMigrationPreview(
            inspectedTaskCount: taskIDs.count,
            migratableTaskCount: Set(changes.map(\.taskID)).count + databaseURLs.count,
            targetProvider: targetProvider,
            targetModel: targetModel
        )
    }

    public func restoreLatestMigration() throws -> URL? {
        guard fileManager.fileExists(atPath: paths.taskMigrationsURL.path) else { return nil }
        let candidates = try fileManager.contentsOfDirectory(
            at: paths.taskMigrationsURL,
            includingPropertiesForKeys: [.contentModificationDateKey, .isDirectoryKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
                && fileManager.fileExists(atPath: url.appendingPathComponent("migration.json").path)
        }.sorted {
            let lhs = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            let rhs = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? nil
            return (lhs ?? .distantPast) > (rhs ?? .distantPast)
        }
        guard let root = candidates.first else { return nil }
        let recordURL = root.appendingPathComponent("migration.json")
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(MigrationRecord.self, from: Data(contentsOf: recordURL))
        let rolloutBackupRoot = root.appendingPathComponent("sessions", isDirectory: true)
        for relativePath in record.rolloutPaths {
            let source = rolloutBackupRoot.appendingPathComponent(relativePath)
            let destination = paths.sessionsURL.appendingPathComponent(relativePath)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try fileManager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: source).write(to: destination, options: .atomic)
            try setOwnerOnlyPermissions(on: destination)
        }
        let databaseBackupRoot = root.appendingPathComponent("databases", isDirectory: true)
        let liveDatabases = try discoverStateDatabases()
        for name in record.databaseNames {
            guard let destination = liveDatabases.first(where: { $0.lastPathComponent == name }) else { continue }
            let source = databaseBackupRoot.appendingPathComponent(name)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try restoreDatabase(at: destination, from: source)
        }
        return root
    }

    private func discoverRollouts() throws -> [URL] {
        guard fileManager.fileExists(atPath: paths.sessionsURL.path) else { return [] }
        guard let enumerator = fileManager.enumerator(
            at: paths.sessionsURL,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }

        return try enumerator.compactMap { element in
            guard let url = element as? URL,
                  url.pathExtension == "jsonl",
                  try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else {
                return nil
            }
            return url
        }.sorted { $0.path < $1.path }
    }

    private func discoverStateDatabases() throws -> [URL] {
        guard fileManager.fileExists(atPath: paths.codexHome.path) else { return [] }
        return try fileManager.contentsOfDirectory(
            at: paths.codexHome,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ).filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("state_")
                && name.hasSuffix(".sqlite")
                && (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
        }.sorted { $0.path < $1.path }
    }

    private func plannedChange(for url: URL, targetProvider: String) throws -> RolloutChange? {
        let original = try Data(contentsOf: url)
        guard let newline = original.firstIndex(of: 0x0A) else {
            throw HarborError.invalidConfiguration("任务文件缺少有效的会话元数据：\(url.lastPathComponent)")
        }
        let firstLine = Data(original[..<newline])
        guard var root = try JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              root["type"] as? String == "session_meta",
              var payload = root["payload"] as? [String: Any],
              let taskID = payload["id"] as? String,
              !taskID.isEmpty else {
            throw HarborError.invalidConfiguration("任务文件的会话元数据无效：\(url.lastPathComponent)")
        }
        guard payload["model_provider"] as? String != targetProvider else { return nil }

        payload["model_provider"] = targetProvider
        root["payload"] = payload
        var migrated = try JSONSerialization.data(withJSONObject: root, options: [.sortedKeys])
        migrated.append(0x0A)
        let remainderStart = original.index(after: newline)
        migrated.append(original[remainderStart..<original.endIndex])

        return RolloutChange(
            sourceURL: url,
            relativePath: relativePath(of: url, below: paths.sessionsURL),
            taskID: taskID,
            originalData: original,
            migratedData: migrated
        )
    }

    private func taskID(in url: URL) throws -> String? {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let prefix = try handle.read(upToCount: 256 * 1024) ?? Data()
        let firstLine = Data(prefix.prefix { $0 != 0x0A })
        guard !firstLine.isEmpty,
              let root = try JSONSerialization.jsonObject(with: firstLine) as? [String: Any],
              root["type"] as? String == "session_meta",
              let payload = root["payload"] as? [String: Any] else { return nil }
        return payload["id"] as? String
    }

    private func updateThreads(
        in databaseURL: URL,
        targetProvider: String,
        targetModel: String?,
        visibleOnly: Bool = false
    ) throws {
        var databasePointer: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &databasePointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database = databasePointer else {
            defer { if databasePointer != nil { sqlite3_close(databasePointer) } }
            throw sqliteError(databasePointer, fallback: "无法打开 Codex 任务索引")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)

        guard tableExists("threads", in: database) else { return }
        try execute("BEGIN IMMEDIATE", in: database)
        do {
            let sql: String
            let suffix = visibleOnly ? " WHERE archived = 0" : ""
            if targetModel?.isEmpty == false {
                sql = "UPDATE threads SET model_provider = ?, model = ?\(suffix)"
            } else {
                sql = "UPDATE threads SET model_provider = ?\(suffix)"
            }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
                  let statement else {
                throw sqliteError(database, fallback: "无法更新 Codex 任务索引")
            }
            defer { sqlite3_finalize(statement) }
            sqlite3_bind_text(statement, 1, targetProvider, -1, sqliteTransient)
            if let targetModel, !targetModel.isEmpty {
                sqlite3_bind_text(statement, 2, targetModel, -1, sqliteTransient)
            }
            guard sqlite3_step(statement) == SQLITE_DONE else {
                throw sqliteError(database, fallback: "Codex 任务索引更新失败")
            }
            try execute("COMMIT", in: database)
        } catch {
            try? execute("ROLLBACK", in: database)
            throw error
        }
    }

    private func databaseRequiresMigration(
        at databaseURL: URL,
        targetProvider: String,
        targetModel: String?,
        visibleOnly: Bool = false
    ) throws -> Bool {
        var databasePointer: OpaquePointer?
        guard sqlite3_open_v2(
            databaseURL.path,
            &databasePointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let database = databasePointer else {
            defer { if databasePointer != nil { sqlite3_close(databasePointer) } }
            throw sqliteError(databasePointer, fallback: "无法读取 Codex 任务索引")
        }
        defer { sqlite3_close(database) }
        sqlite3_busy_timeout(database, 5_000)
        guard tableExists("threads", in: database) else { return false }

        let sql: String
        let visibility = visibleOnly ? " AND archived = 0" : ""
        if targetModel?.isEmpty == false {
            sql = "SELECT 1 FROM threads WHERE (model_provider <> ? OR COALESCE(model, '') <> ?)\(visibility) LIMIT 1"
        } else {
            sql = "SELECT 1 FROM threads WHERE model_provider <> ?\(visibility) LIMIT 1"
        }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw sqliteError(database, fallback: "无法检查 Codex 任务索引")
        }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, targetProvider, -1, sqliteTransient)
        if let targetModel, !targetModel.isEmpty {
            sqlite3_bind_text(statement, 2, targetModel, -1, sqliteTransient)
        }
        let result = sqlite3_step(statement)
        guard result == SQLITE_ROW || result == SQLITE_DONE else {
            throw sqliteError(database, fallback: "Codex 任务索引检查失败")
        }
        return result == SQLITE_ROW
    }

    private func tableExists(_ table: String, in database: OpaquePointer) -> Bool {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(
            database,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = ? LIMIT 1",
            -1,
            &statement,
            nil
        ) == SQLITE_OK, let statement else { return false }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, table, -1, sqliteTransient)
        return sqlite3_step(statement) == SQLITE_ROW
    }

    private func backupDatabase(at sourceURL: URL, to destinationURL: URL) throws {
        try copyDatabase(from: sourceURL, to: destinationURL)
        try setOwnerOnlyPermissions(on: destinationURL)
    }

    private func restoreDatabase(at destinationURL: URL, from sourceURL: URL) throws {
        try copyDatabase(from: sourceURL, to: destinationURL)
    }

    private func copyDatabase(from sourceURL: URL, to destinationURL: URL) throws {
        var sourcePointer: OpaquePointer?
        var destinationPointer: OpaquePointer?
        guard sqlite3_open_v2(
            sourceURL.path,
            &sourcePointer,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let source = sourcePointer else {
            defer { if sourcePointer != nil { sqlite3_close(sourcePointer) } }
            throw sqliteError(sourcePointer, fallback: "无法读取 Codex 任务索引")
        }
        defer { sqlite3_close(source) }
        guard sqlite3_open_v2(
            destinationURL.path,
            &destinationPointer,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
            nil
        ) == SQLITE_OK, let destination = destinationPointer else {
            defer { if destinationPointer != nil { sqlite3_close(destinationPointer) } }
            throw sqliteError(destinationPointer, fallback: "无法创建 Codex 任务索引备份")
        }
        defer { sqlite3_close(destination) }

        guard let backup = sqlite3_backup_init(destination, "main", source, "main") else {
            throw sqliteError(destination, fallback: "无法初始化 Codex 任务索引备份")
        }
        let result = sqlite3_backup_step(backup, -1)
        let finishResult = sqlite3_backup_finish(backup)
        guard result == SQLITE_DONE, finishResult == SQLITE_OK else {
            throw sqliteError(destination, fallback: "Codex 任务索引备份失败")
        }
    }

    private func execute(_ sql: String, in database: OpaquePointer) throws {
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw sqliteError(database, fallback: "Codex 任务索引事务失败")
        }
    }

    private func sqliteError(_ database: OpaquePointer?, fallback: String) -> HarborError {
        guard let database, let message = sqlite3_errmsg(database) else {
            return .invalidConfiguration(fallback)
        }
        return .invalidConfiguration("\(fallback)：\(String(cString: message))")
    }

    private func relativePath(of url: URL, below root: URL) -> String {
        let rootPath = root.standardizedFileURL.path.hasSuffix("/")
            ? root.standardizedFileURL.path
            : root.standardizedFileURL.path + "/"
        let path = url.standardizedFileURL.path
        return path.hasPrefix(rootPath) ? String(path.dropFirst(rootPath.count)) : url.lastPathComponent
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try fileManager.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0o600
    }

    private func setOwnerOnlyPermissions(on url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    private func setOwnerOnlyDirectoryPermissions(on url: URL) throws {
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
    }
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
