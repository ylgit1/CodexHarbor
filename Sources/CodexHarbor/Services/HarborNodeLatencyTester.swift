import CodexHarborCore
import Darwin
import Foundation

/// Shared cancellation for a bounded batch of end-to-end proxy probes.
final class HarborLatencyCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var callbacks: [UUID: @Sendable () -> Void] = [:]

    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func cancel() {
        lock.lock()
        if cancelled {
            lock.unlock()
            return
        }
        cancelled = true
        let handlers = Array(callbacks.values)
        callbacks.removeAll()
        lock.unlock()
        handlers.forEach { $0() }
    }

    func observe(_ callback: @escaping @Sendable () -> Void) -> UUID? {
        lock.lock()
        if cancelled {
            lock.unlock()
            callback()
            return nil
        }
        let id = UUID()
        callbacks[id] = callback
        lock.unlock()
        return id
    }

    func removeObserver(_ id: UUID) {
        lock.lock()
        callbacks.removeValue(forKey: id)
        lock.unlock()
    }
}

/// Safe summaries of probe failures, not raw Xray stderr or credentials.
struct HarborNodeDelayReport: Sendable {
    let milliseconds: Int?
    let failure: String?
    static func failed(_ description: String) -> Self {
        Self(milliseconds: nil, failure: description)
    }
    static func succeeded(_ value: Int) -> Self {
        Self(milliseconds: value, failure: nil)
    }
}

/// Whether a node's isolated proxy actually started matters separately from
/// a remote IP/GeoIP failure. Never report a failed startup as a network test.
struct HarborNodeExitGeoReport: Sendable {
    let location: HarborProxyIPLocation?
    let failure: String?
    let started: Bool

    static func probed(_ location: HarborProxyIPLocation?) -> Self {
        Self(location: location,
             failure: location == nil ? "未能通过该节点获取出口 IP"
                : (location?.verifiedCountryCode == nil ? "已取得出口 IP，地区服务未返回结果" : nil),
             started: true)
    }

    static func notStarted(_ reason: String) -> Self {
        Self(location: nil, failure: reason, started: false)
    }
}


enum HarborProbeProcessReaper {
    static func requestStop(_ process: Process) {
        Task { await HarborProxyCommand.stop(process) }
    }

    static func stop(_ process: Process) {
        HarborProxyCommand.stopBlocking(process)
    }
}

final class HarborRealDelayBatch: @unchecked Sendable {
    private let engine: Process
    private let configPath: URL
    private let basePort: Int
    private let portsByNodeID: [String: Int]
    private let cancellation: HarborLatencyCancellation
    private let lease: UUID
    var hasRunningEngine: Bool { engine.isRunning }

    init(engine: Process, config: URL, basePort: Int, nodes: [HarborProxyNode],
         cancellation: HarborLatencyCancellation, lease: UUID) {
        self.engine = engine
        configPath = config
        self.basePort = basePort
        portsByNodeID = Dictionary(uniqueKeysWithValues: nodes.enumerated().map {
            ($0.element.id, basePort + $0.offset)
        })
        self.cancellation = cancellation
        self.lease = lease
    }

    func close() async {
        if await HarborProxyCommand.stop(engine) {
            HarborProbeFiles.remove(configPath)
            HarborNodeLatencyTester.releasePortRange(basePort, count: portsByNodeID.count)
            await HarborProbeBudget.engines.release(lease)
        }
    }

    func measure(node: HarborProxyNode) async -> HarborNodeDelayReport {
        guard let port = portsByNodeID[node.id], engine.isRunning else {
            return .failed("测速内核未启动或已退出")
        }
        return await HarborNodeLatencyTester.measureHTTP(httpPort: port, cancellation: cancellation)
    }

    func exitLocationReport(node: HarborProxyNode) async -> HarborNodeExitGeoReport {
        guard let port = portsByNodeID[node.id], !cancellation.isCancelled,
              !Task.isCancelled, engine.isRunning else {
            return .notStarted("地区检测内核未启动或已退出")
        }
        return .probed(await HarborNodeGeoIPResolver.exitLocation(socksPort: port, cancellation: cancellation))
    }
}

enum HarborNodeLatencyTester {
    private static let portLock = NSLock()
    private nonisolated(unsafe) static var reservedPorts: Set<Int> = []
    static let openVPNVerificationURL = URL(string: "https://www.gstatic.com/generate_204")!

