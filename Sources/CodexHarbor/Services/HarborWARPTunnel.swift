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
    private let lease: UUID
    private let lock = NSLock()
    private var closed = false

    private init(profile: HarborWARPProfile, httpPort: Int, engine: Process, directory: URL,
                 cancellation: HarborLatencyCancellation, parent: HarborLatencyCancellation,
                 parentObserver: UUID, engineObserver: UUID, lease: UUID) {
        self.profile = profile
        self.httpPort = httpPort
        self.engine = engine
        self.directory = directory
        self.cancellation = cancellation
        self.parent = parent
        self.parentObserver = parentObserver
        self.engineObserver = engineObserver
        self.lease = lease
    }

    func close() async {
        guard lock.withLock({
            if closed { return false }
            closed = true
            return true
        }) else { return }
        parent.removeObserver(parentObserver)
        cancellation.removeObserver(engineObserver)
        cancellation.cancel()
        if await HarborProxyCommand.stop(engine) {
            try? FileManager.default.removeItem(at: directory)
            HarborNodeLatencyTester.releasePortPair(httpPort)
            await HarborProbeBudget.engines.release(lease)
        }
    }

    static func prepare(account: HarborWARPAccount, preferred: HarborWARPEndpoint?,
                        root: URL, cancellation: HarborLatencyCancellation) async throws -> HarborWARPTunnel {
        try account.validate()
        let primary = HarborWARPEndpoint.candidates(preferred: preferred)
        // A lost QUIC handshake is common on filtered networks. Give each
        // QUIC path three bounded chances without enrolling another identity.
        let endpoints = primary
        let deadline = ContinuousClock.now + .seconds(32)
        let attempts = HarborLatencyCancellation()
        let observer = cancellation.observe { attempts.cancel() }
        defer { if let observer { cancellation.removeObserver(observer) } }
        let timer = Task {
            do { try await Task.sleep(until: deadline, clock: .continuous) } catch { return }
            attempts.cancel()
        }
        defer { timer.cancel() }
        let result = await withTaskGroup(of: HarborWARPTunnel?.self) { group in
            var next = 0
            var winner: HarborWARPTunnel?
            func enqueue(_ endpoint: HarborWARPEndpoint) {
                group.addTask {
                    await connect(profile: HarborWARPProfile(account: account, endpoint: endpoint),
                                  root: root, parent: attempts)
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
                    await tunnel?.close()
                }
                if winner == nil, next < endpoints.count,
                   !attempts.isCancelled, !Task.isCancelled {
                    enqueue(endpoints[next]); next += 1
                }
            }
            return winner
        }
        guard let result, !cancellation.isCancelled, !Task.isCancelled else {
            await result?.close()
            if cancellation.isCancelled || Task.isCancelled { throw CancellationError() }
            throw HarborProxyError.invalid("独立通道暂时无法连接，已尝试 TCP 与 QUIC；请稍后重新筛选")
        }
        return result
    }

    private static func connect(profile: HarborWARPProfile, root: URL,
                                parent: HarborLatencyCancellation) async -> HarborWARPTunnel? {
        let cancellation = HarborLatencyCancellation()
        guard let parentObserver = parent.observe({ cancellation.cancel() }) else { return nil }
        guard let lease = await HarborProbeBudget.engines.acquire(cancellation) else {
            parent.removeObserver(parentObserver)
            return nil
        }
        return await withTaskCancellationHandler {
            let released = HarborLatencyCancellation()
            let tunnel = await Task.detached(priority: .utility) { () -> HarborWARPTunnel? in
                guard !cancellation.isCancelled,
                      let port = HarborNodeLatencyTester.reservePortPair() else {
                    released.cancel()
                    return nil
                }
                let directory = root.appendingPathComponent("warp-probe-\(UUID().uuidString)", isDirectory: true)
                let file = directory.appendingPathComponent("config.json")
                let engine = Process()
                var keep = false
                var observer: UUID?
                defer {
                    if !keep {
                        if let observer { cancellation.removeObserver(observer) }
                        if HarborProxyCommand.stopBlocking(engine) {
                            try? FileManager.default.removeItem(at: directory)
                            HarborNodeLatencyTester.releasePortPair(port)
                            released.cancel()
                        }
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
                        parentObserver: parentObserver, engineObserver: observer, lease: lease)
                } catch { return nil }
            }.value
            guard let tunnel else {
                parent.removeObserver(parentObserver)
                if released.isCancelled { await HarborProbeBudget.engines.release(lease) }
                return nil
            }
            guard await tunnel.verify(), !Task.isCancelled, !cancellation.isCancelled else {
                await tunnel.close()
                return nil
            }
            return tunnel
        } onCancel: {
            cancellation.cancel()
        }
    }

    private func verify() async -> Bool {
        guard !cancellation.isCancelled,
              let lease = await HarborProbeBudget.requests.acquire(cancellation) else { return false }
        let result = await verifyEndpoints()
        await HarborProbeBudget.requests.release(lease)
        return result
    }

    private func verifyEndpoints() async -> Bool {
        let port = httpPort
        let task = Task { () -> Bool in
        do {
            var trace = URLRequest(url: URL(string: "https://www.cloudflare.com/cdn-cgi/trace")!)
            trace.timeoutInterval = 6
            let (data, _) = try await HarborProxyHTTPBody.data(for: trace,
                configuration: HarborProxyHTTP.configuration(httpPort: port), limit: 4_096,
                timeout: 6, status: 200..<201)
            guard HarborProxyHTTP.verifiesWARPTrace(data),
                  !cancellation.isCancelled else { return false }
            // A successful WARP trace alone does not prove general Internet
            // access. Also require a non-Cloudflare HTTPS request.
            var check = URLRequest(url: URL(string: "https://www.gstatic.com/generate_204")!)
            check.timeoutInterval = 6
            let (body, _) = try await HarborProxyHTTPBody.data(for: check,
                configuration: HarborProxyHTTP.configuration(httpPort: port), limit: 64,
                timeout: 6, status: 204..<205)
            return body.isEmpty && !cancellation.isCancelled
        } catch { return false }
        }
        let observer = cancellation.observe { task.cancel() }
        defer { if let observer { cancellation.removeObserver(observer) } }
        return await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
    }

    /// Recover only our recorded, orphaned probe cores. Normal live probes
    /// belong to this process and are left alone.
    static func cleanupOrphans(root: URL) async {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix("warp-probe-") {
            let pidFile = directory.appendingPathComponent("pid")
            guard let text = try? String(contentsOf: pidFile, encoding: .utf8),
                  let pid = Int32(text), pid > 0 else { continue }
            if Darwin.kill(pid, 0) == 0 {
                do {
                    let output = try await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
                        arguments: ["-ww", "-p", String(pid), "-o", "ppid=", "-o", "command="], timeout: 1)
                    let line = String(decoding: output.data, as: UTF8.self)
                    let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    guard fields.count == 2, fields[0] == "1",
                          fields[1].contains(root.appendingPathComponent("mihomo").path),
                          fields[1].contains("-d " + directory.path),
                          fields[1].contains("-f " + directory.appendingPathComponent("config.json").path) else { continue }
                    _ = Darwin.kill(pid, SIGTERM)
                    try? await Task.sleep(for: .milliseconds(250))
                } catch { continue }
                if Darwin.kill(pid, 0) == 0 { continue }
            }
            try? fm.removeItem(at: directory)
        }
    }
}
