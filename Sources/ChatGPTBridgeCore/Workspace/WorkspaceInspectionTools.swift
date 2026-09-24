import Foundation

public enum WorkspaceEntryKind: String, Codable, Equatable, Sendable {
    case file
    case directory
    case symlink
    case other
}

public struct WorkspaceDirectoryEntry: Codable, Equatable, Sendable {
    public let name: String
    public let path: String
    public let kind: WorkspaceEntryKind
    public let size: Int?
    public let isHidden: Bool
}

public struct ListDirectoryResult: Codable, Equatable, Sendable {
    public let path: String
    public let entries: [WorkspaceDirectoryEntry]
    public let truncated: Bool
}

public struct WorkspaceTreeEntry: Codable, Equatable, Sendable {
    public let path: String
    public let kind: WorkspaceEntryKind
    public let depth: Int
}

public struct WorkspaceTreeResult: Codable, Equatable, Sendable {
    public let path: String
    public let entries: [WorkspaceTreeEntry]
    public let maxDepth: Int
    public let truncated: Bool
}

public struct WorkspaceInspectionTool: Sendable {
    public static let maximumDirectoryEntries = 500
    public static let maximumTreeEntries = 2_000
    public static let maximumTreeDepth = 6

    private static let defaultExcludedDirectoryNames: Set<String> = [
        ".git", ".build", ".swiftpm", ".idea", ".vscode", ".venv", "venv",
        "node_modules", "dist", "build", "DerivedData", "target", "__pycache__"
    ]

    private let workspaceManager: WorkspaceManager
    private let validator: PathValidator

    public init(
        workspaceManager: WorkspaceManager,
        validator: PathValidator = PathValidator()
    ) {
        self.workspaceManager = workspaceManager
        self.validator = validator
    }

    public func listDirectory(
        workspaceID: UUID,
        path: String = ".",
        includeHidden: Bool = false,
        limit: Int = maximumDirectoryEntries
    ) async throws -> ListDirectoryResult {
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let directoryURL = try validator.resolve(workspace: workspace, relativePath: normalized(path))

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: directoryURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BridgeError.invalidPath(directoryURL.path)
        }

        let requestedLimit = max(1, min(limit, Self.maximumDirectoryEntries))
        let urls = try fileManager.contentsOfDirectory(
            at: directoryURL,
            includingPropertiesForKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey
            ],
            options: []
        )

        let filtered = urls.compactMap { url -> WorkspaceDirectoryEntry? in
            let values = try? url.resourceValues(forKeys: [
                .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .isHiddenKey
            ])
            let hidden = values?.isHidden == true || url.lastPathComponent.hasPrefix(".")
            guard includeHidden || !hidden else { return nil }
            let kind = Self.kind(from: values)
            return WorkspaceDirectoryEntry(
                name: url.lastPathComponent,
                path: relativePath(for: url, workspace: workspace),
                kind: kind,
                size: kind == .file ? values?.fileSize : nil,
                isHidden: hidden
            )
        }
        .sorted {
            if $0.kind == .directory && $1.kind != .directory { return true }
            if $0.kind != .directory && $1.kind == .directory { return false }
            return $0.name.localizedStandardCompare($1.name) == .orderedAscending
        }

        return ListDirectoryResult(
            path: displayPath(directoryURL, workspace: workspace),
            entries: Array(filtered.prefix(requestedLimit)),
            truncated: filtered.count > requestedLimit
        )
    }

    public func workspaceTree(
        workspaceID: UUID,
        path: String = ".",
        depth: Int = 3,
        includeHidden: Bool = false,
        limit: Int = maximumTreeEntries
    ) async throws -> WorkspaceTreeResult {
        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let rootURL = try validator.resolve(workspace: workspace, relativePath: normalized(path))

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: rootURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            throw BridgeError.invalidPath(rootURL.path)
        }

        let maxDepth = max(1, min(depth, Self.maximumTreeDepth))
        let maxEntries = max(1, min(limit, Self.maximumTreeEntries))
        var entries: [WorkspaceTreeEntry] = []
        var truncated = false

        func walk(_ directory: URL, currentDepth: Int) throws {
            guard currentDepth <= maxDepth, !truncated else { return }
            let children = try fileManager.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey
                ],
                options: []
            )
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }

            for child in children {
                if entries.count >= maxEntries {
                    truncated = true
                    return
                }

                let values = try? child.resourceValues(forKeys: [
                    .isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .isHiddenKey
                ])
                let hidden = values?.isHidden == true || child.lastPathComponent.hasPrefix(".")
                if !includeHidden && hidden { continue }

                let kind = Self.kind(from: values)
                entries.append(WorkspaceTreeEntry(
                    path: relativePath(for: child, workspace: workspace),
                    kind: kind,
                    depth: currentDepth
                ))

                guard kind == .directory,
                      values?.isSymbolicLink != true,
                      currentDepth < maxDepth else {
                    continue
                }
                if Self.defaultExcludedDirectoryNames.contains(child.lastPathComponent) {
                    continue
                }

                let canonical = child.standardizedFileURL.resolvingSymlinksInPath()
                let workspaceRoot = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
                    .standardizedFileURL
                    .resolvingSymlinksInPath()
                guard AllowedRootsManager.isSameOrDescendant(canonical, of: workspaceRoot) else {
                    continue
                }
                try walk(child, currentDepth: currentDepth + 1)
            }
        }

        try walk(rootURL, currentDepth: 1)
        return WorkspaceTreeResult(
            path: displayPath(rootURL, workspace: workspace),
            entries: entries,
            maxDepth: maxDepth,
            truncated: truncated
        )
    }

    private func normalized(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "." : trimmed
    }

    private func relativePath(for url: URL, workspace: BridgeWorkspace) -> String {
        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let target = url.standardizedFileURL
        if target.path == root.path { return "." }
        if target.path.hasPrefix(root.path + "/") {
            return String(target.path.dropFirst(root.path.count + 1))
        }
        return url.lastPathComponent
    }

    private func displayPath(_ url: URL, workspace: BridgeWorkspace) -> String {
        relativePath(for: url, workspace: workspace)
    }

    private static func kind(from values: URLResourceValues?) -> WorkspaceEntryKind {
        if values?.isSymbolicLink == true { return .symlink }
        if values?.isDirectory == true { return .directory }
        if values?.isRegularFile == true { return .file }
        return .other
    }
}
