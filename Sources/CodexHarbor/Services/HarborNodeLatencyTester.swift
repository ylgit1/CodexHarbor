import CodexHarborCore
import CFNetwork
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

/// One v2rayN-style real-delay attempt, isolated from the active proxy.
private final class HarborRealDelayAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: Process?
    private var request: URLSessionTask?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let engine = engine
        let request = request
        lock.unlock()
        request?.cancel()
        if engine?.isRunning == true { engine?.terminate() }
    }

    func run(node: HarborProxyNode, root: URL, ruleMode: Bool,
             forcedProxyDomains: [String], cancellation: HarborLatencyCancellation) -> HarborNodeDelayReport {
        guard !cancellation.isCancelled else { return .failed("测试已取消") }
        guard let port = HarborNodeLatencyTester.reservePortPair() else {
            return .failed("测速端口不可用")
        }
        defer { HarborNodeLatencyTester.releasePortPair(port) }

        guard let token = cancellation.observe({ [weak self] in self?.cancel() }) else {
            return .failed("测试已取消")
        }
        defer { cancellation.removeObserver(token) }

        let target = HarborNodeLatencyTester.realPingURL()
        let xray = root.appendingPathComponent("xray")
        let configPath = root.appendingPathComponent("probe-\(UUID().uuidString).json")
        guard FileManager.default.isExecutableFile(atPath: xray.path),
              let data = try? HarborXrayConfig.make(
                node: node,
                httpPort: port,
                ruleMode: ruleMode,
                forcedProxyDomains: forcedProxyDomains,
                routeAllViaProxy: true
              ),
              (try? data.write(to: configPath, options: .atomic)) != nil else {
            return .failed("节点配置无效或 Xray 不可用")
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
        defer { try? FileManager.default.removeItem(at: configPath) }

        let engine = Process()
        engine.executableURL = xray
        engine.currentDirectoryURL = root
        engine.arguments = ["run", "-config", configPath.path]
        engine.standardOutput = FileHandle.nullDevice
        engine.standardError = FileHandle.nullDevice
        guard install(engine) else { return .failed("测试已取消") }
        do { try engine.run() } catch {
            clear(engine)
            return .failed("Xray 启动失败")
        }
        if isCancelled, engine.isRunning { engine.terminate() }
        defer {
            if engine.isRunning { engine.terminate() }
            engine.waitUntilExit()
            clear(engine)
        }

        guard HarborNodeLatencyTester.waitUntilListening(
            port: port,
            process: engine,
            cancellation: cancellation
        ) else { return .failed(isCancelled ? "测试已取消" : "Xray 本地监听启动失败") }
        guard !isCancelled else { return .failed("测试已取消") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port + 1
        ]
        configuration.timeoutIntervalForRequest = TimeInterval(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(HarborProxyLatencyPolicy.requestTimeoutSeconds))
        var timings: [Int] = []
        for _ in 0..<HarborProxyLatencyPolicy.realPingRequestCount {
            guard !isCancelled else { return .failed("测试已取消") }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .failed("真实测速超时") }
            let result = ProbeResponse()
            let done = DispatchSemaphore(value: 0)
            let started = ContinuousClock.now
            let task = session.dataTask(with: target) { _, response, error in
                result.set(response != nil && error == nil,
                           errorCode: (error as NSError?)?.code)
                done.signal()
            }
            guard install(task) else { return .failed("测试已取消") }
            task.resume()
            let completed = done.wait(timeout: .now() + remaining.timeInterval) == .success
            if !completed { task.cancel() }
            clear(task)
            guard !isCancelled else { return .failed("测试已取消") }
            guard completed, result.succeeded else {
                if completed && result.errorCode == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                    return .failed("测速地址的 HTTP 请求被 macOS 安全策略阻止")
                }
                return .failed(completed ? "真实测速请求失败" : "真实测速超时")
            }
            let elapsed = started.duration(to: .now).timeInterval
            timings.append(Int(elapsed * 1_000))
            Thread.sleep(forTimeInterval:
                Double(HarborProxyLatencyPolicy.realPingPauseMilliseconds) / 1_000)
        }
        guard let minimum = timings.filter({ $0 > 0 }).min() else {
            return .failed("真实测速请求失败")
        }
        return .succeeded(minimum)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func install(_ process: Process) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        engine = process
        return true
    }

    private func clear(_ process: Process) {
        lock.lock()
        defer { lock.unlock() }
        if engine === process { engine = nil }
    }

    private func install(_ task: URLSessionTask) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        request = task
        return true
    }

    private func clear(_ task: URLSessionTask) {
        lock.lock()
        defer { lock.unlock() }
        if request === task { request = nil }
    }
}

