import Darwin
import Foundation

/// A PID is only an index, not a process identity. Capture the kernel's
/// microsecond start timestamp and executable path before signaling it.
public struct HarborProcessIdentity: Codable, Equatable, Sendable {
    public let pid: Int32
    public let startSeconds: UInt64
    public let startMicroseconds: UInt64
    public let executablePath: String

    public static func capture(pid: Int32) -> Self? {
        guard pid > 1 else { return nil }
        var info = proc_bsdinfo()
        let expected = Int32(MemoryLayout<proc_bsdinfo>.size)
        let count = withUnsafeMutablePointer(to: &info) {
            proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, $0, expected)
        }
        guard count == expected else { return nil }
        var path = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = path.withUnsafeMutableBufferPointer {
            proc_pidpath(pid, $0.baseAddress, UInt32($0.count))
        }
        guard length > 0 else { return nil }
        let executable = path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        guard !executable.isEmpty else { return nil }
        return Self(pid: pid, startSeconds: info.pbi_start_tvsec,
                    startMicroseconds: info.pbi_start_tvusec,
                    executablePath: String(decoding: executable, as: UTF8.self))
    }

    /// proc_pidpath uses kernel-canonical paths, which can differ from
    /// Foundation's URL normalization (notably /var versus /private/var).
    public func matchesExecutable(at url: URL) -> Bool {
        guard let resolved = realpath(url.path, nil) else { return false }
        defer { free(resolved) }
        return executablePath == String(cString: resolved)
    }

    public var isCurrent: Bool {
        Self.capture(pid: pid) == self
    }
}
