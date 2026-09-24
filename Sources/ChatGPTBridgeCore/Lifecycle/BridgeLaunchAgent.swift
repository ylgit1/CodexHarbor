import Darwin
import Foundation

public struct BridgeLaunchAgentStatus: Equatable, Sendable {
    public let installed: Bool
    public let loaded: Bool
    public let plistURL: URL

    public init(installed: Bool, loaded: Bool, plistURL: URL) {
        self.installed = installed
        self.loaded = loaded
        self.plistURL = plistURL
    }
}

public struct BridgeLaunchAgentManager {
    public static let label = "com.codexharbor.chatgpt-agent"

    private let fileManager: FileManager

    public init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    public func status() -> BridgeLaunchAgentStatus {
        let plistURL = launchAgentURL()
        return BridgeLaunchAgentStatus(
            installed: fileManager.fileExists(atPath: plistURL.path),
            loaded: isLoaded(),
            plistURL: plistURL
        )
    }

    public func makePropertyList(agentExecutableURL: URL, paths: BridgePaths) -> [String: Any] {
        let stdoutURL = paths.logsDirectory.appendingPathComponent("agent-launchd.log")
        let stderrURL = paths.logsDirectory.appendingPathComponent("agent-launchd-error.log")
        return [
            "Label": Self.label,
            "ProgramArguments": [agentExecutableURL.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ProcessType": "Background",
            "ThrottleInterval": 5,
            "StandardOutPath": stdoutURL.path,
            "StandardErrorPath": stderrURL.path
        ]
    }

    @discardableResult
    public func install(agentExecutableURL: URL, paths: BridgePaths) throws -> BridgeLaunchAgentStatus {
        guard fileManager.isExecutableFile(atPath: agentExecutableURL.path) else {
            throw BridgeError.invalidPath("HarborChatGPTAgent 不可执行：\(agentExecutableURL.path)")
        }
        try paths.ensureDirectories()
        BridgeLogRotator.rotateIfNeeded(paths.logsDirectory.appendingPathComponent("agent-launchd.log"))
        BridgeLogRotator.rotateIfNeeded(paths.logsDirectory.appendingPathComponent("agent-launchd-error.log"))

        let launchAgentsDirectory = launchAgentURL().deletingLastPathComponent()
        try fileManager.createDirectory(at: launchAgentsDirectory, withIntermediateDirectories: true)

        let plist = makePropertyList(agentExecutableURL: agentExecutableURL, paths: paths)
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: launchAgentURL(), options: .atomic)

        _ = try? runLaunchctl(["bootout", "\(domainTarget())/\(Self.label)"], acceptFailure: true)
        try runLaunchctl(["bootstrap", domainTarget(), launchAgentURL().path])
        try runLaunchctl(["enable", "\(domainTarget())/\(Self.label)"])
        return status()
    }

    public func uninstall() throws {
        _ = try? runLaunchctl(["bootout", "\(domainTarget())/\(Self.label)"], acceptFailure: true)
        if fileManager.fileExists(atPath: launchAgentURL().path) {
            try fileManager.removeItem(at: launchAgentURL())
        }
    }

    public func kickstart() throws {
        try runLaunchctl(["kickstart", "-k", "\(domainTarget())/\(Self.label)"])
    }

    public func needsRestart(
        agentExecutableURL: URL,
        runtime: BridgeRuntimeState
    ) -> Bool {
        guard runtime.agent == .running,
              let startedAt = runtime.startedAt,
              let attributes = try? fileManager.attributesOfItem(atPath: agentExecutableURL.path),
              let modifiedAt = attributes[.modificationDate] as? Date else {
            return false
        }
        return modifiedAt.timeIntervalSince(startedAt) > 1
    }

    private func isLoaded() -> Bool {
        (try? runLaunchctl(["print", "\(domainTarget())/\(Self.label)"])) != nil
    }

    private func launchAgentURL() -> URL {
        fileManager.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent("\(Self.label).plist")
    }

    private func domainTarget() -> String {
        "gui/\(getuid())"
    }

    @discardableResult
    private func runLaunchctl(_ arguments: [String], acceptFailure: Bool = false) throws -> String {
        let process = Process()
        let stdout = Pipe()
        let stderr = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        process.waitUntilExit()
        let outputData = stdout.fileHandleForReading.readDataToEndOfFile()
        let errorData = stderr.fileHandleForReading.readDataToEndOfFile()
        if process.terminationStatus != 0 && !acceptFailure {
            let message = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw BridgeError.writeFailed(
                "launchctl \(arguments.first ?? "") 失败：\(message?.isEmpty == false ? message! : "exit \(process.terminationStatus)")"
            )
        }
        return String(data: outputData, encoding: .utf8) ?? ""
    }
}
