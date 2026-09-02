import Foundation

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
        let visibility = CodexTaskVisibilityManager(paths: paths, fileManager: fileManager)
        let ids = try visibility.indexedTaskIDs()
        var entries = try load(); let known = Set(entries.map(\.id))
        for id in ids where !known.contains(id) { entries.append(.init(id: id, title: id)) }
        try save(entries)
        return entries.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }

    public func setGroup(_ group: String?, for ids: Set<String>) throws -> [CodexSessionEntry] {
        var entries = try reconcile()
        for index in entries.indices where ids.contains(entries[index].id) { entries[index].group = group }
        try save(entries); return entries
    }

    public func setDeleted(_ deleted: Bool, for ids: Set<String>) throws -> [CodexSessionEntry] {
        var entries = try reconcile()
        let visibility = CodexTaskVisibilityManager(paths: paths, fileManager: fileManager)
        if deleted { try visibility.archiveTaskIDs(Array(ids)) } else { try visibility.restoreTaskIDs(Array(ids)) }
        for index in entries.indices where ids.contains(entries[index].id) { entries[index].deleted = deleted }
        try save(entries); return entries
    }
}
