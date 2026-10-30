import CodexHarborCore
import Darwin
import Foundation

/// A short TCP preflight only improves probe order. A reachable socket is not
/// an OpenVPN handshake, an HTTPS exit, or proof of residential ownership.
enum HarborVPNGatePortScanner {
    static func rank(_ nodes: [HarborProxyNode]) async -> [HarborProxyNode] {
        let targets = Array(nodes.filter { $0.network == "tcp" }.prefix(64))
        guard !targets.isEmpty else { return nodes }
        var reachable = Set<String>()
        var queue = HarborProxyLatencyQueue(count: targets.count, limit: 8)
        await withTaskGroup(of: (String, Bool).self) { group in
            for index in queue.initialIndices() {
                let node = targets[index]
                group.addTask { (node.id, await canConnect(node)) }
            }
            while let (id, success) = await group.next() {
                if success { reachable.insert(id) }
                if let index = queue.nextIndex() {
                    let node = targets[index]
                    group.addTask { (node.id, await canConnect(node)) }
                }
            }
        }
        return nodes.filter { reachable.contains($0.id) }
            + nodes.filter { !reachable.contains($0.id) }
    }

    private static func canConnect(_ node: HarborProxyNode) async -> Bool {
        await Task.detached(priority: .utility) {
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
}