private final class ProbeResponse: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    private var code: Int?
    var succeeded: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
    var errorCode: Int? {
        lock.lock()
        defer { lock.unlock() }
        return code
    }
    func set(_ newValue: Bool, errorCode: Int?) {
        lock.lock()
        value = newValue
        code = errorCode
        lock.unlock()
    }
}

private extension Duration {
    var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}

/// One Xray process for the entire real-ping batch. Each mixed inbound is
/// routed to exactly one outbound, matching v2rayN's speedtest configuration.
final class HarborRealDelayBatch: @unchecked Sendable {
    private let engine: Process
    private let configPath: URL
    private let basePort: Int
    private let portsByNodeID: [String: Int]
    private let cancellation: HarborLatencyCancellation
    private let cancellationObserver: UUID
    private let lock = NSLock()
    private var stopped = false

    init?(nodes: [HarborProxyNode], root: URL,
          cancellation: HarborLatencyCancellation) {
        guard Set(nodes.map(\.id)).count == nodes.count else { return nil }
        guard let basePort = HarborNodeLatencyTester.reservePortRange(nodes.count) else { return nil }
        let configPath = root.appendingPathComponent("probe-batch-\(UUID().uuidString).json")
        let xray = root.appendingPathComponent("xray")
        guard FileManager.default.isExecutableFile(atPath: xray.path),
              let data = try? HarborXrayConfig.makeRealPingBatch(
                nodes: nodes, basePort: basePort),
              (try? data.write(to: configPath, options: .atomic)) != nil else {
            HarborNodeLatencyTester.releasePortRange(basePort, count: nodes.count)
            return nil
        }
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configPath.path)
        let engine = Process()
        engine.executableURL = xray
        engine.currentDirectoryURL = root
        engine.arguments = ["run", "-config", configPath.path]
        engine.standardOutput = FileHandle.nullDevice
        engine.standardError = FileHandle.nullDevice
        self.engine = engine
        self.configPath = configPath
        self.basePort = basePort
        self.portsByNodeID = Dictionary(uniqueKeysWithValues:
            nodes.enumerated().map { ($0.element.id, basePort + $0.offset) })
        self.cancellation = cancellation
        guard let observer = cancellation.observe({ [weak engine] in
            if engine?.isRunning == true { engine?.terminate() }
        }) else {
            try? FileManager.default.removeItem(at: configPath)
            HarborNodeLatencyTester.releasePortRange(basePort, count: nodes.count)
            return nil
        }
        self.cancellationObserver = observer
        do { try engine.run() } catch {
            close()
            return nil
        }
        guard HarborNodeLatencyTester.waitUntilListening(
            port: basePort, process: engine, cancellation: cancellation),
              HarborNodeLatencyTester.waitUntilListening(
                port: basePort + nodes.count - 1,
                process: engine, cancellation: cancellation) else {
            close()
            return nil
        }
    }

    func close() {
        lock.lock()
        if stopped { lock.unlock(); return }
        stopped = true
        lock.unlock()
        cancellation.removeObserver(cancellationObserver)
        if engine.isRunning { engine.terminate() }
        if engine.processIdentifier != 0 { engine.waitUntilExit() }
        try? FileManager.default.removeItem(at: configPath)
        HarborNodeLatencyTester.releasePortRange(basePort, count: portsByNodeID.count)
    }

    func measure(node: HarborProxyNode) async -> HarborNodeDelayReport {
        guard let port = portsByNodeID[node.id], !cancellation.isCancelled else {
            return .failed("测试已取消")
        }
        let target = HarborNodeLatencyTester.realPingURL()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port
        ]
        configuration.timeoutIntervalForRequest = TimeInterval(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        guard let observer = cancellation.observe({ session.invalidateAndCancel() }) else {
            return .failed("测试已取消")
        }
        defer { cancellation.removeObserver(observer) }
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(HarborProxyLatencyPolicy.requestTimeoutSeconds))
        var timings: [Int] = []
        for _ in 0..<HarborProxyLatencyPolicy.realPingRequestCount {
            guard !cancellation.isCancelled, !Task.isCancelled else {
                return .failed("测试已取消")
            }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return .failed("真实测速超时") }
            var request = URLRequest(url: target, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = remaining.timeInterval
            let started = ContinuousClock.now
            do {
                // Any HTTP response is a result, including non-2xx statuses,
                // just as HttpClient.GetAsync is used by v2rayN.
                _ = try await session.data(for: request)
            } catch {
                if cancellation.isCancelled || Task.isCancelled {
                    return .failed("测试已取消")
                }
                if (error as NSError).code == NSURLErrorAppTransportSecurityRequiresSecureConnection {
                    return .failed("测速地址的 HTTP 请求被 macOS 安全策略阻止")
                }
                return .failed(ContinuousClock.now >= deadline
                    ? "真实测速超时" : "真实测速请求失败")
            }
            timings.append(Int(started.duration(to: .now).timeInterval * 1_000))
            try? await Task.sleep(for: .milliseconds(
                HarborProxyLatencyPolicy.realPingPauseMilliseconds))
        }
        guard let minimum = timings.filter({ $0 > 0 }).min() else {
            return .failed("真实测速请求失败")
        }
        return .succeeded(minimum)
    }
}

