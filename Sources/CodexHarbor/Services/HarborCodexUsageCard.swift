import Foundation
import Darwin

/// Owns a single native, per-user macOS notch overlay. No browser DOM/CDP integration.
enum HarborCodexUsageCard {
    enum Action: Sendable { case enable, disable }
    static let enabledKey = "harbor.nativeUsageCard.enabled"
    static let label = "com.codexharbor.usage-card"

    static var isInstalled: Bool {
        FileManager.default.fileExists(atPath: agentPlist.path) &&
        (configuration()?["enabled"] as? Bool == true)
    }

    static var requiresNotchMigration: Bool {
        isInstalled && (configuration()?["position"] as? String != "notch")
    }

    static var legacyPluginDetected: Bool {
        FileManager.default.fileExists(
            atPath: FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/LaunchAgents/com.codexusagebadge.agent.plist").path
        )
    }

    private static var directory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/UsageCard", isDirectory: true)
    }
    private static var configurationFile: URL { directory.appendingPathComponent("configuration.json") }
    private static var agentPlist: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/LaunchAgents/\(label).plist")
    }
    private static var agent: URL {
        let packaged = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HarborUsageCardAgent")
        if FileManager.default.isExecutableFile(atPath: packaged.path) { return packaged }
        return Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("HarborUsageCardAgent") ?? packaged
    }

    private static func configuration() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configurationFile) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func perform(_ action: Action) throws -> String {
        switch action {
        case .enable:
            guard !legacyPluginDetected else {
                throw CardError.message("检测到旧版第三方额度插件，请先卸载它，以免重复显示。")
            }
            guard FileManager.default.isExecutableFile(atPath: agent.path) else {
                throw CardError.message("找不到内置原生额度后台，请使用新版 CodexHarbor。")
            }
            try saveConfiguration(enabled: true)
            try installAgent()
            return "刘海额度已开启。仅 ChatGPT 为当前前台应用时显示；切到其他 App 会自动隐藏。"
        case .disable:
            try saveConfiguration(enabled: false)
            try removeAgent()
            return "刘海额度已关闭"
        }
    }

    static func runtimeDescription() -> String {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("status.json")),
              let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let value = state["state"] as? String else {
            return "后台尚未提供显示状态"
        }
        let detail = state["detail"] as? String ?? ""
        switch value {
        case "visible":
            let five = (state["remainingFiveHours"] as? NSNumber)?.doubleValue
            let weekly = (state["remainingWeekly"] as? NSNumber)?.doubleValue
            let values = [
                five.map { "5 小时剩余 \(Int($0.rounded()))%" },
                weekly.map { "每周剩余 \(Int($0.rounded()))%" }
            ].compactMap { $0 }
            return values.isEmpty ? "刘海已显示，额度正在读取" : "刘海显示中 · " + values.joined(separator: " · ")
        case "waiting-for-window": return "等待 ChatGPT 启动后显示"
        case "hidden-in-background": return "已隐藏 · 切回 ChatGPT 时自动显示"
        case "quota-unavailable": return "额度暂不可用 · " + detail
        default: return detail.isEmpty ? "后台状态：" + value : detail
        }
    }

    private static func saveConfiguration(enabled: Bool) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(
            withJSONObject: ["enabled": enabled, "position": "notch"], options: .sortedKeys
        )
        try data.write(to: configurationFile, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configurationFile.path)
    }

    private static func installAgent() throws {
        let plist: [String: Any] = [
            "Label": label,
            "ProgramArguments": [agent.path],
            "RunAtLoad": true,
            "KeepAlive": ["SuccessfulExit": false],
            "ThrottleInterval": 15,
            "ProcessType": "Background",
            "StandardOutPath": directory.appendingPathComponent("agent.out.log").path,
            "StandardErrorPath": directory.appendingPathComponent("agent.err.log").path
        ]
        try FileManager.default.createDirectory(
            at: agentPlist.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: agentPlist.path) { try verifyOwnedPlist() }
        _ = try? execute("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist, format: .xml, options: 0
        )
        try data.write(to: agentPlist, options: .atomic)
        _ = try execute("/bin/launchctl", ["bootstrap", "gui/\(getuid())", agentPlist.path])
    }

    private static func removeAgent() throws {
        guard FileManager.default.fileExists(atPath: agentPlist.path) else { return }
        try verifyOwnedPlist()
        _ = try? execute("/bin/launchctl", ["bootout", "gui/\(getuid())/\(label)"])
        try FileManager.default.removeItem(at: agentPlist)
    }

    private static func verifyOwnedPlist() throws {
        let data = try Data(contentsOf: agentPlist)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              plist["Label"] as? String == label,
              let args = plist["ProgramArguments"] as? [String],
              args.count == 1, args[0].hasSuffix("/HarborUsageCardAgent") else {
            throw CardError.message("发现不属于 CodexHarbor 的后台任务配置，已停止操作")
        }
    }

    @discardableResult
    private static func execute(_ path: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let bytes = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let content = String(decoding: bytes, as: UTF8.self)
        guard process.terminationStatus == 0 else {
            throw CardError.message(content.isEmpty ? "系统操作失败" : String(content.suffix(600)))
        }
        return content
    }

    enum CardError: LocalizedError {
        case message(String)
        var errorDescription: String? {
            if case .message(let content) = self { return content }
            return nil
        }
    }
}
