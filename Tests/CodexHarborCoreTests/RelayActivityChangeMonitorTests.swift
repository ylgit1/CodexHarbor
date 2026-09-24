import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Relay activity change monitor")
struct RelayActivityChangeMonitorTests {
    @Test("new Relay SQLite activity triggers immediately and unrelated files are ignored")
    func detectsRelayActivityOnly() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborRelayMonitor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CodexPaths(
            codexHome: root.appendingPathComponent(".codex", isDirectory: true),
            appSupport: root.appendingPathComponent("support", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)

        let store = RelayActivityStore(paths: paths)
        let profileID = UUID()
        let baseline = record(id: "baseline", profileID: profileID)
        try store.append(baseline, now: baseline.startedAt)

        let signal = DispatchSemaphore(value: 0)
        let monitor = RelayActivityChangeMonitor(paths: paths)
        monitor.start {
            signal.signal()
        }
        defer { monitor.stop() }

        Thread.sleep(forTimeInterval: 0.2)

        try Data("unrelated".utf8).write(
            to: paths.appSupport.appendingPathComponent("unrelated.tmp"),
            options: .atomic
        )
        #expect(signal.wait(timeout: .now() + 0.4) == .timedOut)

        let next = record(
            id: "next",
            profileID: profileID,
            startedAt: baseline.startedAt.addingTimeInterval(1)
        )
        try store.append(next, now: next.startedAt)

        #expect(signal.wait(timeout: .now() + 2) == .success)
    }

    private func record(
        id: String,
        profileID: UUID,
        startedAt: Date = Date()
    ) -> RelayRequestRecord {
        RelayRequestRecord(
            id: id,
            profileID: profileID,
            startedAt: startedAt,
            completedAt: startedAt.addingTimeInterval(0.1),
            durationMilliseconds: 100,
            succeeded: true,
            statusCode: 200,
            model: "test-model",
            upstreamProtocol: .responses,
            usage: RelayUsage(
                inputTokens: 10,
                outputTokens: 5,
                totalTokens: 15,
                billedTokens: 15,
                source: .providerBilling
            )
        )
    }
}
