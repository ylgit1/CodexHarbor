import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Incremental Codex token monitoring")
struct CodexTokenUsageMonitorTests {
    @Test("Existing daily rollout grows without rescanning historical usage")
    func detectsIncrementalChangesAndNewDailySessions() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborTokenMonitor-\(UUID().uuidString)", isDirectory: true)
        let paths = CodexPaths(
            codexHome: root.appendingPathComponent("codex", isDirectory: true),
            appSupport: root.appendingPathComponent("support", isDirectory: true)
        )
        defer { try? FileManager.default.removeItem(at: root) }

        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let components = utcCalendar.dateComponents([.year, .month, .day], from: Date())
        let folder = paths.sessionsURL.appendingPathComponent(
            String(format: "%04d/%02d/%02d",
                   components.year!, components.month!, components.day!),
            isDirectory: true
        )
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let firstURL = folder.appendingPathComponent("rollout-one.jsonl")
        try Data(record(turn: "first", total: 8).utf8).write(to: firstURL)

        let monitor = CodexTokenUsageMonitor(paths: paths)
        let first = await monitor.recentUsage()
        #expect(first.map(\.id) == ["thread/first"])
        #expect(await monitor.recentUsage() == first)

        let handle = try FileHandle(forWritingTo: firstURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(record(turn: "second", total: 13).utf8))
        try handle.close()

        let second = await monitor.recentUsage()
        #expect(Set(second.map(\.id)) == ["thread/first", "thread/second"])
        #expect(second.reduce(0) { $0 + $1.totalTokens } == 21)

        // A new file in today's folder must be discovered before the slower
        // historical 30-second scan, preserving live usage responsiveness.
        try Data(record(turn: "third", total: 5).utf8).write(
            to: folder.appendingPathComponent("rollout-two.jsonl")
        )
        let third = await monitor.recentUsage()
        #expect(Set(third.map(\.id)) == ["thread/first", "thread/second", "thread/third"])

        let restored = CodexTokenUsageMonitor(paths: paths)
        #expect(await restored.recentUsage() == third)
    }

    private func record(turn: String, total: Int) -> String {
        let timestamp = ISO8601DateFormatter().string(from: Date())
        return """
        {"timestamp":"\(timestamp)","type":"token_usage_record","payload":{"thread_id":"thread","turn_id":"\(turn)","usage":{"input_tokens":\(total),"output_tokens":0,"total_tokens":\(total)}}}
        """ + "\n"
    }
}
