import Foundation

public struct GitFileChange: Codable, Equatable, Sendable {
    public let path: String
    public let additions: Int
    public let deletions: Int
    public let status: String?

    public init(path: String, additions: Int, deletions: Int, status: String? = nil) {
        self.path = path
        self.additions = additions
        self.deletions = deletions
        self.status = status
    }
}

public struct GitStatusEntry: Codable, Equatable, Sendable {
    public let path: String
    public let indexStatus: String
    public let workTreeStatus: String

    public init(path: String, indexStatus: String, workTreeStatus: String) {
        self.path = path
        self.indexStatus = indexStatus
        self.workTreeStatus = workTreeStatus
    }
}

public struct GitStatusResult: Codable, Equatable, Sendable {
    public let branch: String?
    public let isClean: Bool
    public let entries: [GitStatusEntry]
}

public struct GitChangedFilesResult: Codable, Equatable, Sendable {
    public let files: [GitFileChange]
}

public struct GitService: Sendable {
    private let validator: PathValidator

    public init(validator: PathValidator = PathValidator()) {
        self.validator = validator
    }

    public func getDiff(workspace: BridgeWorkspace, path: String? = nil) throws -> GitDiffResult {
        let path = try validatedPath(path, workspace: workspace)
        var arguments = ["diff", "--no-ext-diff"]
        if let path, !path.isEmpty { arguments += ["--", path] }
        let result = try runGit(arguments, workspace: workspace)
        guard result.exitCode == 0 else { throw BridgeError.gitFailed(result.stderr) }
        return GitDiffResult(
            diff: result.stdout,
            exitCode: result.exitCode,
            files: try getChangedFiles(workspace: workspace, path: path).files
        )
    }

    public func getStatus(workspace: BridgeWorkspace) throws -> GitStatusResult {
        let result = try runGit(["status", "--porcelain=v1", "--branch"], workspace: workspace)
        guard result.exitCode == 0 else { throw BridgeError.gitFailed(result.stderr) }
        var branch: String?
        var entries: [GitStatusEntry] = []
        for line in result.stdout.split(separator: "\n", omittingEmptySubsequences: true).map(String.init) {
            if line.hasPrefix("## ") {
                let branchLine = String(line.dropFirst(3))
                let value = branchLine.range(of: "...").map { String(branchLine[..<$0.lowerBound]) } ?? branchLine
                branch = value == "HEAD (no branch)" ? nil : value
                continue
            }
            guard line.count >= 3 else { continue }
            let index = line.index(line.startIndex, offsetBy: 1)
            let pathStart = line.index(line.startIndex, offsetBy: 3)
            entries.append(GitStatusEntry(
                path: String(line[pathStart...]),
                indexStatus: String(line[line.startIndex]),
                workTreeStatus: String(line[index])
            ))
        }
        return GitStatusResult(branch: branch, isClean: entries.isEmpty, entries: entries)
    }

    public func getChangedFiles(workspace: BridgeWorkspace, path: String? = nil) throws -> GitChangedFilesResult {
        let path = try validatedPath(path, workspace: workspace)
        var arguments = ["diff", "--numstat", "--no-ext-diff", "HEAD"]
        if let path, !path.isEmpty { arguments += ["--", path] }
        var result = try runGit(arguments, workspace: workspace)
        if result.exitCode != 0 {
            arguments = ["diff", "--numstat", "--no-ext-diff"]
            if let path, !path.isEmpty { arguments += ["--", path] }
            result = try runGit(arguments, workspace: workspace)
        }
        guard result.exitCode == 0 else { throw BridgeError.gitFailed(result.stderr) }
        var files = result.stdout.split(separator: "\n", omittingEmptySubsequences: true).compactMap { line -> GitFileChange? in
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return nil }
            return GitFileChange(
                path: String(fields[2]),
                additions: Int(fields[0]) ?? 0,
                deletions: Int(fields[1]) ?? 0
            )
        }

        let status = try getStatus(workspace: workspace)
        let known = Set(files.map(\.path))
        files += status.entries.compactMap { entry in
            guard !known.contains(entry.path) else { return nil }
            return GitFileChange(
                path: entry.path,
                additions: 0,
                deletions: 0,
                status: entry.indexStatus + entry.workTreeStatus
            )
        }
        return GitChangedFilesResult(files: files.sorted { $0.path < $1.path })
    }

    private func validatedPath(_ path: String?, workspace: BridgeWorkspace) throws -> String? {
        guard let path, !path.isEmpty else { return nil }
        let resolved = try validator.resolve(workspace: workspace, relativePath: path, mustExist: false)
        let root = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
            .standardizedFileURL
            .resolvingSymlinksInPath()
        guard resolved.path != root.path else { return "." }
        return String(resolved.path.dropFirst(root.path.count + 1))
    }

    private func runGit(_ arguments: [String], workspace: BridgeWorkspace) throws -> (
        stdout: String,
        stderr: String,
        exitCode: Int32
    ) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = URL(fileURLWithPath: workspace.rootPath, isDirectory: true)
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        let output = stdout.fileHandleForReading.readDataToEndOfFile()
        let error = stderr.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (
            String(decoding: output, as: UTF8.self),
            String(decoding: error, as: UTF8.self),
            process.terminationStatus
        )
    }
}