/// Measures real HTTP response time through an isolated Xray instance. A
/// result proves that the node protocol and remote proxy path carried traffic;
/// it is not a direct TCP handshake to the server port.
enum HarborNodeLatencyTester {
    private static let portLock = NSLock()
    private nonisolated(unsafe) static var reservedPorts: Set<Int> = []

    static func realPingURL() -> URL {
        let path = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/v2rayN/guiConfigs/guiNConfig.json")
        let data = try? Data(contentsOf: path)
        return HarborProxyRealPingTarget.resolve(v2rayNConfigurationData: data)
    }

    /// Active-node real ping follows v2rayN's ConnectionHandler exactly:
    /// one configured SpeedPingTestUrl, two GETs, 100 ms gap, 5s shared budget.
    /// Measure through the running Xray SOCKS listener, never through system
    /// proxy settings or a direct route. Do not add fallback probe sites.
    static func checkActiveSOCKS(port: Int) async -> Bool {
        guard (1...65_535).contains(port), !Task.isCancelled else { return false }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.connectionProxyDictionary = [
            kCFNetworkProxiesSOCKSEnable as String: 1,
            kCFNetworkProxiesSOCKSProxy as String: "127.0.0.1",
            kCFNetworkProxiesSOCKSPort as String: port
        ]
        configuration.timeoutIntervalForRequest = TimeInterval(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        configuration.timeoutIntervalForResource = TimeInterval(HarborProxyLatencyPolicy.requestTimeoutSeconds)
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = realPingURL()
        let deadline = ContinuousClock.now.advanced(
            by: .seconds(HarborProxyLatencyPolicy.requestTimeoutSeconds))
        for _ in 0..<HarborProxyLatencyPolicy.realPingRequestCount {
            guard !Task.isCancelled else { return false }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { return false }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
            request.timeoutInterval = remaining.timeInterval
            do {
                // HttpClient.GetAsync does not require 2xx; URLSession likewise
                // only needs a completed HTTP response.
                _ = try await session.data(for: request)
            } catch {
                return false
            }
            do {
                try await Task.sleep(for: .milliseconds(
                    HarborProxyLatencyPolicy.realPingPauseMilliseconds))
            } catch {
                return false
            }
        }
        return !Task.isCancelled
    }

    static func startRealBatch(nodes: [HarborProxyNode], root: URL,
                               cancellation: HarborLatencyCancellation) async -> HarborRealDelayBatch? {
        await Task.detached(priority: .utility) {
            HarborRealDelayBatch(nodes: nodes, root: root, cancellation: cancellation)
        }.value
    }

    fileprivate static func reservePortRange(_ count: Int) -> Int? {
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

    /// Fast server-port reachability only. This intentionally does not claim
    /// that credentials, TLS, the proxy protocol, or internet egress work.
    static func measureTCP(node: HarborProxyNode,
                           cancellation: HarborLatencyCancellation) async -> Int? {
        await Task.detached(priority: .utility) {
            guard !cancellation.isCancelled,
                  !node.host.isEmpty,
                  (1...65_535).contains(node.port) else { return nil }
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/nc")
            process.arguments = [
                "-G", String(HarborProxyLatencyPolicy.connectTimeoutSeconds),
                "-w", String(HarborProxyLatencyPolicy.connectTimeoutSeconds),
                "-z", node.host, String(node.port)
            ]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            guard let token = cancellation.observe({
                if process.isRunning { process.terminate() }
            }) else { return nil }
            defer { cancellation.removeObserver(token) }
            let started = ContinuousClock.now
            do { try process.run() } catch { return nil }
            if cancellation.isCancelled, process.isRunning { process.terminate() }
            process.waitUntilExit()
            guard process.terminationStatus == 0, !cancellation.isCancelled else { return nil }
            let duration = started.duration(to: .now).components
            return max(1, Int(duration.seconds * 1_000
                + duration.attoseconds / 1_000_000_000_000_000))
        }.value
    }

    static func measure(node: HarborProxyNode, root: URL, ruleMode: Bool,
                        forcedProxyDomains: [String] = HarborProxyDomainRules.defaults,
                        cancellation: HarborLatencyCancellation) async -> HarborNodeDelayReport {
        let attempt = HarborRealDelayAttempt()
        return await withTaskCancellationHandler {
            await Task.detached(priority: .utility) {
                attempt.run(
                    node: node,
                    root: root,
                    ruleMode: ruleMode,
                    forcedProxyDomains: forcedProxyDomains,
                    cancellation: cancellation
                )
            }.value
        } onCancel: {
            attempt.cancel()
        }
    }

    fileprivate static func reservePortPair() -> Int? {
        portLock.lock()
        defer { portLock.unlock() }
        for port in stride(from: 18200, through: 18480, by: 2)
            where !reservedPorts.contains(port)
                && isAvailable(port) && isAvailable(port + 1) {
            reservedPorts.insert(port)
            return port
        }
        return nil
    }

    fileprivate static func releasePortPair(_ port: Int) {
        portLock.lock()
        reservedPorts.remove(port)
        portLock.unlock()
    }

    fileprivate static func waitUntilListening(
        port: Int,
        process: Process,
        cancellation: HarborLatencyCancellation
    ) -> Bool {
        let deadline = Date().addingTimeInterval(
            Double(HarborProxyLatencyPolicy.listenerStartupTimeoutMilliseconds) / 1_000)
        while process.isRunning, !cancellation.isCancelled, Date() < deadline {
            if canConnect(port) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    private static func canConnect(_ port: Int) -> Bool {
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
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
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
