import Foundation
import SQLite3

private let sessionSQLiteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Harbor-owned session metadata. Deletion is a reversible archive operation;
/// Codex rollout contents remain intact.
public struct CodexSessionManager {
    private let paths: CodexPaths
    private let fileManager: FileManager
    private var metadataURL: URL { paths.appSupport.appendingPathComponent("session-management.json") }

    public init(paths: CodexPaths = .live(), fileManager: FileManager = .default) { self.paths = paths; self.fileManager = fileManager }

    public func load() throws -> [CodexSessionEntry] {
        guard fileManager.fileExists(atPath: metadataURL.path) else { return [] }
        return try JSONDecoder().decode([CodexSessionEntry].self, from: Data(contentsOf: metadataURL))
    }

    public func save(_ entries: [CodexSessionEntry]) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        try JSONEncoder().encode(entries).write(to: metadataURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadataURL.path)
    }

    public func reconcile() throws -> [CodexSessionEntry] {
        var entries = try load(); let old = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        let catalog = try readCatalog()
        let live = try readCodexThreads().map { row -> ThreadRow in
            guard let c = catalog[row.id] else { return row }
            let cwdGroup = c.cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }
            return .init(id: row.id, title: c.title.isEmpty ? row.title : c.title, group: row.group ?? c.group ?? cwdGroup, projectID: row.projectID ?? c.projectID, sectionID: row.sectionID, cwd: c.cwd ?? row.cwd, deleted: row.deleted)
        }
        entries = live.map { row in
            var item = old[row.id] ?? .init(id: row.id, title: row.title)
            item.title = row.title; item.group = row.group; item.projectID = row.projectID; item.sectionID = row.sectionID; item.cwd = row.cwd; item.deleted = row.deleted
            return item
        }
        try save(entries)
        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func setGroup(_ group: String?, for ids: Set<String>) throws -> [CodexSessionEntry] {
        let dbURL = paths.codexHome.appendingPathComponent("state_5.sqlite")
        guard fileManager.fileExists(atPath: dbURL.path) else { return try reconcile() }
        var db: OpaquePointer?; guard sqlite3_open_v2(dbURL.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { return try reconcile() }; defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 5000); sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil)
        var projectID: String?
        if let group, !group.isEmpty {
            projectID = try findProject(named: group, in: db) ?? UUID().uuidString
            if try findProject(named: group, in: db) == nil { try execute("INSERT INTO projects (id,name,metadata,position,created_at_ms,updated_at_ms) VALUES ('\(projectID!)', '\(sql(group))', '{}', 999999, \(Int(Date().timeIntervalSince1970 * 1000)), \(Int(Date().timeIntervalSince1970 * 1000)))", db: db) }
        }
        for id in ids { try execute("UPDATE threads SET project_id = \(projectID.map { "'\($0)'" } ?? "NULL") WHERE id = '\(sql(id))'", db: db) }
        sqlite3_exec(db, "COMMIT", nil, nil, nil)
        let catalog = paths.codexHome.appendingPathComponent("sqlite/codex-dev.db")
        if fileManager.fileExists(atPath: catalog.path) { try? updateCatalog(catalog, ids: ids, projectID: projectID) }
        return try reconcile()
    }

    public func setDeleted(_ deleted: Bool, for ids: Set<String>) throws -> [CodexSessionEntry] {
        var entries = try reconcile()
        let visibility = CodexTaskVisibilityManager(paths: paths, fileManager: fileManager)
        if deleted { try visibility.archiveTaskIDs(Array(ids)) } else { try visibility.restoreTaskIDs(Array(ids)) }
        for index in entries.indices where ids.contains(entries[index].id) { entries[index].deleted = deleted }
        try save(entries); return entries
    }

    public func rename(_ id: String, to title: String) throws -> [CodexSessionEntry] {
        let value = title.trimmingCharacters(in: .whitespacesAndNewlines); guard !value.isEmpty else { return try reconcile() }
        let url = paths.codexHome.appendingPathComponent("state_5.sqlite"); var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { return try reconcile() }; defer { sqlite3_close(db) }
        try execute("UPDATE threads SET title='\(sql(value))', name='\(sql(value))' WHERE id='\(sql(id))'", db: db)
        return try reconcile()
    }

    private struct ThreadRow { let id: String; let title: String; let group: String?; let projectID: String?; let sectionID: String?; let cwd: String?; let deleted: Bool }
    private func readCodexThreads() throws -> [ThreadRow] {
        let url = paths.codexHome.appendingPathComponent("state_5.sqlite"); guard fileManager.fileExists(atPath: url.path) else { return [] }
        var db: OpaquePointer?; guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { return [] }; defer { sqlite3_close(db) }
        let sql = "SELECT t.id, COALESCE(NULLIF(t.title,''), NULLIF(t.name,''), NULLIF(t.first_user_message,''), t.id), p.name, t.project_id, t.thread_section_id, t.cwd, t.archived FROM threads t LEFT JOIN projects p ON p.id=t.project_id"
        var st: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return [] }; defer { sqlite3_finalize(st) }
        var rows:[ThreadRow]=[]; while sqlite3_step(st) == SQLITE_ROW { func str(_ i:Int32)->String? { sqlite3_column_text(st,i).map{String(cString:$0)} }; rows.append(.init(id:str(0) ?? "", title:str(1) ?? "未命名会话", group:str(2), projectID:str(3), sectionID:str(4), cwd:str(5), deleted:sqlite3_column_int(st,6) != 0)) }; return rows.filter{ !$0.id.isEmpty }
    }
    private func readCatalog() throws -> [String: (title: String, group: String?, projectID: String?, cwd: String?)] {
        let url = paths.codexHome.appendingPathComponent("sqlite/codex-dev.db"); guard fileManager.fileExists(atPath: url.path) else { return [:] }
        var db: OpaquePointer?; guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let db else { return [:] }; defer { sqlite3_close(db) }
        let sql = "SELECT c.thread_id, c.display_title, c.project_id, c.cwd FROM local_thread_catalog c WHERE c.host_id='local'"
        var st: OpaquePointer?; guard sqlite3_prepare_v2(db, sql, -1, &st, nil) == SQLITE_OK, let st else { return [:] }; defer { sqlite3_finalize(st) }
        var result: [String: (String,String?,String?,String?)] = [:]
        while sqlite3_step(st) == SQLITE_ROW { func str(_ i:Int32)->String? { sqlite3_column_text(st,i).map{String(cString:$0)} }; if let id = str(0) { let cwd = str(3); let folder = cwd.flatMap { URL(fileURLWithPath: $0).lastPathComponent.isEmpty ? nil : URL(fileURLWithPath: $0).lastPathComponent }; result[id] = (str(1) ?? "", folder, str(2), cwd) } }
        return result
    }
    private func findProject(named name: String, in db: OpaquePointer) throws -> String? { var st:OpaquePointer?; guard sqlite3_prepare_v2(db,"SELECT id FROM projects WHERE name = ? LIMIT 1",-1,&st,nil)==SQLITE_OK, let st else{return nil}; defer{sqlite3_finalize(st)}; sqlite3_bind_text(st,1,name,-1,sessionSQLiteTransient); return sqlite3_step(st)==SQLITE_ROW ? sqlite3_column_text(st,0).map{String(cString:$0)} : nil }
    private func updateCatalog(_ url: URL, ids: Set<String>, projectID: String?) throws { var db:OpaquePointer?; guard sqlite3_open_v2(url.path,&db,SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,nil)==SQLITE_OK,let db else{return}; defer{sqlite3_close(db)}; for id in ids { try execute("UPDATE local_thread_catalog SET project_id = \(projectID.map { "'\($0)'" } ?? "NULL") WHERE thread_id = '\(sql(id))'",db:db) } }
    private func execute(_ sql:String, db:OpaquePointer) throws { guard sqlite3_exec(db,sql,nil,nil,nil)==SQLITE_OK else { throw HarborError.invalidConfiguration("Codex 会话索引更新失败") } }
    private func sql(_ value:String)->String { value.replacingOccurrences(of:"'",with:"''") }
}
