import Foundation

public struct OpenWorkspaceResult: Codable, Equatable, Sendable {
    public let workspaceID: UUID
    public let name: String
    public let rootPath: String
    public let gitBranch: String?
    public let isGitDirty: Bool
}

public struct ReadFileResult: Codable, Equatable, Sendable {
    public let path: String
    public let startLine: Int
    public let endLine: Int
    public let totalLines: Int
    public let content: String
    public let truncated: Bool
}

public struct SearchResult: Codable, Equatable, Sendable {
    public let query: String
    public let path: String
    public let output: String
    public let matchLineCount: Int
    public let truncated: Bool
}

public struct OpenWorkspaceTool: Sendable {
    private let workspaceManager: WorkspaceManager

    public init(workspaceManager: WorkspaceManager) {
        self.workspaceManager = workspaceManager
    }

    public func execute(path: String) async throws -> OpenWorkspaceResult {
        let workspace = try await workspaceManager.open(path: path)
        return OpenWorkspaceResult(
            workspaceID: workspace.id,
            name: workspace.displayName,
            rootPath: workspace.rootPath,
            gitBranch: workspace.gitBranch,
            isGitDirty: workspace.isGitDirty
        )
    }
}

public struct ReadFileTool: Sendable {
    public static let defaultLineLimit = 200
    public static let maximumLineLimit = 1_000
    public static let maximumFileSize = 4 * 1_024 * 1_024

    private let workspaceManager: WorkspaceManager
    private let validator: PathValidator

    public init(
        workspaceManager: WorkspaceManager,
        validator: PathValidator = PathValidator()
    ) {
        self.workspaceManager = workspaceManager
        self.validator = validator
    }

    public func execute(
        workspaceID: UUID,
        path: String,
        offset: Int = 1,
        limit: Int = ReadFileTool.defaultLineLimit
    ) async throws -> ReadFileResult {
        guard offset > 0, limit > 0, limit <= Self.maximumLineLimit else {
            throw BridgeError.invalidReadRange
        }

        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let fileURL = try validator.resolve(workspace: workspace, relativePath: path)
        let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true else {
            throw BridgeError.invalidPath(fileURL.path)
        }
        if let fileSize = values.fileSize, fileSize > Self.maximumFileSize {
            throw BridgeError.fileTooLarge(fileURL.path)
        }

        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        guard let text = String(data: data, encoding: .utf8) else {
            throw BridgeError.invalidPath("文件不是 UTF-8 文本：\(fileURL.path)")
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let totalLines = lines.count
        let startIndex = min(offset - 1, totalLines)
        let endIndex = min(startIndex + limit, totalLines)
        let selectedLines = startIndex < endIndex ? Array(lines[startIndex..<endIndex]) : []

        return ReadFileResult(
            path: path,
            startLine: startIndex + 1,
            endLine: endIndex,
            totalLines: totalLines,
            content: selectedLines.joined(separator: "\n"),
            truncated: endIndex < totalLines
        )
    }
}

public struct SearchTool: Sendable {
    public static let maximumOutputBytes = 1_024 * 1_024
    public static let maximumFileSize = 2 * 1_024 * 1_024

    private let workspaceManager: WorkspaceManager
    private let validator: PathValidator

    public init(
        workspaceManager: WorkspaceManager,
        validator: PathValidator = PathValidator()
    ) {
        self.workspaceManager = workspaceManager
        self.validator = validator
    }

    public func execute(
        workspaceID: UUID,
        query: String,
        path: String = "."
    ) async throws -> SearchResult {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedQuery.isEmpty else {
            throw BridgeError.searchFailed("搜索内容不能为空")
        }

        let workspace = try await workspaceManager.workspace(id: workspaceID)
        let searchRoot = try validator.resolve(workspace: workspace, relativePath: path)
        let workspaceRoot = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()

        var output = ""
        var matchLineCount = 0
        var truncated = false

        func appendMatches(from fileURL: URL) throws {
            guard !truncated else { return }
            let values = try fileURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true else { return }
            if let fileSize = values.fileSize, fileSize > Self.maximumFileSize { return }
            let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
            guard let text = String(data: data, encoding: .utf8) else { return }

            let relativePath = fileURL.path.replacingOccurrences(
                of: workspaceRoot.path + "/",
                with: "",
                options: [.anchored]
            )
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                guard line.contains(trimmedQuery) else { continue }
                let entry = "\(relativePath):\(index + 1):\(line)\n"
                if output.utf8.count + entry.utf8.count > Self.maximumOutputBytes {
                    truncated = true
                    return
                }
                output += entry
                matchLineCount += 1
            }
        }

        let values = try searchRoot.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey])
        if values.isRegularFile == true {
            try appendMatches(from: searchRoot)
        } else if values.isDirectory == true {
            let keys: [URLResourceKey] = [.isRegularFileKey, .fileSizeKey]
            guard let enumerator = FileManager.default.enumerator(
                at: searchRoot,
                includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                throw BridgeError.searchFailed("无法遍历目录：\(searchRoot.path)")
            }
            for case let fileURL as URL in enumerator {
                try appendMatches(from: fileURL)
                if truncated { break }
            }
        } else {
            throw BridgeError.invalidPath(searchRoot.path)
        }

        return SearchResult(
            query: trimmedQuery,
            path: path,
            output: output,
            matchLineCount: matchLineCount,
            truncated: truncated
        )
    }
}
