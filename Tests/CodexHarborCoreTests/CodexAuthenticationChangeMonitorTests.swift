import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Codex authentication change monitor")
struct CodexAuthenticationChangeMonitorTests {
    @Test("atomic auth.json replacement triggers an immediate change event")
    func detectsAtomicReplacement() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexHarborAuthMonitor-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = CodexPaths(
            codexHome: root.appendingPathComponent(".codex", isDirectory: true),
            appSupport: root.appendingPathComponent("support", isDirectory: true)
        )
        try FileManager.default.createDirectory(at: paths.codexHome, withIntermediateDirectories: true)
        try Data("{\"token\":\"first\"}".utf8).write(to: paths.authURL, options: .atomic)

        let signal = DispatchSemaphore(value: 0)
        let monitor = CodexAuthenticationChangeMonitor(paths: paths)
        monitor.start {
            signal.signal()
        }
        defer { monitor.stop() }

        // start() installs vnode sources on its serial queue.
        Thread.sleep(forTimeInterval: 0.2)
        try Data("{\"token\":\"second\"}".utf8).write(to: paths.authURL, options: .atomic)

        #expect(signal.wait(timeout: .now() + 2) == .success)
    }
}
