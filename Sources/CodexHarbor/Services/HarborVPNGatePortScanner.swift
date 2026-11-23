import CodexHarborCore
import Darwin
import Foundation

/// TCP reachability only prioritizes candidate attempts. It cannot mark an
/// OpenVPN node usable, and a direct failure does not block alternate routes.
enum HarborVPNGatePortScanner {
    static func reachableIDs(_ nodes: [HarborProxyNode],
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
                            continuation.resume(returning: connect(node, cancellation: cancellation))
                        }
                    }
                    await HarborProbeBudget.requests.release(lease)
                    return (node.id, result)
                }
            }
            for index in queue.initialIndices() { submit(index) }
            while let (id, success) = await group.next() {
                if Task.isCancelled || cancellation?.isCancelled == true { group.cancelAll(); break }
                if success { reachable.insert(id) }
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
}
