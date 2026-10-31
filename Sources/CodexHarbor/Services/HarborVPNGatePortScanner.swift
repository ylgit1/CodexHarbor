import CodexHarborCore
import Darwin
import Foundation

/// A short TCP preflight only improves probe order. A reachable socket is not
/// an OpenVPN handshake, an HTTPS exit, or proof of residential ownership.
enum HarborVPNGatePortScanner {
    static func rank(_ nodes: [HarborProxyNode], socksPort: Int? = nil) async -> [HarborProxyNode] {
        let targets = Array(nodes.filter { $0.network == "tcp" }.prefix(64))
        guard !targets.isEmpty else { return nodes }
        let reachable = await reachableIDs(targets, socksPort: socksPort)
        return nodes.filter { reachable.contains($0.id) }
            + nodes.filter { !reachable.contains($0.id) }
    }

    static func reachableIDs(_ nodes: [HarborProxyNode], socksPort: Int?,
                             cancellation: HarborLatencyCancellation? = nil) async -> Set<String> {
        let targets = nodes.filter { $0.network == "tcp" }
        var reachable = Set<String>()
        var queue = HarborProxyLatencyQueue(count: targets.count, limit: 8)
        await withTaskGroup(of: (String, Bool).self) { group in
            for index in queue.initialIndices() {
                let node = targets[index]
                group.addTask {
                    guard cancellation?.isCancelled != true else { return (node.id, false) }
                    return (node.id, await canConnect(node, socksPort: socksPort))
                }
            }
            while let (id, success) = await group.next() {
                if cancellation?.isCancelled == true { group.cancelAll(); break }
                if success { reachable.insert(id) }
                if let index = queue.nextIndex() {
                    let node = targets[index]
                    group.addTask {
                        guard cancellation?.isCancelled != true else { return (node.id, false) }
                        return (node.id, await canConnect(node, socksPort: socksPort))
                    }
                }
            }
        }
        return reachable
    }

    private static func canConnect(_ node: HarborProxyNode, socksPort: Int?) async -> Bool {
        await Task.detached(priority: .utility) {
            if let socksPort { return canConnectThroughSOCKS(node, port: socksPort) }
            var address = sockaddr_in()
            address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            address.sin_family = sa_family_t(AF_INET)
            address.sin_port = UInt16(node.port).bigEndian
            guard inet_pton(AF_INET, node.host, &address.sin_addr) == 1 else { return false }
            let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { return false }
            defer { _ = Darwin.close(fd) }
            let flags = Darwin.fcntl(fd, F_GETFL)
            guard flags >= 0, Darwin.fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
                return false
            }
            let result = withUnsafePointer(to: &address) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            if result == 0 { return true }
            guard errno == EINPROGRESS else { return false }
            var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            guard Darwin.poll(&pending, 1, 3_000) > 0,
                  pending.revents & Int16(POLLOUT) != 0 else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0
                && error == 0
        }.value
    }

    private static func canConnectThroughSOCKS(_ node: HarborProxyNode, port: Int) -> Bool {
        guard (1...65_535).contains(port), (1...65_535).contains(node.port) else { return false }
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
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard connected, sendAll(fd, [5, 1, 0]), readExact(fd, count: 2) == [5, 0] else {
            return false
        }
        let octets = withUnsafeBytes(of: relay.s_addr) { Array($0) }
        let destinationPort = UInt16(node.port).bigEndian
        let portBytes = withUnsafeBytes(of: destinationPort) { Array($0) }
        guard sendAll(fd, [5, 1, 0, 1] + octets + portBytes),
              let reply = readExact(fd, count: 2) else { return false }
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