    static let realPingURL: URL = {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN/guiConfigs/guiNConfig.json")
        let data = (try? FileHandle(forReadingFrom: path)).flatMap { handle -> Data? in
            defer { try? handle.close() }
            return try? handle.read(upToCount: 262_144)
        }
        return HarborProxyRealPingTarget.resolve(v2rayNConfigurationData: data)
    }()

    static func verificationURL(openVPN: Bool) -> URL {
        openVPN ? openVPNVerificationURL : realPingURL
    }

    static func checkActiveHTTP(port: Int, cancellation: HarborLatencyCancellation? = nil) async -> Bool {
        await measureHTTP(httpPort: port, cancellation: cancellation ?? HarborLatencyCancellation()).milliseconds != nil
    }

    static func measureHTTP(httpPort: Int, cancellation: HarborLatencyCancellation) async -> HarborNodeDelayReport {
        guard (1...65_535).contains(httpPort), !cancellation.isCancelled, !Task.isCancelled,
              let lease = await HarborProbeBudget.requests.acquire(cancellation) else {
            return .failed("测试已取消")
        }
        let report = await performHTTPMeasurement(port: httpPort, cancellation: cancellation)
        await HarborProbeBudget.requests.release(lease)
        return report
    }

    private static func performHTTPMeasurement(port: Int, cancellation: HarborLatencyCancellation) async -> HarborNodeDelayReport {
        let target = realPingURL
        let deadline = ContinuousClock.now + .seconds(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        var timings: [Int] = []
        for index in 0..<HarborProxyLatencyPolicy.realPingRequestCount {
            guard !cancellation.isCancelled, !Task.isCancelled else { return .failed("测试已取消") }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .failed("真实测速超时") }
            let parts = remaining.components
            let timeout = Double(parts.seconds) + Double(parts.attoseconds) / 1e18
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = timeout
            let started = ContinuousClock.now
            let load = Task {
                try await HarborProxyHTTPBody.data(for: request,
                    configuration: HarborProxyHTTP.configuration(httpPort: port),
                    limit: 16_384, timeout: timeout)
            }
            let observer = cancellation.observe { load.cancel() }
            defer { if let observer { cancellation.removeObserver(observer) } }
            do {
                let (_, response) = try await withTaskCancellationHandler {
                    try await load.value
                } onCancel: {
                    load.cancel()
                }
                if target.path == "/generate_204" && response.statusCode != 204 {
                    return .failed("测速站点未返回预期的 HTTP 204")
                }
            } catch {
                if cancellation.isCancelled || Task.isCancelled { return .failed("测试已取消") }
                if (error as? URLError)?.code == .timedOut || ContinuousClock.now >= deadline {
                    return .failed("真实测速超时")
                }
                if error is HarborProxyError { return .failed(error.localizedDescription) }
                return .failed("测速地址连接、TLS 或 HTTP 请求失败")
            }
            let elapsed = started.duration(to: .now).components
            timings.append(max(1, Int(elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000)))
            if index + 1 < HarborProxyLatencyPolicy.realPingRequestCount {
                do { try await Task.sleep(for: .milliseconds(HarborProxyLatencyPolicy.realPingPauseMilliseconds)) }
                catch { return .failed("测试已取消") }
            }
        }
        guard !cancellation.isCancelled, let fastest = timings.min() else { return .failed("测试已取消") }
        return .succeeded(fastest)
    }

