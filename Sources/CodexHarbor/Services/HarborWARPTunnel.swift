import CodexHarborCore
import Darwin
import Foundation

/// A short-lived, loopback-only WARP proxy used to fetch and classify VPN Gate.
/// Actual node tests and connections embed the same WARP profile in Mihomo;
/// they never depend on this temporary listener surviving.
final class HarborWARPTunnel: @unchecked Sendable {
    let profile: HarborWARPProfile
    let httpPort: Int
    var socksPort: Int { httpPort + 1 }
    private let engine: Process
    private let directory: URL
    private let cancellation: HarborLatencyCancellation
    private let parent: HarborLatencyCancellation
    private let parentObserver: UUID
    private let engineObserver: UUID
    private let lock = NSLock()
    private var closed = false

    private init(profile: HarborWARPProfile, httpPort: Int, engine: Process, directory: URL,
                 cancellation: HarborLatencyCancellation, parent: HarborLatencyCancellation,
                 parentObserver: UUID, engineObserver: UUID) {
        self.profile = profile
        self.httpPort = httpPort
        self.engine = engine
        self.directory = directory
        self.cancellation = cancellation
        self.parent = parent
        self.parentObserver = parentObserver
        self.engineObserver = engineObserver
    }

    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true
        lock.unlock()
        parent.removeObserver(parentObserver)
        cancellation.removeObserver(engineObserver)
        cancellation.cancel()
        let engine = engine, directory = directory, port = httpPort
        Task.detached(priority: .utility) {
            HarborProbeProcessReaper.stop(engine)
            try? FileManager.default.removeItem(at: directory)
            HarborNodeLatencyTester.releasePortPair(port)
        }
    }

    deinit { close() }

    static func prepare(account: HarborWARPAccount, preferred: HarborWARPEndpoint?,
                        root: URL, cancellation: HarborLatencyCancellation) async throws -> HarborWARPTunnel {
        try account.validate()
        let primary = HarborWARPEndpoint.candidates(preferred: preferred)
        // A lost QUIC handshake is common on filtered networks. Give each
        // QUIC path three bounded chances without enrolling another identity.
        let retry = primary.filter { $0.transport == .h3 }
        let endpoints = primary + retry + retry
        let result = await withTaskGroup(of: HarborWARPTunnel?.self) { group in
            var next = 0
            var winner: HarborWARPTunnel?
            func enqueue(_ endpoint: HarborWARPEndpoint) {
                group.addTask {
                    await connect(profile: HarborWARPProfile(account: account, endpoint: endpoint),
                                  root: root, parent: cancellation)
                }
            }
            // Keep the previous success first while racing one alternative;
            // a stale cached path must not serialize the entire discovery.
            let initial = 2
            for _ in 0..<min(initial, endpoints.count) {
                enqueue(endpoints[next]); next += 1
            }
            while let tunnel = await group.next() {
                if winner == nil, let tunnel, !cancellation.isCancelled, !Task.isCancelled {
                    winner = tunnel
                    group.cancelAll()
                } else {
                    tunnel?.close()
                }
                if winner == nil, next < endpoints.count,
                   !cancellation.isCancelled, !Task.isCancelled {
                    enqueue(endpoints[next]); next += 1
                }
            }
            return winner
        }
        guard let result, !cancellation.isCancelled, !Task.isCancelled else {
            result?.close()
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            throw HarborProxyError.invalid("独立通道暂时无法连接，已尝试 TCP 与 QUIC；请稍后重新筛选")
        }
        return result
    }

    private static func connect(profile: HarborWARPProfile, root: URL,
                                parent: HarborLatencyCancellation) async -> HarborWARPTunnel? {
        let cancellation = HarborLatencyCancellation()
        guard let parentObserver = parent.observe({ cancellation.cancel() }) else { return nil }
        return await withTaskCancellationHandler {
            let tunnel = await Task.detached(priority: .utility) { () -> HarborWARPTunnel? in
                guard !cancellation.isCancelled,
                      let port = HarborNodeLatencyTester.reservePortPair() else { return nil }
                let directory = root.appendingPathComponent("warp-probe-\(UUID().uuidString)", isDirectory: true)
                let file = directory.appendingPathComponent("config.json")
                let engine = Process()
                var keep = false
                var observer: UUID?
                defer {
                    if !keep {
                        if let observer { cancellation.removeObserver(observer) }
                        HarborProbeProcessReaper.stop(engine)
                        try? FileManager.default.removeItem(at: directory)
                        HarborNodeLatencyTester.releasePortPair(port)
                    }
                }
                do {
                    try FileManager.default.createDirectory(
                        at: directory, withIntermediateDirectories: true,
                        attributes: [.posixPermissions: 0o700])
                    try HarborWARPConfig.make(profile: profile, httpPort: port).write(to: file, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
                    engine.executableURL = root.appendingPathComponent("mihomo")
                    engine.currentDirectoryURL = directory
                    engine.arguments = ["-d", directory.path, "-f", file.path]
                    engine.standardOutput = FileHandle.nullDevice
                    engine.standardError = FileHandle.nullDevice
                    observer = cancellation.observe { [weak engine] in
                        if let engine { HarborProbeProcessReaper.requestStop(engine) }
                    }
                    guard let observer, !cancellation.isCancelled else { return nil }
                    try engine.run()
                    let pidFile = directory.appendingPathComponent("pid")
                    try Data(String(engine.processIdentifier).utf8).write(to: pidFile, options: .atomic)
                    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: pidFile.path)
                    guard HarborNodeLatencyTester.waitUntilListening(
                        port: port, process: engine, cancellation: cancellation),
                          HarborNodeLatencyTester.waitUntilListening(
                        port: port + 1, process: engine, cancellation: cancellation),
                          !cancellation.isCancelled else { return nil }
                    keep = true
                    return HarborWARPTunnel(
                        profile: profile, httpPort: port, engine: engine, directory: directory,
                        cancellation: cancellation, parent: parent,
                        parentObserver: parentObserver, engineObserver: observer)
                } catch { return nil }
            }.value
            guard let tunnel else { parent.removeObserver(parentObserver); return nil }
            guard await tunnel.verify(), !Task.isCancelled, !cancellation.isCancelled else {
                tunnel.close()
                return nil
            }
            return tunnel
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func verify() async -> Bool {
        guard !cancellation.isCancelled else { return false }
        let session = URLSession(configuration: HarborProxyHTTP.configuration(httpPort: httpPort))
        let observer = cancellation.observe { session.invalidateAndCancel() }
        defer {
            if let observer { cancellation.removeObserver(observer) }
            session.invalidateAndCancel()
        }
        do {
            var trace = URLRequest(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
            trace.timeoutInterval = 6
            let (data, response) = try await session.data(for: trace)
            guard (response as? HTTPURLResponse)?.statusCode == 200,
                  HarborProxyHTTP.verifiesWARPTrace(data),
                  !cancellation.isCancelled else { return false }
            // A successful WARP trace alone does not prove general Internet
            // access. Also require a non-Cloudflare HTTPS request.
            var check = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!)
            check.timeoutInterval = 6
            let (body, result) = try await session.data(for: check)
            return (result as? HTTPURLResponse)?.statusCode == 204
                && body.isEmpty && !cancellation.isCancelled
        } catch { return false }
    }

    /// Recover only our recorded, orphaned probe cores. Normal live probes
    /// belong to this process and are left alone.
    static func cleanupOrphans(root: URL) {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix("warp-probe-") {
            let pidFile = directory.appendingPathComponent("pid")
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text), pid > 0 else { continue }
            if Darwin.kill(pid, 0) == 0 {
                let ps = Process(), output = Pipe()
                ps.executableURL = URL(fileURLWithPath: "/bin/ps")
                ps.arguments = ["-ww", "-p", String(pid), "-o", "ppid=", "-o", "command="]
                ps.standardOutput = output
                ps.standardError = FileHandle.nullDevice
                do {
                    try ps.run()
                    ps.waitUntilExit()
                    let line = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                    let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    guard fields.count == 2, fields[0] == "1",
                          fields[1].contains(root.appendingPathComponent("mihomo").path),
                          fields[1].contains("-d " + directory.path),
                          fields[1].contains("-f " + directory.appendingPathComponent("config.json").path) else { continue }
                    _ = Darwin.kill(pid, SIGTERM)
                } catch { continue }
                // Leave the record for a later retry if the old process has
                // not exited. Do not delete credentials underneath a live core.
                continue
            }
            try? fm.removeItem(at: directory)
        }
    }
}
