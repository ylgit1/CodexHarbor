import Foundation

/// Reversible workspace-only file operations. A trash entry is stored outside
/// the project, so removed generated directories do not pollute Git status.
public struct WorkspaceTrashEntry: Codable, Equatable, Sendable {
    public let id: UUID
    public let workspaceID: UUID
    public let workspaceRoot: String
    public let originalPath: String
    public let deletedAt: Date
}

public struct WorkspacePathOperationResult: Codable, Equatable, Sendable {
    public let operation: String
    public let path: String
    public let destination: String?
    public let trashID: UUID?
}

public actor WorkspaceFileOperations {
    private let workspaceManager: WorkspaceManager
    private let permissionEngine: PermissionEngine
    private let auditLogger: AuditLogger
    private let trashRoot: URL
    private let fileManager: FileManager
    private let validator = PathValidator()

    public init(
        workspaceManager: WorkspaceManager,
        permissionEngine: PermissionEngine,
        auditLogger: AuditLogger,
        trashRoot: URL,
        fileManager: FileManager = .default
    ) {
        self.workspaceManager = workspaceManager
        self.permissionEngine = permissionEngine
        self.auditLogger = auditLogger
        self.trashRoot = trashRoot
        self.fileManager = fileManager
    }

    public func createDirectory(workspaceID: UUID, path: String, approvalGranted: Bool = false) async throws -> WorkspacePathOperationResult {
        try permissionEngine.authorizeModification(operation: "create_directory \(path)", approvalGranted: approvalGranted)
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let target = try securePath(workspace: workspace, path: path, mustExist: false)
        guard !fileManager.fileExists(atPath: target.path) else { throw BridgeError.writeFailed("目录或文件已存在：\(path)") }
        try fileManager.createDirectory(at: target, withIntermediateDirectories: true)
        await audit("create_directory", workspaceID: workspaceID, path: path)
        return WorkspacePathOperationResult(operation: "create_directory", path: path, destination: nil, trashID: nil)
    }

    public func move(workspaceID: UUID, source: String, destination: String, approvalGranted: Bool = false) async throws -> WorkspacePathOperationResult {
        try permissionEngine.authorizeModification(operation: "move_path \(source) → \(destination)", approvalGranted: approvalGranted)
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let from = try securePath(workspace: workspace, path: source, mustExist: true)
        let to = try securePath(workspace: workspace, path: destination, mustExist: false)
        guard from != to, !AllowedRootsManager.isSameOrDescendant(to, of: from) else {
            throw BridgeError.invalidPath("不能将目录移动到自身或其子目录")
        }
        guard !fileManager.fileExists(atPath: to.path) else { throw BridgeError.writeFailed("目标路径已存在：\(destination)") }
        let parent = to.deletingLastPathComponent()
        guard fileManager.fileExists(atPath: parent.path) else { throw BridgeError.invalidPath("目标父目录不存在：\(destination)") }
        try fileManager.moveItem(at: from, to: to)
        await audit("move_path", workspaceID: workspaceID, path: source)
        return WorkspacePathOperationResult(operation: "move_path", path: source, destination: destination, trashID: nil)
    }

    public func trash(workspaceID: UUID, path: String, approvalGranted: Bool = false) async throws -> WorkspacePathOperationResult {
        try permissionEngine.authorizeModification(operation: "trash_path \(path)", approvalGranted: approvalGranted)
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let source = try securePath(workspace: workspace, path: path, mustExist: true)
        let id = UUID()
        let directory = trashRoot.appendingPathComponent(id.uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        try fileManager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let record = WorkspaceTrashEntry(id: id, workspaceID: workspaceID,
                                         workspaceRoot: workspace.rootPath,
                                         originalPath: path, deletedAt: Date())
        do {
            let metadata = directory.appendingPathComponent("metadata.json")
            try JSONEncoder().encode(record).write(to: metadata, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: metadata.path)
            try fileManager.moveItem(at: source, to: directory.appendingPathComponent("payload"))
        } catch {
            try? fileManager.removeItem(at: directory)
            throw error
        }
        await audit("trash_path", workspaceID: workspaceID, path: path)
        return WorkspacePathOperationResult(operation: "trash_path", path: path, destination: nil, trashID: id)
    }

    public func restore(workspaceID: UUID, trashID: UUID, approvalGranted: Bool = false) async throws -> WorkspacePathOperationResult {
        try permissionEngine.authorizeModification(operation: "restore_path \(trashID.uuidString)", approvalGranted: approvalGranted)
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let directory = trashRoot.appendingPathComponent(trashID.uuidString, isDirectory: true)
        let metadata = directory.appendingPathComponent("metadata.json")
        let record = try JSONDecoder().decode(WorkspaceTrashEntry.self, from: Data(contentsOf: metadata))
        guard record.id == trashID, record.workspaceID == workspaceID,
              record.workspaceRoot == workspace.rootPath else {
            throw BridgeError.pathNotAllowed("回收记录不属于当前 Workspace")
        }
        let target = try securePath(workspace: workspace, path: record.originalPath, mustExist: false)
        guard !fileManager.fileExists(atPath: target.path) else {
            throw BridgeError.writeFailed("原路径已存在，请先处理冲突：\(record.originalPath)")
        }
        try fileManager.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fileManager.moveItem(at: directory.appendingPathComponent("payload"), to: target)
        try fileManager.removeItem(at: directory)
        await audit("restore_path", workspaceID: workspaceID, path: record.originalPath)
        return WorkspacePathOperationResult(operation: "restore_path", path: record.originalPath, destination: nil, trashID: trashID)
    }

    public func listTrash(workspaceID: UUID) async throws -> [WorkspaceTrashEntry] {
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let contents = (try? fileManager.contentsOfDirectory(at: trashRoot, includingPropertiesForKeys: nil)) ?? []
        return contents.compactMap { url -> WorkspaceTrashEntry? in
            guard let data = try? Data(contentsOf: url.appendingPathComponent("metadata.json")),
                  let entry = try? JSONDecoder().decode(WorkspaceTrashEntry.self, from: data),
                  entry.workspaceID == workspaceID, entry.workspaceRoot == workspace.rootPath,
                  entry.id.uuidString == url.lastPathComponent else { return nil }
            return entry
        }.sorted { $0.deletedAt > $1.deletedAt }
    }

    private func securePath(workspace: BridgeWorkspace, path: String, mustExist: Bool) throws -> URL {
        let components = (path as NSString).pathComponents
        guard !path.isEmpty, !path.hasPrefix("/"), !components.isEmpty,
              !components.contains("."), !components.contains(".."),
              !components.contains(".git"), !components.contains(".codexharbor-trash"),
              !components.contains(".codexharbor"), !path.contains("\u{0}") else {
            throw BridgeError.invalidPath("禁止修改工作区根目录、Git 数据或受保护路径：\(path)")
        }
        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        // Refuse intermediate symlinks and symlink targets, instead of resolving
        // a symlink and mutating a different physical object.
        var current = root
        for component in components {
            current.appendPathComponent(component)
            if (try? current.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                throw BridgeError.pathNotAllowed("禁止通过符号链接操作文件：\(path)")
            }
        }
        let resolved = try validator.resolve(workspace: workspace, relativePath: path, mustExist: mustExist)
        guard resolved != root.standardizedFileURL.resolvingSymlinksInPath() else {
            throw BridgeError.pathNotAllowed("不能操作 Workspace 根目录")
        }
        return resolved
    }

    private func audit(_ tool: String, workspaceID: UUID, path: String) async {
        try? await auditLogger.record(AuditEntry(
            tool: tool, workspaceID: workspaceID, target: path,
            status: .success, durationMilliseconds: 0, summary: tool
        ))
    }
}
