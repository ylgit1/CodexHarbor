import CodexHarborCore
import Darwin
import Foundation

/// TCP reachability only prioritizes candidate attempts. It cannot mark an
/// OpenVPN node usable, and a direct failure does not block alternate routes.
enum HarborVPNGatePortScanner {
    static func rank(_ nodes: [HarborProxyNode], socksPort: Int?,
                     cancellation: HarborLatencyCancellation) async -> [HarborProxyNode] {
        let targets = Array(nodes.filter { $0.network == "tcp" }.prefix(64))
        let ranking = HarborLatencyCancellation()
        let observer = cancellation.observe { ranking.cancel() }
        let timer = Task {
            do { try await Task.sleep(for: .seconds(50)) } catch { return }
            ranking.cancel()
        }
        defer {
            timer.cancel()
            if let observer { cancellation.removeObserver(observer) }
        }
        let reachable = await reachableIDs(targets, socksPort: socksPort, cancellation: ranking)
        // A partial preflight may change order, never membership.
        return nodes.filter { reachable.contains($0.id) } + nodes.filter { !reachable.contains($0.id) }
    }

    static func reachableIDs(_ nodes: [HarborProxyNode], socksPort: Int? = nil,
                             cancellation: HarborLatencyCancellation?) async -> Set<String> {
        let targets = nodes.filter { $0.network == "tcp" && (1...65_535).contains($0.port) }
        return await withTaskGroup(of: (String, Bool).self) { group in
            var queue = HarborProxyLatencyQueue(count: targets.count, limit: 4)
            var reachable = Set<String>()
            func submit(_ index: Int) {
                let node = targets[index]
                group.addTask {
                    guard let lease = await HarborProbeBudget.requests.acquire(cancellation) else {
                        return (node.id, false)
                    }
                    let result = await withCheckedContinuation { continuation in
                        DispatchQueue.global(qos: .utility).async {
                            let connected = socksPort.map {
                                canConnectThroughSOCKS(node, port: $0, cancellation: cancellation)
                            } ?? connect(node, cancellation: cancellation)
                            continuation.resume(returning: connected)
                        }
                    }
                    await HarborProbeBudget.requests.release(lease)
                    return (node.id, result)
                }
            }
            for index in queue.initialIndices() { submit(index) }
            while let (id, success) = await group.next() {
                if success { reachable.insert(id) }
                if Task.isCancelled || cancellation?.isCancelled == true { group.cancelAll(); break }
                if let index = queue.nextIndex() { submit(index) }
            }
            return reachable
        }
    }

    private static func connect(_ node: HarborProxyNode, cancellation: HarborLatencyCancellation?) -> Bool {
        guard cancellation?.isCancelled != true else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(node.port).bigEndian
        guard inet_pton(AF_INET, node.host, &address.sin_addr) == 1 else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        let deadline = ContinuousClock.now + .seconds(3)
        while ContinuousClock.now < deadline, cancellation?.isCancelled != true {
            var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&pending, 1, 75)
            if ready == 0 || (ready < 0 && errno == EINTR) { continue }
            guard ready > 0, pending.revents & Int16(POLLOUT) != 0 else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
        }
        return false
    }
    private static func canConnectThroughSOCKS(
        _ node: HarborProxyNode, port: Int, cancellation: HarborLatencyCancellation?
    ) -> Bool {
        guard cancellation?.isCancelled != true,
              (1...65_535).contains(port), (1...65_535).contains(node.port) else {
            return false
        }
        var relay = in_addr()
        guard inet_pton(AF_INET, node.host, &relay) == 1 else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { _ = Darwin.close(fd) }
        // A volunteer relay or local SOCKS listener may close mid-handshake.
        // Never let a failed preflight terminate the host app with SIGPIPE.
        var noSIGPIPE: Int32 = 1
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSIGPIPE,
                              socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 3, tv_usec: 0)
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                              socklen_t(MemoryLayout<timeval>.size))
        _ = Darwin.setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                              socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        // SO_RCVTIMEO and SO_SNDTIMEO do not bound a blocking connect().
        // Use the same three-second nonblocking connect deadline as direct
        // preflight, then restore blocking I/O for bounded SOCKS handshakes.
        let flags = Darwin.fcntl(fd, F_GETFL)
        guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            return false
        }
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result != 0 {
            guard errno == EINPROGRESS else { return false }
            var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pending, 1, 3_000) > 0,
                  pending.revents & Int16(POLLOUT) != 0 else { return false }
            var socketError: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            guard Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length) == 0,
                  socketError == 0 else { return false }
        }
        guard cancellation?.isCancelled != true,
              Darwin.fcntl(fd, F_SETFL, flags) == 0,
              sendAll(fd, [5, 1, 0]),
              readExact(fd, count: 2) == [5, 0],
              cancellation?.isCancelled != true else { return false }
        let octets = withUnsafeBytes(of: relay.s_addr) { Array($0) }
        let destinationPort = UInt16(node.port).bigEndian
        let portBytes = withUnsafeBytes(of: destinationPort) { Array($0) }
        guard cancellation?.isCancelled != true,
              sendAll(fd, [5, 1, 0, 1] + octets + portBytes),
              let reply = readExact(fd, count: 2),
              cancellation?.isCancelled != true else { return false }
        return reply == [5, 0]
    }

    private static func sendAll(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
        bytes.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return false }
            var sent = 0
            while sent < buffer.count {
                let count = Darwin.send(fd, base.advanced(by: sent), buffer.count - sent, 0)
                guard count > 0 else { return false }
                sent += count
            }
            return true
        }
    }

    private static func readExact(_ fd: Int32, count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        var received = 0
        while received < count {
            let next = bytes.withUnsafeMutableBytes { buffer in
                Darwin.recv(fd, buffer.baseAddress!.advanced(by: received), count - received, 0)
            }
            guard next > 0 else { return nil }
            received += next
        }
        return bytes
    }
}
