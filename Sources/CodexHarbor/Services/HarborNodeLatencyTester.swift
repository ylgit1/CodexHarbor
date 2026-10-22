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

/// One v2rayN-style real-delay attempt. The temporary Xray and curl process
/// are isolated from the active proxy and can both be stopped immediately.
private final class HarborRealDelayAttempt: @unchecked Sendable {
    private let lock = NSLock()
    private var engine: Process?
    private var request: Process?
    private var cancelled = false

    func cancel() {
        lock.lock()
        cancelled = true
        let engine = engine
        let request = request
        lock.unlock()
        if request?.isRunning == true { request?.terminate() }
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

        let xray = root.appendingPathComponent("xray")
        let configPath = root.appendingPathComponent("probe-\(UUID().uuidString).json")
        guard FileManager.default.isExecutableFile(atPath: xray.path),
              let data = try? HarborXrayConfig.make(
                node: node,
                httpPort: port,
                ruleMode: ruleMode,
                forcedProxyDomains: forcedProxyDomains,
                routeVerificationViaProxy: true
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
        guard install(engine, asRequest: false) else { return .failed("测试已取消") }
        do { try engine.run() } catch {
            clear(engine, asRequest: false)
            return .failed("Xray 启动失败")
        }
        if isCancelled, engine.isRunning { engine.terminate() }
        defer {
            if engine.isRunning { engine.terminate() }
            engine.waitUntilExit()
            clear(engine, asRequest: false)
        }

        guard HarborNodeLatencyTester.waitUntilListening(
            port: port,
            process: engine,
            cancellation: cancellation
        ) else { return .failed(isCancelled ? "测试已取消" : "Xray 本地监听启动失败") }
        guard !isCancelled else { return .failed("测试已取消") }
        var lastError = "HTTPS 请求失败"

        for address in [
            "https://www.gstatic.com/generate_204",
            "https://www.cloudflare.com/cdn-cgi/trace"
        ] {
            guard !isCancelled else { return .failed("测试已取消") }
            let curl = Process()
            let output = Pipe()
            curl.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            curl.arguments = [
                "-q", "--silent", "--fail", "--noproxy", "",
                "--proxy", "http://127.0.0.1:\(port)",
                "--connect-timeout", String(HarborProxyLatencyPolicy.connectTimeoutSeconds),
                "--max-time", String(HarborProxyLatencyPolicy.requestTimeoutSeconds),
                "--output", "/dev/null", "--write-out", "%{time_total}",
                address
            ]
            var environment = ProcessInfo.processInfo.environment
            for key in ["HTTP_PROXY", "HTTPS_PROXY", "ALL_PROXY", "http_proxy", "https_proxy", "all_proxy"] {
                environment.removeValue(forKey: key)
            }
            curl.environment = environment
            curl.standardOutput = output
            curl.standardError = FileHandle.nullDevice
            guard install(curl, asRequest: true) else { return .failed("测试已取消") }
            do { try curl.run() } catch {
                clear(curl, asRequest: true)
                lastError = "HTTPS 测试工具启动失败"
                continue
            }
            if isCancelled, curl.isRunning { curl.terminate() }
            curl.waitUntilExit()
            clear(curl, asRequest: true)
            guard !isCancelled else { return .failed("测试已取消") }
            let value = String(decoding: output.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if curl.terminationStatus == 0, let seconds = Double(value), seconds >= 0 {
                return .succeeded(max(1, Int((seconds * 1_000).rounded())))
            }
            // curl exit codes are intentionally coarse. A timeout alone
            // cannot tell TLS handshake filtering from a broken proxy path.
            switch curl.terminationStatus {
            case 28: lastError = "HTTPS 超时（TLS / WebSocket / 上游网络）"
            case 35: lastError = "TLS 握手失败"
            case 52, 56: lastError = "远端断开代理连接"
            case 5, 6: lastError = "DNS 解析失败"
            case 7: lastError = "代理连接失败"
            case 22: lastError = "HTTPS 返回错误状态"
            default: lastError = "HTTPS 验证未通过（代码 \(curl.terminationStatus)）"
            }
        }
        return .failed(lastError)
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    private func install(_ process: Process, asRequest: Bool) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return false }
        if asRequest { request = process } else { engine = process }
        return true
    }

    private func clear(_ process: Process, asRequest: Bool) {
        lock.lock()
        defer { lock.unlock() }
        if asRequest, request === process { request = nil }
        if !asRequest, engine === process { engine = nil }
    }
}

/// Measures real HTTPS response time through an isolated Xray instance. A
/// result proves that the node protocol and remote proxy path carried traffic;
/// it is not a direct TCP handshake to the server port.
enum HarborNodeLatencyTester {
    private static let portLock = NSLock()
    private nonisolated(unsafe) static var reservedPorts: Set<Int> = []

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
