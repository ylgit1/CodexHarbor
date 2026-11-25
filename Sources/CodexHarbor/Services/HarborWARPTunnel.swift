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
    private let lease: UUID
    private let lock = NSLock()
    private var closed = false
    var isUsable: Bool { lock.withLock { !closed && engine.isRunning && !cancellation.isCancelled } }

    private init(profile: HarborWARPProfile, httpPort: Int, engine: Process, directory: URL,
                 cancellation: HarborLatencyCancellation, parent: HarborLatencyCancellation,
                 parentObserver: UUID, lease: UUID) {
        self.profile = profile
        self.httpPort = httpPort
        self.engine = engine
        self.directory = directory
        self.cancellation = cancellation
        self.parent = parent
        self.parentObserver = parentObserver
        self.lease = lease
    }

    struct PromotedRuntime: Sendable {
        let process: Process
        let directory: URL
        let port: Int
        let profile: HarborWARPProfile
    }

    /// Transfer the exact verified engine out of the discovery budget.
    /// Detach discovery cancellation before releasing its lease; the formal
    /// supervisor assumes the port reservation and process cleanup.
    func promote() async -> PromotedRuntime? {
        guard lock.withLock({
            if closed || !engine.isRunning || cancellation.isCancelled { return false }
            closed = true
            return true
        }) else { return nil }
        parent.removeObserver(parentObserver)
        await HarborProbeBudget.engines.release(lease)
        return PromotedRuntime(process: engine, directory: directory, port: httpPort, profile: profile)
    }

    func close() async {
        guard lock.withLock({
            if closed { return false }
            closed = true
            return true
        }) else { return }
        parent.removeObserver(parentObserver)
        cancellation.cancel()
        await HarborProbeRetirementQueue.shared.retire(.init(
            process: engine, config: directory.appendingPathComponent("config.json"),
            directory: directory, port: httpPort, lease: lease))
    }

    static func prepare(account: HarborWARPAccount, preferred: HarborWARPEndpoint?,
                        root: URL, cancellation: HarborLatencyCancellation) async throws -> HarborWARPTunnel {
        try account.validate()
        let endpoints = HarborWARPEndpoint.discoveryAttempts(preferred: preferred)
        // Keep the bounded resource pool, but allow the original retry sweep.
        let deadline = ContinuousClock.now + .seconds(HarborWARPEndpoint.discoveryDeadlineSeconds)
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
        guard !cancellation.isCancelled, let port = HarborNodeLatencyTester.reservePortPair() else {
            parent.removeObserver(parentObserver)
            await HarborProbeBudget.engines.release(lease)
            return nil
        }
        let directory = root.appendingPathComponent("warp-probe-\(UUID().uuidString)", isDirectory: true)
        let file = directory.appendingPathComponent("config.json")
        let engine = Process()
        return await withTaskCancellationHandler {
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
                try HarborProbeFiles.write(HarborWARPConfig.make(profile: profile, httpPort: port), to: file)
                engine.executableURL = root.appendingPathComponent("mihomo")
                engine.currentDirectoryURL = directory
                engine.arguments = ["-d", directory.path, "-f", file.path]
                engine.standardInput = FileHandle.nullDevice
                engine.standardOutput = FileHandle.nullDevice
                engine.standardError = FileHandle.nullDevice
                guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                try engine.run()
                let identity = HarborProcessIdentity.capture(pid: engine.processIdentifier)
                let record = identity.flatMap { try? JSONEncoder().encode($0) }
                    ?? Data(String(engine.processIdentifier).utf8)
                try HarborProbeFiles.write(record, to: directory.appendingPathComponent("pid"))
                guard await HarborNodeLatencyTester.awaitListeningPair(port: port, process: engine,
                                                                       cancellation: cancellation),
                      !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
                let tunnel = HarborWARPTunnel(profile: profile, httpPort: port, engine: engine,
                    directory: directory, cancellation: cancellation, parent: parent,
                    parentObserver: parentObserver, lease: lease)
                guard await tunnel.verify(), !Task.isCancelled, !cancellation.isCancelled else {
                    await tunnel.close()
                    return nil
                }
                return tunnel
            } catch {
                parent.removeObserver(parentObserver)
                cancellation.cancel()
                await HarborProbeRetirementQueue.shared.retire(.init(
                    process: engine, config: file, directory: directory, port: port, lease: lease))
                return nil
            }
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
    static func cleanupOrphans(root: URL, protectedPaths: Set<String> = []) async {
        let fm = FileManager.default
        guard let directories = try? fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) else { return }
        for directory in directories where directory.lastPathComponent.hasPrefix("warp-probe-") {
            guard !protectedPaths.contains(directory.path) else { continue }
            let pidFile = directory.appendingPathComponent("pid")
            guard let data = try? Data(contentsOf: pidFile), data.count <= 16_384 else { continue }
            let recorded = try? JSONDecoder().decode(HarborProcessIdentity.self, from: data)
            guard let pid = recorded?.pid ?? Int32(String(decoding: data, as: UTF8.self)), pid > 1 else { continue }
            if Darwin.kill(pid, 0) == 0 {
                guard let identity = HarborProcessIdentity.capture(pid: pid),
                      recorded == nil || recorded == identity else { continue }
                do {
                    let output = try await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
                        arguments: ["-ww", "-p", String(pid), "-o", "ppid=", "-o", "command="], timeout: 1)
                    let line = String(decoding: output.data, as: UTF8.self)
                    let fields = line.split(maxSplits: 1, whereSeparator: \.isWhitespace)
                    let expected = "\(root.appendingPathComponent("mihomo").path) -d \(directory.path) -f \(directory.appendingPathComponent("config.json").path)"
                    guard fields.count == 2, fields[0] == "1",
                          fields[1].trimmingCharacters(in: .whitespacesAndNewlines) == expected,
                          identity.isCurrent else { continue }
                    _ = Darwin.kill(pid, SIGTERM)
                    try? await Task.sleep(for: .milliseconds(250))
                } catch { continue }
                if Darwin.kill(pid, 0) == 0 { continue }
            }
            try? fm.removeItem(at: directory)
        }
    }
}
