import Darwin
import Foundation

/// A nonblocking TCP connect can return EINPROGRESS even for a healthy
/// localhost listener. Wait a small, bounded interval and check SO_ERROR.
public enum HarborLoopbackTCP {
    public static func isListening(_ port: Int) -> Bool {
        guard (1...65_535).contains(port) else { return false }
        let fd = Darwin.socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = UInt16(port).bigEndian
        address.sin_addr = in_addr(s_addr: in_addr_t(INADDR_LOOPBACK).bigEndian)
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if result == 0 { return true }
        guard errno == EINPROGRESS || errno == EINTR else { return false }
        let deadline = ContinuousClock.now + .milliseconds(50)
        while ContinuousClock.now < deadline {
            let remaining = ContinuousClock.now.duration(to: deadline).components
            let milliseconds = remaining.seconds * 1_000 + remaining.attoseconds / 1_000_000_000_000_000
            var pending = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            let ready = Darwin.poll(&pending, 1, Int32(max(1, min(50, milliseconds + 1))))
            if ready < 0 && errno == EINTR { continue }
            guard ready > 0, pending.revents & Int16(POLLOUT) != 0 else { return false }
            var error: Int32 = 0
            var length = socklen_t(MemoryLayout<Int32>.size)
            return Darwin.getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 && error == 0
        }
        return false
    }
}
