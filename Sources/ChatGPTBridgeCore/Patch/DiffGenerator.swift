import Foundation

public struct DiffGenerator: Sendable {
    public init() {}

    public func generate(old: String, new: String, path: String) throws -> String {
        guard old != new else { return "" }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-diff-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let oldURL = directory.appendingPathComponent("old")
        let newURL = directory.appendingPathComponent("new")
        try Data(old.utf8).write(to: oldURL)
        try Data(new.utf8).write(to: newURL)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "git", "diff", "--no-index", "--no-ext-diff", "--unified=3", "--", oldURL.path, newURL.path
        ]
        let output = Pipe()
        let error = Pipe()
        process.standardOutput = output
        process.standardError = error
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        let errorData = error.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else {
            throw BridgeError.patchFailed(String(decoding: errorData, as: UTF8.self))
        }

        var lines = String(decoding: data, as: UTF8.self)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
        if let index = lines.firstIndex(where: { $0.hasPrefix("--- ") }) {
            lines[index] = "--- a/\(path)"
        }
        if let index = lines.firstIndex(where: { $0.hasPrefix("+++ ") }) {
            lines[index] = "+++ b/\(path)"
        }
        if !lines.isEmpty {
            lines[0] = "diff --git a/\(path) b/\(path)"
        }
        return lines.joined(separator: "\n")
    }
}
