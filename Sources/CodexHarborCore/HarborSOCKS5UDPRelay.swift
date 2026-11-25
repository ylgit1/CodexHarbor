import Darwin
import Foundation

/// One bounded SOCKS5 UDP association. The TCP control channel owns this
/// object, so a switch/drain/close never leaves a separate active relay.
/// Both sockets are loopback-only; only the negotiated engine endpoint can
/// send replies. All mutable state belongs to the gateway's serial queue.
final class HarborSOCKS5UDPRelay: @unchecked Sendable {
    let port: UInt16
    private let front: Int32
    private let back: Int32
    private let queue: DispatchQueue
    private let peerAddress: in_addr_t
    private let requestedPort: UInt16
    private let forbiddenPorts: Set<UInt16>
    private var clientAddress: sockaddr_in?
    private var frontSource: DispatchSourceRead?
    private var backSource: DispatchSourceRead?
    private var closed = false
    private var buffer = [UInt8](repeating: 0, count: 65_535)

    init?(peerHost: String, requestedPort: UInt16, upstream: HarborSOCKS5Frame.Address,
          forbiddenPorts: Set<UInt16>, queue: DispatchQueue) {
        var peer = in_addr()
        guard peerHost.withCString({ inet_pton(AF_INET, $0, &peer) }) == 1,
              HarborGatewayConfiguration.isLoopback(peerHost),
              upstream.isLoopback, !upstream.isUnspecified, upstream.port != 0,
              !forbiddenPorts.contains(upstream.port) else { return nil }
        guard let front = Self.socket(AF_INET) else { return nil }
        var bindAddress = Self.ipv4("127.0.0.1", port: 0)!
        guard withUnsafePointer(to: &bindAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(front, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }) == 0 else { Darwin.close(front); return nil }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        guard withUnsafeMutablePointer(to: &bindAddress, {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(front, $0, &length) }
        }) == 0 else { Darwin.close(front); return nil }
        let localPort = UInt16(bigEndian: bindAddress.sin_port)
        guard localPort != 0, let back = Self.upstreamSocket(upstream) else {
            Darwin.close(front); return nil
        }
        self.port = localPort
        self.front = front
        self.back = back
        self.queue = queue
        self.peerAddress = peer.s_addr
        self.requestedPort = requestedPort
        self.forbiddenPorts = forbiddenPorts.union([upstream.port, localPort])
    }

    private static func socket(_ family: Int32) -> Int32? {
        let fd = Darwin.socket(family, SOCK_DGRAM, IPPROTO_UDP)
        guard fd >= 0 else { return nil }
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0, fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else {
            Darwin.close(fd); return nil
        }
        return fd
    }

    private static func ipv4(_ host: String, port: UInt16) -> sockaddr_in? {
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = port.bigEndian
        guard host.withCString({ inet_pton(AF_INET, $0, &address.sin_addr) }) == 1 else { return nil }
        return address
    }

    private static func upstreamSocket(_ upstream: HarborSOCKS5Frame.Address) -> Int32? {
        let host = upstream.host.lowercased() == "localhost" ? "127.0.0.1" : upstream.host
        if var remote = ipv4(host, port: upstream.port) {
            guard let fd = socket(AF_INET) else { return nil }
            var local = ipv4("127.0.0.1", port: 0)!
            let bound = withUnsafePointer(to: &local) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            let connected = withUnsafePointer(to: &remote) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
            guard bound == 0, connected == 0 else { Darwin.close(fd); return nil }
            return fd
        }
        guard host == "::1", let fd = socket(AF_INET6) else { return nil }
        var remote = sockaddr_in6()
        remote.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        remote.sin6_family = sa_family_t(AF_INET6)
        remote.sin6_port = upstream.port.bigEndian
        remote.sin6_addr = in6addr_loopback
        var local = remote
        local.sin6_port = 0
        let bound = withUnsafePointer(to: &local) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        let connected = withUnsafePointer(to: &remote) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
            }
        }
        guard bound == 0, connected == 0 else { Darwin.close(fd); return nil }
        return fd
    }

    func start() {
        guard !closed, frontSource == nil else { return }
        let inbound = DispatchSource.makeReadSource(fileDescriptor: front, queue: queue)
        let outbound = DispatchSource.makeReadSource(fileDescriptor: back, queue: queue)
        inbound.setEventHandler { [weak self] in self?.readClient() }
        outbound.setEventHandler { [weak self] in self?.readEngine() }
        let frontFD = front, backFD = back
        inbound.setCancelHandler { Darwin.close(frontFD) }
        outbound.setCancelHandler { Darwin.close(backFD) }
        frontSource = inbound
        backSource = outbound
        inbound.resume()
        outbound.resume()
    }

    private func readClient() {
        guard !closed else { return }
        // Bound work per readiness event to avoid starving TCP forwarding.
        for _ in 0..<32 {
            var source = sockaddr_in()
            var length = socklen_t(MemoryLayout<sockaddr_in>.size)
            let count = buffer.withUnsafeMutableBytes { bytes in
                withUnsafeMutablePointer(to: &source) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        recvfrom(front, bytes.baseAddress, bytes.count, 0, $0, &length)
                    }
                }
            }
            guard count >= 0 else { return }
            guard count > 0, source.sin_family == sa_family_t(AF_INET),
                  source.sin_addr.s_addr == peerAddress,
                  requestedPort == 0 || source.sin_port == requestedPort.bigEndian,
                  clientAddress == nil || clientAddress?.sin_port == source.sin_port else { continue }
            let data = Data(buffer.prefix(count))
            guard let target = HarborSOCKS5Frame.udpDestination(data),
                  !(target.isLoopback && forbiddenPorts.contains(target.port)) else { continue }
            if clientAddress == nil { clientAddress = source }
            data.withUnsafeBytes { bytes in
                _ = Darwin.send(back, bytes.baseAddress, bytes.count, 0)
            }
        }
    }

    private func readEngine() {
        guard !closed else { return }
        for _ in 0..<32 {
            let count = buffer.withUnsafeMutableBytes { recv(back, $0.baseAddress, $0.count, 0) }
            guard count >= 0 else { return }
            guard count > 0, var destination = clientAddress else { continue }
            let data = Data(buffer.prefix(count))
            guard HarborSOCKS5Frame.udpDestination(data) != nil else { continue }
            data.withUnsafeBytes { bytes in
                withUnsafePointer(to: &destination) {
                    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(front, bytes.baseAddress, bytes.count, 0, $0,
                                   socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }
    }

    func close() {
        guard !closed else { return }
        closed = true
        if let frontSource { frontSource.cancel() } else { Darwin.close(front) }
        if let backSource { backSource.cancel() } else { Darwin.close(back) }
        frontSource = nil
        backSource = nil
    }

    deinit { close() }
}