    static func startRealBatch(nodes: [HarborProxyNode], root: URL,
                               cancellation: HarborLatencyCancellation) async -> HarborRealDelayBatch? {
        guard !nodes.isEmpty, Set(nodes.map(\.id)).count == nodes.count,
              let lease = await HarborProbeBudget.engines.acquire(cancellation) else { return nil }
        guard !cancellation.isCancelled, let basePort = reservePortRange(nodes.count) else {
            await HarborProbeBudget.engines.release(lease)
            return nil
        }
        let config = root.appendingPathComponent("probe-batch-\(UUID().uuidString).json")
        let engine = Process()
        do {
            let data = try HarborXrayConfig.makeRealPingBatch(nodes: nodes, basePort: basePort)
            try HarborProbeFiles.write(data, to: config)
            engine.executableURL = root.appendingPathComponent("xray")
            engine.currentDirectoryURL = root
            engine.arguments = ["run", "-config", config.path]
            engine.standardInput = FileHandle.nullDevice
            engine.standardOutput = FileHandle.nullDevice
            engine.standardError = FileHandle.nullDevice
            guard !cancellation.isCancelled else { throw CancellationError() }
            try engine.run()
            HarborProbeFiles.record(engine, config: config)
            guard await awaitListening(port: basePort, process: engine, cancellation: cancellation),
                  await awaitListening(port: basePort + nodes.count - 1, process: engine, cancellation: cancellation) else {
                throw HarborProxyError.invalid("测速端口未就绪")
            }
            return HarborRealDelayBatch(engine: engine, config: config, basePort: basePort,
                                        nodes: nodes, cancellation: cancellation, lease: lease)
        } catch {
            if await HarborProxyCommand.stop(engine) {
                HarborProbeFiles.remove(config)
                releasePortRange(basePort, count: nodes.count)
                await HarborProbeBudget.engines.release(lease)
            }
            return nil
        }
    }

    static func probeExitLocation(
        node: HarborProxyNode, root: URL, cancellation: HarborLatencyCancellation,
        batch: HarborRealDelayBatch? = nil
    ) async -> HarborNodeExitGeoReport {
        if let batch {
            let report = await batch.exitLocationReport(node: node)
            if report.started { return report }
        }
        guard let isolated = await startRealBatch(nodes: [node], root: root, cancellation: cancellation) else {
            return .notStarted("节点检测内核未启动，请检查配置或端口")
        }
        let report = await isolated.exitLocationReport(node: node)
        await isolated.close()
        return report
    }

    static func measure(node: HarborProxyNode, root: URL,
                        cancellation: HarborLatencyCancellation) async -> HarborNodeDelayReport {
        guard let batch = await startRealBatch(nodes: [node], root: root, cancellation: cancellation) else {
            return .failed("节点配置无效或测速内核未启动")
        }
        let report = await batch.measure(node: node)
        await batch.close()
        return report
    }

    private static func reservePortRange(_ count: Int) -> Int? {
        guard (1...HarborProxyLatencyPolicy.realPingBatchSize).contains(count) else { return nil }
        portLock.lock()
        defer { portLock.unlock() }
        for base in 18200...(19400 - count) {
            let range = base..<(base + count)
            if range.allSatisfy({ !reservedPorts.contains($0) && isAvailable($0) }) {
                reservedPorts.formUnion(range)
                return base
            }
        }
        return nil
    }

    fileprivate static func releasePortRange(_ base: Int, count: Int) {
        portLock.lock()
        reservedPorts.subtract(base..<(base + count))
        portLock.unlock()
    }

    static func reservePortPair() -> Int? { reservePortRange(2) }

    static func releasePortPair(_ port: Int) { releasePortRange(port, count: 2) }

    static func awaitListening(port: Int, process: Process, cancellation: HarborLatencyCancellation) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(HarborProxyLatencyPolicy.listenerStartupTimeoutMilliseconds)
        while process.isRunning, !cancellation.isCancelled, !Task.isCancelled, ContinuousClock.now < deadline {
            if canConnect(port) { return true }
            do { try await Task.sleep(for: .milliseconds(40)) } catch { return false }
        }
        return false
    }

    static func waitUntilListening(port: Int, process: Process, cancellation: HarborLatencyCancellation) -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(HarborProxyLatencyPolicy.listenerStartupTimeoutMilliseconds)
        while process.isRunning, !cancellation.isCancelled, ContinuousClock.now < deadline {
            if canConnect(port) { return true }
            Thread.sleep(forTimeInterval: 0.04)
        }
        return false
    }

    static func canConnect(_ port: Int) -> Bool { HarborLoopbackTCP.isListening(port) }

    /// Runtime startup and preflight check both listeners against one bounded
    /// deadline rather than a fixed number of scheduling-dependent iterations.
    static func awaitListeningPair(port: Int, process: Process,
                                   cancellation: HarborLatencyCancellation?) async -> Bool {
        let deadline = ContinuousClock.now + .milliseconds(
            HarborProxyLatencyPolicy.runtimeListenerStartupTimeoutMilliseconds)
        while process.isRunning, cancellation?.isCancelled != true,
              !Task.isCancelled, ContinuousClock.now < deadline {
            if canConnect(port), canConnect(port + 1), process.isRunning { return true }
            do { try await Task.sleep(for: .milliseconds(75)) } catch { return false }
        }
        return false
    }

    private static func isAvailable(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let descriptor = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { Darwin.close(descriptor) }
        guard fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let length = socklen_t(MemoryLayout<sockaddr_in>.size)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { pointer in
                return Darwin.bind(descriptor, pointer, length) == 0
            }
        }
    }
}

