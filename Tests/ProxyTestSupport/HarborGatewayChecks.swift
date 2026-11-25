import Darwin
import Foundation
import Network
import CodexHarborCore

/// Isolated loopback fixtures. No real proxy, subscriptions, LaunchAgent,
/// system proxy or user settings are used.
public struct HarborGatewayChecks: Sendable {
    public init() {}
    private func check(_ condition: Bool, _ line: UInt = #line) throws {
        guard condition else { throw Failure.assertion(line) }
    }
    private enum Failure: Error { case socket, timeout, badResponse, assertion(UInt) }

    private final class Fixture: @unchecked Sendable {
        let listener: NWListener
        let queue = DispatchQueue(label: "harbor.tests.gateway.fixture")
        enum Mode: Sendable { case echo, http, socks }
        let marker: Data
        let mode: Mode
        let udpPort: UInt16?
        init(_ label: String, mode: Mode = .echo, udpPort: UInt16? = nil) throws {
            self.udpPort = udpPort
            marker = Data(label.utf8)
            self.mode = mode
            let params = NWParameters.tcp
            params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: .any)
            listener = try NWListener(using: params)
        }
        func start() async throws -> UInt16 {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UInt16, any Error>) in
                // State and completion are confined to this serial queue.
                let gate = StartGate(continuation)
                listener.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .ready:
                        if let port = self?.listener.port?.rawValue { gate.finish(.success(port)) }
                        else { gate.finish(.failure(Failure.socket)) }
                    case .failed, .cancelled: gate.finish(.failure(Failure.socket))
                    default: break
                    }
                }
                listener.newConnectionHandler = { [weak self] connection in
                    guard let self else { connection.cancel(); return }
                    connection.start(queue: self.queue)
                    switch self.mode {
                    case .echo: self.respond(connection)
                    case .http: self.httpRequest(connection, accumulated: Data())
                    case .socks: self.socksGreeting(connection)
                    }
                }
                listener.start(queue: queue)
                queue.asyncAfter(deadline: .now() + .seconds(5)) { gate.finish(.failure(Failure.timeout)) }
            }
        }
        private func exact(_ connection: NWConnection, count: Int,
                           then: @escaping @Sendable (Data) -> Void) {
            connection.receive(minimumIncompleteLength: count, maximumLength: count) { data, _, _, error in
                guard error == nil, let data, data.count == count else { connection.cancel(); return }
                then(data)
            }
        }
        private func socksGreeting(_ connection: NWConnection) {
            exact(connection, count: 3) { [weak self] greeting in
                guard let self, greeting == Data([5, 1, 0]) else { connection.cancel(); return }
                connection.send(content: Data([5, 0]), completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil else { connection.cancel(); return }
                    self.exact(connection, count: 10) { [weak self] request in
                        guard let self else { connection.cancel(); return }
                        if HarborSOCKS5Frame.command(request) == .udpAssociate, let port = self.udpPort {
                            connection.send(content: HarborSOCKS5Frame.loopbackReply(port: port),
                                            completion: .contentProcessed { error in
                                guard error == nil else { connection.cancel(); return }
                                connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { _, _, _, _ in connection.cancel() }
                            })
                            return
                        }
                        guard HarborSOCKS5Frame.command(request) == .connect else { connection.cancel(); return }
                        connection.send(content: HarborSOCKS5Frame.loopbackReply(port: 12345),
                                        completion: .contentProcessed { [weak self] error in
                            guard let self, error == nil else { connection.cancel(); return }
                            self.respond(connection)
                        })
                    }
                })
            }
        }
        private func httpRequest(_ connection: NWConnection, accumulated: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, _, error in
                guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
                let request = accumulated + data
                guard request.count <= 8192 else { connection.cancel(); return }
                guard request.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    self.httpRequest(connection, accumulated: request); return
                }
                let line = String(decoding: request, as: UTF8.self)
                let tunnel = line.hasPrefix("CONNECT example.com:443 HTTP/1.1\r\n")
                guard tunnel || line.hasPrefix("GET http://example.com/ HTTP/1.1\r\n") else {
                    connection.cancel(); return
                }
                let response = tunnel
                    ? Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
                    : Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\n".utf8) + self.marker
                connection.send(content: response, completion: .contentProcessed { [weak self] error in
                    guard let self, error == nil, tunnel else { connection.cancel(); return }
                    self.respond(connection)
                })
            }
        }
        private func respond(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1024) { [weak self] data, _, eof, error in
                guard let self, error == nil, let data, !data.isEmpty else { connection.cancel(); return }
                connection.send(content: self.marker + data, completion: .contentProcessed { [weak self] error in
                    if error != nil || eof { connection.cancel() }
                    else if let self { self.respond(connection) }
                    else { connection.cancel() }
                })
            }
        }
        func stop() { listener.cancel() }
        private final class StartGate: @unchecked Sendable {
            private var continuation: CheckedContinuation<UInt16, any Error>?
            init(_ continuation: CheckedContinuation<UInt16, any Error>) { self.continuation = continuation }
            func finish(_ result: Result<UInt16, any Error>) {
                let current = continuation
                continuation = nil
                current?.resume(with: result)
            }
        }
    }

    private func gateway(drainSeconds: Int = 1) async throws -> (HarborLocalProxyGateway, Int) {
        // A real bind is the authority; a port probe alone is not a reservation.
        for port in stride(from: 28000, through: 28998, by: 2).shuffled().prefix(30) {
            let gateway = try HarborLocalProxyGateway(httpPort: port, drainSeconds: drainSeconds)
            do { try await gateway.start(); return (gateway, port) }
            catch { gateway.stop() }
        }
        throw Failure.socket
    }

    private func connect(_ port: Int) throws -> Int32 {
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw Failure.socket }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        var noSignal: Int32 = 1
        guard setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0,
              setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSignal, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            Darwin.close(fd); throw Failure.socket
        }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let status = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard status == 0 else { Darwin.close(fd); throw Failure.socket }
        return fd
    }

    private func exchange(_ fd: Int32, expected: String) throws {
        let sent = Data("x".utf8)
        guard sent.withUnsafeBytes({ Darwin.send(fd, $0.baseAddress, $0.count, 0) }) == sent.count else {
            throw Failure.socket
        }
        let expectedBytes = Data((expected + "x").utf8)
        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 32)
        while received.count < expectedBytes.count {
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            guard count > 0 else { throw Failure.badResponse }
            received.append(contentsOf: buffer.prefix(count))
        }
        try check(received == expectedBytes)
    }

    private func sendBytes(_ fd: Int32, _ bytes: Data) throws {
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeBytes { Darwin.send(fd, $0.baseAddress?.advanced(by: offset), bytes.count - offset, 0) }
            guard count > 0 else { throw Failure.socket }
            offset += count
        }
    }

    private func receiveBytes(_ fd: Int32, count: Int) throws -> Data {
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while result.count < count {
            let length = min(buffer.count, count - result.count)
            let read = buffer.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, length, 0) }
            guard read > 0 else { throw Failure.badResponse }
            result.append(contentsOf: buffer.prefix(read))
        }
        return result
    }

    public func httpAndSOCKSProtocols() async throws {
        let http = try Fixture("H", mode: .http), socks = try Fixture("S", mode: .socks)
        defer { http.stop(); socks.stop() }
        let httpPort = try await http.start(), socksPort = try await socks.start()
        let (gateway, port) = try await gateway()
        defer { gateway.stop() }
        try gateway.route(to: .init(httpPort: httpPort, socksPort: socksPort))
        do {
            let fd = try connect(port)
            defer { Darwin.close(fd) }
            try sendBytes(fd, Data("GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n".utf8))
            let expected = Data("HTTP/1.1 200 OK\r\nContent-Length: 1\r\nConnection: close\r\n\r\nH".utf8)
            try check(try receiveBytes(fd, count: expected.count) == expected)
        }
        do {
            let fd = try connect(port)
            defer { Darwin.close(fd) }
            try sendBytes(fd, Data("CONNECT example.com:443 HTTP/1.1\r\nHost: example.com:443\r\n\r\n".utf8))
            let expected = Data("HTTP/1.1 200 Connection Established\r\n\r\n".utf8)
            try check(try receiveBytes(fd, count: expected.count) == expected)
            try exchange(fd, expected: "H")
        }
        do {
            let fd = try connect(port + 1)
            defer { Darwin.close(fd) }
            try sendBytes(fd, Data([5, 1, 0]))
            try check(try receiveBytes(fd, count: 2) == Data([5, 0]))
            // Documentation-only destination; the fixture never dials it.
            try sendBytes(fd, Data([5, 1, 0, 1, 192, 0, 2, 1, 1, 187]))
            let reply = try receiveBytes(fd, count: 10)
            try check(reply == HarborSOCKS5Frame.loopbackReply(port: 12345))
            try exchange(fd, expected: "S")
        }
        do {
            let fd = try connect(port + 1)
            defer { Darwin.close(fd) }
            try sendBytes(fd, Data([5, 1, 0]))
            try check(try receiveBytes(fd, count: 2) == Data([5, 0]))
            try sendBytes(fd, Data([5, 1, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255)]))
            try check(try receiveBytes(fd, count: 10) == HarborSOCKS5Frame.failure(2))
        }
    }

    private func udpSocket(port: UInt16 = 0) throws -> (Int32, UInt16) {
        let fd = Darwin.socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { throw Failure.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        var timeout = timeval(tv_sec: 0, tv_usec: 300_000)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &size) }
        }
        guard bound == 0, named == 0,
              setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size)) == 0 else {
            Darwin.close(fd); throw Failure.socket
        }
        return (fd, UInt16(bigEndian: address.sin_port))
    }

    private func sendDatagram(_ fd: Int32, data: Data, port: UInt16) throws {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let sent = data.withUnsafeBytes { bytes in
            withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    sendto(fd, bytes.baseAddress, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }
        try check(sent == data.count)
    }

    private func receiveDatagram(_ fd: Int32) -> (Data, UInt16)? {
        var address = sockaddr_in()
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        var buffer = [UInt8](repeating: 0, count: 65535)
        let received = buffer.withUnsafeMutableBytes { bytes in
            withUnsafeMutablePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(fd, bytes.baseAddress, bytes.count, 0, $0, &size)
                }
            }
        }
        guard received > 0 else { return nil }
        return (Data(buffer.prefix(received)), UInt16(bigEndian: address.sin_port))
    }

    public func udpAssociationAndRelease() async throws {
        let (backendFD, udpPort) = try udpSocket()
        defer { Darwin.close(backendFD) }
        let (clientFD, clientPort) = try udpSocket()
        defer { Darwin.close(clientFD) }
        let (otherFD, _) = try udpSocket()
        defer { Darwin.close(otherFD) }
        let http = try Fixture("H"), socks = try Fixture("S", mode: .socks, udpPort: udpPort)
        defer { http.stop(); socks.stop() }
        let hp = try await http.start(), sp = try await socks.start()
        let (gateway, port) = try await gateway()
        defer { gateway.stop() }
        let route = HarborLocalProxyGateway.Backend(httpPort: hp, socksPort: sp)
        try gateway.route(to: route)
        let control = try connect(port + 1)
        defer { Darwin.close(control) }
        try sendBytes(control, Data([5, 1, 0]))
        try check(try receiveBytes(control, count: 2) == Data([5, 0]))
        try sendBytes(control, Data([5, 3, 0, 1, 127, 0, 0, 1, UInt8(clientPort >> 8), UInt8(clientPort & 255)]))
        let reply = try receiveBytes(control, count: 10)
        guard let address = HarborSOCKS5Frame.parseAddress(reply), reply[1] == 0,
              address.isLoopback, address.port != udpPort else { throw Failure.badResponse }
        let relayPort = address.port
        let packet = Data([0, 0, 0, 1, 192, 0, 2, 1, 0, 53, 42])
        try sendDatagram(clientFD, data: packet, port: relayPort)
        guard let (forwarded, returnPort) = receiveDatagram(backendFD) else { throw Failure.timeout }
        try check(forwarded == packet)
        try sendDatagram(backendFD, data: packet, port: returnPort)
        try check(receiveDatagram(clientFD)?.0 == packet)

        // A different local UDP source cannot use the association.
        try sendDatagram(otherFD, data: packet, port: relayPort)
        try check(receiveDatagram(backendFD) == nil)
        var fragmented = packet
        fragmented[2] = 1
        try sendDatagram(clientFD, data: fragmented, port: relayPort)
        try check(receiveDatagram(backendFD) == nil)
        try sendDatagram(clientFD, data: Data([0, 0, 0, 3, 250, 1, 2]), port: relayPort)
        try check(receiveDatagram(backendFD) == nil)
        // Reserved local destination must never reach the backend.
        try sendDatagram(clientFD, data: Data([0, 0, 0, 1, 127, 0, 0, 1, UInt8(port >> 8), UInt8(port & 255), 42]), port: relayPort)
        try check(receiveDatagram(backendFD) == nil)
        _ = Darwin.shutdown(control, SHUT_RDWR)
        let deadline = ContinuousClock.now + .seconds(3)
        var released = false
        while ContinuousClock.now < deadline {
            if let (fd, _) = try? udpSocket(port: relayPort) {
                Darwin.close(fd)
                released = true
                break
            }
            try await Task.sleep(for: .milliseconds(30))
        }
        try check(released)
        try check(gateway.connectionCount(backendID: route.id) == 0)
        gateway.stop()
        // Rebind the same fixed pair after stopping (NW cancellation is asynchronous).
        let replacement = try HarborLocalProxyGateway(httpPort: port)
        defer { replacement.stop() }
        try await replacement.start()
        try check(replacement.isReady)
    }

    private struct ResourceSample {
        let descriptors: Int
        let rss: UInt64
        let cpuSeconds: Double
        static func capture() throws -> Self {
            let estimated = proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, nil, 0)
            guard estimated > 0, estimated < 4 * 1024 * 1024 else { throw Failure.socket }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(estimated) / MemoryLayout<proc_fdinfo>.stride + 64)
            let bytes = fds.withUnsafeMutableBytes {
                proc_pidinfo(getpid(), PROC_PIDLISTFDS, 0, $0.baseAddress, Int32($0.count))
            }
            guard bytes > 0 else { throw Failure.socket }
            var info = mach_task_basic_info()
            var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
            let result = withUnsafeMutablePointer(to: &info) {
                $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
                }
            }
            guard result == KERN_SUCCESS else { throw Failure.socket }
            var usage = rusage()
            guard getrusage(RUSAGE_SELF, &usage) == 0 else { throw Failure.socket }
            let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
                + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
            return .init(descriptors: Int(bytes) / MemoryLayout<proc_fdinfo>.stride,
                         rss: info.resident_size, cpuSeconds: cpu)
        }
    }

    /// Long-lived gateway soak. Unlike stress(), the listener and two
    /// backends remain alive throughout the run. Periodically suspend and
    /// resume routing, and capture process resource trends after drain.
    public func resourceSoak(seconds: Int) async throws {
        guard (10...259_200).contains(seconds) else { throw Failure.badResponse }
        let first = try Fixture("A"), second = try Fixture("B")
        defer { first.stop(); second.stop() }
        let aPort = try await first.start(), bPort = try await second.start()
        let (gateway, port) = try await gateway(drainSeconds: 2)
        defer { gateway.stop() }
        let a = HarborLocalProxyGateway.Backend(httpPort: aPort, socksPort: bPort)
        let b = HarborLocalProxyGateway.Backend(httpPort: bPort, socksPort: aPort)
        func cycle(_ index: Int) throws {
            let next = index.isMultiple(of: 2) ? a : b
            try gateway.route(to: next)
            try check(gateway.activeBackendID == next.id && gateway.isReady)
            let fd = try connect(port)
            defer { Darwin.close(fd) }
            try exchange(fd, expected: next.id == a.id ? "A" : "B")
        }
        for index in 0..<50 { try cycle(index) }
        try await Task.sleep(for: .seconds(3))
        let baseline = try ResourceSample.capture()
        let start = ContinuousClock.now
        let deadline = start + .seconds(seconds)
        var index = 0
        var nextReport = start
        var previous = baseline
        var peakRSS = baseline.rss
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            try cycle(index)
            index += 1
            if index.isMultiple(of: 10) {
                gateway.suspendRouting(closeExisting: true)
                try check(gateway.activeBackendID == nil)
                try check(gateway.connectionCount(backendID: a.id) == 0)
                try check(gateway.connectionCount(backendID: b.id) == 0)
            }
            try await Task.sleep(for: .seconds(1))
            if ContinuousClock.now >= nextReport {
                let sample = try ResourceSample.capture()
                peakRSS = max(peakRSS, sample.rss)
                print("SOAK: elapsed=\(start.duration(to: .now)) switches=\(index) fd=\(sample.descriptors) rss=\(sample.rss) cpu_delta=\(sample.cpuSeconds - previous.cpuSeconds)")
                previous = sample
                nextReport = .now + .seconds(30)
            }
        }
        gateway.stop()
        try await Task.sleep(for: .seconds(3))
        let end = try ResourceSample.capture()
        try check(gateway.connectionCount(backendID: a.id) == 0)
        try check(gateway.connectionCount(backendID: b.id) == 0)
        try check(end.descriptors <= baseline.descriptors + 8)
        try check(end.rss <= baseline.rss + 64 * 1024 * 1024)
        print("SOAK PASS: switches=\(index) fd_start=\(baseline.descriptors) fd_end=\(end.descriptors) rss_start=\(baseline.rss) rss_peak_sample=\(peakRSS) rss_end=\(end.rss) cpu_seconds=\(end.cpuSeconds - baseline.cpuSeconds)")
    }

    public func resourceStress(rounds: Int = 10) async throws {
        guard (1...100).contains(rounds) else { throw Failure.badResponse }
        // Warm up Network.framework's process-level caches before sampling.
        try await switchesOneHundredTimesWithoutReplacingEntry()
        try await Task.sleep(for: .seconds(2))
        let baseline = try ResourceSample.capture()
        let start = ContinuousClock.now
        var peak = baseline.rss
        var peakFDs = baseline.descriptors
        for _ in 0..<rounds {
            try await switchesOneHundredTimesWithoutReplacingEntry()
            try await Task.sleep(for: .milliseconds(200))
            let sample = try ResourceSample.capture()
            peak = max(peak, sample.rss)
            peakFDs = max(peakFDs, sample.descriptors)
        }
        try await Task.sleep(for: .seconds(3))
        let end = try ResourceSample.capture()
        let elapsed = start.duration(to: .now).components
        let wall = Double(elapsed.seconds) + Double(elapsed.attoseconds) / 1e18
        print("STRESS: switches=\(rounds * 100) elapsed=\(wall)s cpu_seconds=\(end.cpuSeconds - baseline.cpuSeconds)")
        print("STRESS: fd_baseline=\(baseline.descriptors) fd_peak_sample=\(peakFDs) fd_end=\(end.descriptors)")
        print("STRESS: rss_baseline_bytes=\(baseline.rss) rss_peak_sample_bytes=\(peak) rss_end_bytes=\(end.rss)")
        // Small framework cache fluctuations are allowed; every individual
        // round still verifies zero tracked connections and releases listeners.
        try check(end.descriptors <= baseline.descriptors + 8)
        try check(end.rss <= baseline.rss + 64 * 1024 * 1024)
    }

    public func switchesOneHundredTimesWithoutReplacingEntry() async throws {
        let first = try Fixture("A"), second = try Fixture("B")
        defer { first.stop(); second.stop() }
        let aPort = try await first.start(), bPort = try await second.start()
        let (gateway, port) = try await gateway(drainSeconds: 2)
        defer { gateway.stop() }
        // Separate SOCKS port is not exercised by this TCP routing fixture.
        let a = HarborLocalProxyGateway.Backend(httpPort: aPort, socksPort: bPort)
        let b = HarborLocalProxyGateway.Backend(httpPort: bPort, socksPort: aPort)
        var switchMilliseconds: [Double] = []
        for iteration in 0..<100 {
            let next = iteration.isMultiple(of: 2) ? a : b
            let started = ContinuousClock.now
            try gateway.route(to: next)
            let elapsed = started.duration(to: .now).components
            switchMilliseconds.append(Double(elapsed.seconds) * 1000 + Double(elapsed.attoseconds) / 1e15)
            try check(gateway.isReady)
            try check(gateway.activeBackendID == next.id)
            let fd = try connect(port)
            defer { Darwin.close(fd) }
            try exchange(fd, expected: next.id == a.id ? "A" : "B")
        }
        let sorted = switchMilliseconds.sorted()
        print(String(format: "BENCH: local route commit milliseconds p50=%.3f p95=%.3f max=%.3f",
            sorted[49], sorted[94], sorted[99]))
        gateway.stop()
        try check(!gateway.isReady)
        try check(gateway.activeBackendID == nil)
        try check(gateway.connectionCount(backendID: a.id) == 0)
        try check(gateway.connectionCount(backendID: b.id) == 0)
    }

    public func oldFlowDrainsAndSuspendedGatewayNeverRoutes() async throws {
        let first = try Fixture("A"), second = try Fixture("B")
        defer { first.stop(); second.stop() }
        let aPort = try await first.start(), bPort = try await second.start()
        let (gateway, port) = try await gateway(drainSeconds: 2)
        defer { gateway.stop() }
        let a = HarborLocalProxyGateway.Backend(httpPort: aPort, socksPort: bPort)
        let b = HarborLocalProxyGateway.Backend(httpPort: bPort, socksPort: aPort)
        try gateway.route(to: a)
        let old = try connect(port)
        defer { Darwin.close(old) }
        try exchange(old, expected: "A")
        try gateway.route(to: b)
        try exchange(old, expected: "A")
        let fresh = try connect(port)
        defer { Darwin.close(fresh) }
        try exchange(fresh, expected: "B")
        try await Task.sleep(for: .milliseconds(2400))
        try check(gateway.connectionCount(backendID: a.id) == 0)
        gateway.suspendRouting(closeExisting: true)
        try check(gateway.activeBackendID == nil)
        try check(gateway.connectionCount(backendID: b.id) == 0)
        // TCP accept may succeed before the listener rejects the connection.
        if let fd = try? connect(port) {
            defer { Darwin.close(fd) }
            var byte: UInt8 = 0
            try check(Darwin.recv(fd, &byte, 1, 0) <= 0)
        }
        do {
            try gateway.route(to: .init(httpPort: UInt16(port), socksPort: bPort))
            throw Failure.badResponse
        } catch HarborLocalProxyGateway.GatewayError.recursiveRoute {}
    }
}
