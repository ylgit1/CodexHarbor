import CodexHarborCore
import Foundation

enum CodexProcessSupport {
    static func executableURL(fileManager: FileManager = .default) throws -> URL {
        let fixedCandidates = [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = fixedCandidates.first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }

        let searchPaths = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        if let path = searchPaths
            .map({ URL(fileURLWithPath: $0).appendingPathComponent("codex").path })
            .first(where: { fileManager.isExecutableFile(atPath: $0) }) {
            return URL(fileURLWithPath: path)
        }
        throw HarborError.invalidConfiguration("未找到 Codex 官方命令行工具")
    }

    static func environment() -> [String: String] {
        var environment = ProcessInfo.processInfo.environment
        let requiredPaths = [
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        let currentPaths = (environment["PATH"] ?? "")
            .split(separator: ":")
            .map(String.init)
        environment["PATH"] = (requiredPaths + currentPaths)
            .reduce(into: [String]()) { result, path in
                if !result.contains(path) {
                    result.append(path)
                }
            }
            .joined(separator: ":")
        return environment
    }
}
