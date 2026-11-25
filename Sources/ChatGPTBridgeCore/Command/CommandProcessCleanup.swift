import Darwin
import Foundation

/// Foundation launches commands in a separate process group on macOS.
/// Never signal our own group or an unverified group. Kernel start times
/// protect escalation against PID reuse after the original leader exits.
struct CommandProcessCleanup: Sendable {
    private struct Member: Hashable, Sendable {
        let pid: Int32
        let seconds: UInt64
        let micros: UInt64

        static func capture(_ pid: Int32) -> Member? {
            guard pid > 1 else { return nil }
            var info = proc_bsdinfo()
            let size = Int32(MemoryLayout<proc_bsdinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size,
                  info.pbi_uid == getuid() else { return nil }
            return Member(pid: pid, seconds: info.pbi_start_tvsec, micros: info.pbi_start_tvusec)
        }

        var isCurrent: Bool { Self.capture(pid) == self }
    }

    private let leader: Member?
    private let group: Int32?

    init(_ process: Process) {
        let pid = process.processIdentifier
        leader = Member.capture(pid)
        group = leader != nil && pid > 1 && getpgid(pid) == pid && pid != getpgrp() ? pid : nil
    }

    private func members(of group: Int32) -> Set<Member> {
        let bytes = proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), nil, 0)
        guard bytes > 0, bytes <= 4 * 1024 * 1024 else { return [] }
        var pids = [Int32](repeating: 0, count: Int(bytes) / MemoryLayout<Int32>.stride + 64)
        let count = pids.withUnsafeMutableBytes {
            proc_listpids(UInt32(PROC_PGRP_ONLY), UInt32(group), $0.baseAddress, Int32($0.count))
        }
        guard count > 0 else { return [] }
        return Set(pids.prefix(Int(count) / MemoryLayout<Int32>.stride).compactMap { pid in
            guard getpgid(pid) == group else { return nil }
            return Member.capture(pid)
        })
    }

    /// Cancellation must not cancel cleanup. Use a detached bounded worker
    /// so the cancelling caller still waits for its own children to be signaled.
    func stop(_ process: Process) async {
        let task = Task.detached { [self] in
            if let group, let leader, leader.isCurrent, getpgid(leader.pid) == group {
                let known = members(of: group).union([leader])
                _ = Darwin.kill(-group, SIGTERM)
                try? await Task.sleep(for: .milliseconds(250))
                if known.contains(where: { $0.isCurrent && getpgid($0.pid) == group }) {
                    _ = Darwin.kill(-group, SIGKILL)
                }
                return
            }
            // Fast exits and platforms without an isolated group must not
            // cause a signal to an unrelated process or inherited group.
            guard let leader, leader.isCurrent, process.isRunning else { return }
            _ = Darwin.kill(leader.pid, SIGTERM)
            try? await Task.sleep(for: .milliseconds(250))
            if leader.isCurrent && process.isRunning { _ = Darwin.kill(leader.pid, SIGKILL) }
        }
        await task.value
    }
}