enum HarborMihomoLatencyTester {
    static func checkActiveSOCKS(port: Int, cancellation: HarborLatencyCancellation? = nil) async -> Bool {
        await warmupAndMeasure(socksPort: port, cancellation: cancellation ?? HarborLatencyCancellation(),
                               diagnostics: nil, seconds: 28).milliseconds != nil
    }

    static func underlayReady(socksPort: Int, cancellation: HarborLatencyCancellation) async -> Bool {
        let target = HarborNodeLatencyTester.openVPNVerificationURL.absoluteString
        if let result = await curlRequest(url: target, socksPort: socksPort,
                                         timeout: 4, cancellation: cancellation),
           result.exitCode == 0, result.status == 204 { return true }
        let fallback = await curlRequest(url: "https://example.com", socksPort: socksPort,
                                         timeout: 4, cancellation: cancellation)
        return fallback?.succeeded == true
    }

    static func measure(node: HarborProxyNode, root: URL,
                        cancellation: HarborLatencyCancellation, underlaySocksPort: Int? = nil,
                        warpProfile: HarborWARPProfile? = nil, seconds: Int = 28) async -> HarborNodeDelayReport {
        await withProxy(node: node, root: root, cancellation: cancellation,
                        underlaySocksPort: underlaySocksPort, warpProfile: warpProfile) { socksPort, diagnostics in
            await warmupAndMeasure(socksPort: socksPort, cancellation: cancellation, diagnostics: diagnostics, seconds: seconds)
        } ?? .failed(cancellation.isCancelled ? "测试已取消" : "Mihomo/OpenVPN 未能启动")
    }

    static func websiteReport(socksPort: Int, cancellation: HarborLatencyCancellation) async -> String {
        async let youtube = curlRequest(url: "https://www.youtube.com/", socksPort: socksPort,
                                        timeout: 8, cancellation: cancellation, follow: true)
        async let chatgpt = curlRequest(url: "https://chatgpt.com/", socksPort: socksPort,
                                        timeout: 8, cancellation: cancellation, follow: true)
        let (video, chat) = await (youtube, chatgpt)
        func label(_ name: String, _ result: CurlResult?) -> String {
            guard let result else { return "\(name) 请求未完成" }
            if result.succeeded { return "\(name) 首页响应 (HTTP \(result.status))" }
            if result.exitCode == 28 { return "\(name) 请求超时" }
            if result.status != 0 { return "\(name) HTTP \(result.status)" }
            return "\(name) HTTPS 连接失败"
        }
        return label("YouTube", video) + "；" + label("ChatGPT", chat) + "。仅检查首页响应。"
    }

    static func exitLocationReport(
        node: HarborProxyNode, root: URL, cancellation: HarborLatencyCancellation,
        underlaySocksPort: Int? = nil, warpProfile: HarborWARPProfile? = nil
    ) async -> HarborNodeExitGeoReport {
        let report = await withProxy(node: node, root: root, cancellation: cancellation,
                                     underlaySocksPort: underlaySocksPort, warpProfile: warpProfile) { port, _ in
            HarborNodeExitGeoReport.probed(await HarborNodeGeoIPResolver.exitLocation(
                socksPort: port, cancellation: cancellation))
        }
        return report ?? .notStarted("Mihomo/OpenVPN 检测内核未启动")
    }

