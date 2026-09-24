import Foundation

public actor AllowedRootsManager {
    private var roots: [URL]

    public init(roots: [URL]) {
        self.roots = roots.map(Self.canonicalURL)
    }

    public func all() -> [URL] {
        roots
    }

    public func replace(with roots: [URL]) {
        self.roots = roots.map(Self.canonicalURL)
    }

    public func add(_ url: URL) {
        let canonical = Self.canonicalURL(url)
        guard !roots.contains(canonical) else { return }
        roots.append(canonical)
    }

    public func remove(_ url: URL) {
        let canonical = Self.canonicalURL(url)
        roots.removeAll { $0 == canonical }
    }

    public func contains(_ url: URL) -> Bool {
        let candidate = Self.canonicalURL(url)
        return roots.contains { Self.isSameOrDescendant(candidate, of: $0) }
    }

    static func canonicalURL(_ url: URL) -> URL {
        url.standardizedFileURL.resolvingSymlinksInPath()
    }

    static func isSameOrDescendant(_ candidate: URL, of root: URL) -> Bool {
        let candidateComponents = canonicalURL(candidate).pathComponents
        let rootComponents = canonicalURL(root).pathComponents
        guard candidateComponents.count >= rootComponents.count else { return false }
        return Array(candidateComponents.prefix(rootComponents.count)) == rootComponents
    }
}

public struct PathValidator: Sendable {
    public init() {}

    public func resolve(
        workspace: BridgeWorkspace,
        relativePath: String,
        mustExist: Bool = true,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !relativePath.hasPrefix("/") else {
            throw BridgeError.invalidPath(relativePath)
        }

        let workspaceRoot = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        let requested = workspaceRoot
            .appendingPathComponent(relativePath.isEmpty ? "." : relativePath)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        guard AllowedRootsManager.isSameOrDescendant(requested, of: workspaceRoot) else {
            throw BridgeError.pathNotAllowed(requested.path)
        }

        if mustExist, !fileManager.fileExists(atPath: requested.path) {
            throw BridgeError.invalidPath(requested.path)
        }

        return requested
    }
}

public actor WorkspaceManager {
    private let allowedRoots: AllowedRootsManager
    private let fileManager: FileManager
    private let persistenceURL: URL?
    private var workspaces: [UUID: BridgeWorkspace] = [:]

    public init(
        allowedRoots: AllowedRootsManager,
        fileManager: FileManager = .default,
        persistenceURL: URL? = nil
    ) {
        self.allowedRoots = allowedRoots
        self.fileManager = fileManager
        self.persistenceURL = persistenceURL

        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL) {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            if let decoded = try? decoder.decode([BridgeWorkspace].self, from: data) {
                self.workspaces = Dictionary(uniqueKeysWithValues: decoded.map { ($0.id, $0) })
            }
        }
    }

    public func open(path: String) async throws -> BridgeWorkspace {
        let candidate = URL(fileURLWithPath: path, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw BridgeError.invalidPath(path)
        }
        guard await allowedRoots.contains(candidate) else {
            throw BridgeError.pathNotAllowed(candidate.path)
        }

        if let existing = workspaces.values.first(where: { $0.rootPath == candidate.path }) {
            var refreshed = existing
            refreshed.lastOpenedAt = Date()
            let git = Self.gitStatus(at: candidate)
            refreshed.gitBranch = git.branch
            refreshed.isGitDirty = git.dirty
            workspaces[refreshed.id] = refreshed
            persist()
            return refreshed
        }

        let git = Self.gitStatus(at: candidate)
        let workspace = BridgeWorkspace(
            rootPath: candidate.path,
            displayName: candidate.lastPathComponent,
            gitBranch: git.branch,
            isGitDirty: git.dirty
        )
        workspaces[workspace.id] = workspace
        persist()
        return workspace
    }

    public func workspace(id: UUID) async throws -> BridgeWorkspace {
        guard let workspace = workspaces[id] else {
            throw BridgeError.workspaceNotFound(id)
        }
        let url = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        guard await allowedRoots.contains(url) else {
            workspaces[id] = nil
            persist()
            throw BridgeError.pathNotAllowed(workspace.rootPath)
        }
        return workspace
    }

    public func list() -> [BridgeWorkspace] {
        workspaces.values.sorted { $0.lastOpenedAt > $1.lastOpenedAt }
    }

    public func close(id: UUID) {
        workspaces[id] = nil
        persist()
    }

    private func persist() {
        guard let persistenceURL else { return }
        let values = workspaces.values.sorted { $0.createdAt < $1.createdAt }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fileManager.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(values).write(to: persistenceURL, options: .atomic)
        } catch {
            // Workspace persistence is best-effort; runtime operations remain available.
        }
    }

    private static func gitStatus(at root: URL) -> (branch: String?, dirty: Bool) {
        let branch = runGit(arguments: ["-C", root.path, "rev-parse", "--abbrev-ref", "HEAD"])
            .flatMap { output in
                let trimmed = output.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty || trimmed == "HEAD" ? nil : trimmed
            }
        let status = runGit(arguments: ["-C", root.path, "status", "--porcelain"])
        return (branch, !(status?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true))
    }

    private static func runGit(arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return nil }
            return String(data: data, encoding: .utf8)
        } catch {
            return nil
        }
    }
}
