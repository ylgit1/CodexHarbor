import CodexHarborCore
import Darwin
import Foundation

/// An explicit, one-at-a-time end-to-end proxy test.
/// Starts an isolated Xray listener, makes one HTTPS request through it,
/// then always terminates the child and deletes the temporary config.
/// Does not alter the active node or macOS system proxy.
enum HarborNodeLatencyTester {
    static func measure(node: HarborProxyNode, root: URL, ruleMode: Bool) async -> Int? {
        await Task.detached(priority: .userInitiated) {
            guard !Task.isCancelled else { return nil }
            return perform(node: node, root: root, ruleMode: ruleMode)
        }.value
    }

    private static func perform(node: HarborProxyNode, root: URL, ruleMode: Bool) -> Int? {
        let xray = root.appendingPathComponent("xray")
        guard FileManager.default.isExecutableFile(atPath: xray.path),
              let port = freePortPair() else { return nil }
        let configPath = root.appendingPathComponent("probe-\(UUID().uuidString).json")
        guard let data = try? HarborXrayConfig.make(node: node, httpPort: port, ruleMode: ruleMode),
              (try? data.write(to: configPath, options: .atomic)) != nil else { return nil }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
        defer { try? FileManager.default.removeItem(at: configPath) }

        let engine = Process()
        engine.executableURL = xray
        engine.currentDirectoryURL = root
        engine.arguments = ["run", "-config", configPath.path]
        engine.standardOutput = FileHandle.nullDevice
        engine.standardError = FileHandle.nullDevice
        do { try engine.run() } catch { return nil }
        defer {
            if engine.isRunning { engine.terminate() }
            engine.waitUntilExit()
        }

        // Xray needs a short startup window before the local HTTP listener binds.
        Thread.sleep(forTimeInterval: 0.30)
        guard engine.isRunning else { return nil }

        let targets = [
            "https://www.apple.com/library/test/success.html",
            "https://www.gstatic.com/generate_204"
        ]
        for url in targets {
            let curl = Process()
            let output = Pipe()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = [
                "-q", "--silent", "--fail", "--noproxy", "",
                "--proxy", "http://127.0.0.1:\(port)",
                "--connect-timeout", "2", "--max-time", "5",
                "--output", "/dev/null", "--write-out", "%{time_total}",
                url
            ]
            var environment = ProcessInfo.processInfo.environment
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                environment.removeValue(forKey: key)
            }
            curl.environment = environment
            curl.standardOutput = output
            curl.standardError = FileHandle.nullDevice
            do { try curl.run() } catch { continue }
            curl.waitUntilExit()
            let body = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if curl.terminationStatus == 0, let seconds = Double(body), seconds >= 0 {
                return max(1, Int((seconds * 1_000).rounded()))
            }
        }
        return nil
    }

    private static func freePortPair() -> Int? {
        for port in stride(from: 18200, through: 18480, by: 2)
            where isAvailable(port) && isAvailable(port + 1) {
            return port
        }
        return nil
    }

    private static func isAvailable(_ port: Int) -> Bool {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
    }
}