    private static func withProxy<T: Sendable>(
        node: HarborProxyNode, root: URL, cancellation: HarborLatencyCancellation,
        underlaySocksPort: Int?, warpProfile: HarborWARPProfile?,
        action: @escaping @Sendable (Int, HarborProbeDiagnostics?) async -> T
    ) async -> T? {
        guard let lease = await HarborProbeBudget.engines.acquire(cancellation) else { return nil }
        guard !cancellation.isCancelled, let port = HarborNodeLatencyTester.reservePortPair() else {
            await HarborProbeBudget.engines.release(lease)
            return nil
        }
        let config = root.appendingPathComponent("probe-\(UUID().uuidString).json")
        let diagnostics = HarborProbeDiagnostics()
        let engine = Process()
        var result: T?
        do {
            try HarborProbeFiles.write(HarborMihomoConfig.make(
                node: node, httpPort: port, underlaySocksPort: underlaySocksPort, warpProfile: warpProfile
            ), to: config)
            engine.executableURL = root.appendingPathComponent("mihomo")
            engine.currentDirectoryURL = root
            engine.arguments = ["-d", root.path, "-f", config.path]
            engine.standardInput = FileHandle.nullDevice
            engine.standardOutput = FileHandle.nullDevice
            if let diagnostics { engine.standardError = diagnostics.pipe }
            else { engine.standardError = FileHandle.nullDevice }
            guard !cancellation.isCancelled, !Task.isCancelled else { throw CancellationError() }
            try engine.run()
            HarborProbeFiles.record(engine, config: config)
            if await HarborNodeLatencyTester.awaitListening(port: port, process: engine, cancellation: cancellation),
               await HarborNodeLatencyTester.awaitListening(port: port + 1, process: engine, cancellation: cancellation) {
                result = await action(port + 1, diagnostics)
            }
        } catch {}
        if await HarborProxyCommand.stop(engine) {
            HarborProbeFiles.remove(config)
            HarborNodeLatencyTester.releasePortPair(port)
            await HarborProbeBudget.engines.release(lease)
        }
        return result
    }

    private struct CurlResult: Sendable {
        let exitCode: Int32
        let status: Int
        let milliseconds: Int?
        var succeeded: Bool { exitCode == 0 && (200..<300).contains(status) }
    }

    private static func warmupAndMeasure(socksPort: Int, cancellation: HarborLatencyCancellation,
                                         diagnostics: HarborProbeDiagnostics?, seconds: Int) async -> HarborNodeDelayReport {
        let deadline = ContinuousClock.now + .seconds(seconds)
        let url = HarborNodeLatencyTester.openVPNVerificationURL.absoluteString
        while ContinuousClock.now < deadline, !cancellation.isCancelled, !Task.isCancelled {
            let remaining = ContinuousClock.now.duration(to: deadline).components.seconds
            if let result = await curlRequest(url: url, socksPort: socksPort,
                                              timeout: max(1, min(5, Int(remaining))),
                                              cancellation: cancellation),
               result.exitCode == 0, result.status == 204, let milliseconds = result.milliseconds {
                return .succeeded(milliseconds)
            }
            if diagnostics?.indicatesAuthenticationFailure() == true {
                return .failed("OpenVPN 认证被入口拒绝")
            }
            do { try await Task.sleep(for: .milliseconds(300)) } catch { return .failed("测试已取消") }
        }
        return .failed(cancellation.isCancelled || Task.isCancelled
                       ? "测试已取消" : "OpenVPN 握手或 HTTPS 出口验证超时")
    }

    private static func curlRequest(url: String, socksPort: Int, timeout: Int,
                                    cancellation: HarborLatencyCancellation, follow: Bool = false) async -> CurlResult? {
        guard !cancellation.isCancelled, !Task.isCancelled,
              let lease = await HarborProbeBudget.requests.acquire(cancellation) else { return nil }
        var arguments = [
            "--disable", "--silent", "--max-time", String(timeout),
            "--proxy", "socks5h://127.0.0.1:\(socksPort)", "--noproxy", "",
            "--output", "/dev/null", "--write-out", "%{http_code} %{time_total}"
        ]
        if follow { arguments += ["--location", "--max-redirs", "3", "--proto-redir", "=https"] }
        arguments += ["--url", url]
        let output = try? await HarborProxyCommand.run(
            URL(fileURLWithPath: "/usr/bin/curl"), arguments: arguments,
            timeout: TimeInterval(timeout) + 1, outputLimit: 128, cancelled: { cancellation.isCancelled }
        )
        await HarborProbeBudget.requests.release(lease)
        guard let output, !cancellation.isCancelled else { return nil }
        let parts = String(decoding: output.data, as: UTF8.self).split(separator: " ")
        let status = parts.first.flatMap { Int($0) } ?? 0
        let milliseconds = parts.dropFirst().first.flatMap { Double($0) }.map { max(1, Int(($0 * 1_000).rounded())) }
        return CurlResult(exitCode: output.status, status: status, milliseconds: milliseconds)
    }
}
