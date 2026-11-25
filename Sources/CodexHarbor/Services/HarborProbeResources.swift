import CodexHarborCore
import Darwin
import Foundation

enum HarborProbePriority: Int, Sendable, Comparable {
    case geoIP = 0, screening, manual, health, switching, recovery, safety
    static func < (lhs: Self, rhs: Self) -> Bool { lhs.rawValue < rhs.rawValue }
}

/// Task-local priorities propagate through structured child tasks, without
/// making the caller take a second resource permit for each helper.
enum HarborProbeScope {
    @TaskLocal static var priority: HarborProbePriority = .screening
}

actor HarborProbeBudget {
    static let engines = HarborProbeBudget(limit: HarborProxyLatencyPolicy.temporaryEngineLimit, reserved: 1)
    static let requests = HarborProbeBudget(limit: HarborProxyLatencyPolicy.probeRequestLimit, reserved: 2)

    private struct Waiter {
        let id: UUID
        let count: Int
        let priority: HarborProbePriority
        let cancellation: HarborLatencyCancellation?
        let continuation: CheckedContinuation<[UUID]?, Never>
    }

    private let limit: Int
    private let reserved: Int
    private let queueLimit = 128
    private var held: Set<UUID> = []
    private var waiting: [Waiter] = []

    init(limit: Int, reserved: Int = 0) {
        self.limit = max(1, limit)
        self.reserved = max(0, min(reserved, limit - 1))
    }

    func acquire(_ cancellation: HarborLatencyCancellation? = nil,
                 priority: HarborProbePriority = HarborProbeScope.priority) async -> UUID? {
        await acquireGroup(1, cancellation: cancellation, priority: priority)?.first
    }

    /// All permits for a dependent engine chain are granted together. Never
    /// retain one engine permit while waiting for another from the same pool.
    func acquireGroup(_ count: Int, cancellation: HarborLatencyCancellation? = nil,
                      priority: HarborProbePriority = HarborProbeScope.priority) async -> [UUID]? {
        let capacity = priority >= .health ? limit : limit - reserved
        guard (1...capacity).contains(count), !Task.isCancelled,
              cancellation?.isCancelled != true else { return nil }
        let id = UUID()
        let observer = cancellation?.observe { Task { await self.withdraw(id) } }
        defer { if let observer { cancellation?.removeObserver(observer) } }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            self.withdraw(id)
        }
        defer { deadline.cancel() }
        let granted: [UUID]? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled, cancellation?.isCancelled != true else {
                    continuation.resume(returning: nil)
                    return
                }
                if waiting.count >= queueLimit {
                    if let index = waiting.lastIndex(where: { $0.priority < priority }) {
                        waiting.remove(at: index).continuation.resume(returning: nil)
                    } else {
                        continuation.resume(returning: nil)
                        return
                    }
                }
                waiting.append(Waiter(id: id, count: count, priority: priority,
                                      cancellation: cancellation, continuation: continuation))
                dispatch()
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
        if let granted, Task.isCancelled || cancellation?.isCancelled == true {
            for lease in granted { held.remove(lease) }
            dispatch()
            return nil
        }
        return granted
    }

    func release(_ id: UUID) {
        guard held.remove(id) != nil else { return }
        dispatch()
    }

    private func withdraw(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.id == id }) else { return }
        waiting.remove(at: index).continuation.resume(returning: nil)
        dispatch()
    }

    private func dispatch() {
        while !waiting.isEmpty {
            // FIFO within priority. Do not let lower priority work consume
            // the capacity a higher priority grouped request is waiting for.
            guard let highest = waiting.map(\.priority).max(),
                  let index = waiting.firstIndex(where: { $0.priority == highest }) else { return }
            let next = waiting[index]
            if next.cancellation?.isCancelled == true {
                waiting.remove(at: index).continuation.resume(returning: nil)
                continue
            }
            let capacity = next.priority >= .health ? limit : limit - reserved
            guard held.count + next.count <= capacity else { return }
            waiting.remove(at: index)
            let permits = (0..<next.count).map { _ in UUID() }
            held.formUnion(permits)
            next.continuation.resume(returning: permits)
        }
    }
}

enum HarborProbeFiles {
    static func write(_ data: Data, to file: URL) throws {
        // Exclusive creation prevents overwriting an existing file or
        // following a symlink at the destination. Permissions are private
        // from the first write, not applied after the credentials reach disk.
        let descriptor = Darwin.open(file.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else {
            throw HarborProxyError.invalid("无法创建私有代理配置")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
            try? FileManager.default.removeItem(at: file)
            throw error
        }
    }

    static func replace(_ data: Data, at destination: URL) throws {
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".proxy-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        try write(data, to: staged)
        guard Darwin.rename(staged.path, destination.path) == 0 else {
            throw HarborProxyError.invalid("无法保存代理进程状态")
        }
    }

    static func record(_ process: Process, config: URL) {
        let identity = HarborProcessIdentity.capture(pid: process.processIdentifier)
        let data = identity.flatMap { try? JSONEncoder().encode($0) }
            ?? Data(String(process.processIdentifier).utf8)
        try? replace(data, at: recordURL(for: config))
    }

    static func remove(_ config: URL) {
        try? FileManager.default.removeItem(at: config)
        try? FileManager.default.removeItem(at: recordURL(for: config))
        if config.lastPathComponent.hasPrefix("probe-runtime-") {
            try? FileManager.default.removeItem(at: config.deletingPathExtension().appendingPathExtension("data"))
        }
    }

    private static func recordURL(for config: URL) -> URL { config.appendingPathExtension("pid") }

    static func cleanOrphans(root: URL, protectedPaths: Set<String> = []) async {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]
        ) else { return }
        let processList = try? await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
            arguments: ["-axww", "-o", "pid=", "-o", "ppid=", "-o", "command="],
            timeout: 2, outputLimit: 2_000_000)
        guard let processList, processList.status == 0 else { return }
        let processes = String(decoding: processList.data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        for config in files where config.lastPathComponent.hasPrefix("probe-") && config.pathExtension == "json" {
            guard !protectedPaths.contains(config.path) else { continue }
            guard let info = try? config.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  info.isRegularFile == true, let modified = info.contentModificationDate else { continue }
            let record = try? Data(contentsOf: recordURL(for: config))
            let recordedIdentity = record.flatMap { try? JSONDecoder().decode(HarborProcessIdentity.self, from: $0) }
            let recordedPID = recordedIdentity?.pid ?? record.flatMap { Int32(String(decoding: $0, as: UTF8.self)) }
            let owned = processes.compactMap { line -> (Int32, Int32)? in
                let fields = line.split(maxSplits: 2, whereSeparator: \.isWhitespace)
                guard fields.count == 3, let pid = Int32(fields[0]), let parent = Int32(fields[1]),
                      ["xray", "mihomo"].contains(where: { binary in
                          fields[2].hasPrefix(root.appendingPathComponent(binary).path + " ")
                      }), (fields[2].hasSuffix(" -config " + config.path)
                           || fields[2].hasSuffix(" -f " + config.path)) else { return nil }
                return (pid, parent)
            }
            var alive = false
            for (pid, parent) in owned {
                guard parent == 1, recordedPID == nil || pid == recordedPID else { alive = true; continue }
                alive = !(await stopOrphan(pid, config: config, root: root, recorded: recordedIdentity)) || alive
            }
            if !alive, !owned.isEmpty || Date.now.timeIntervalSince(modified) > 3_600 {
                remove(config)
            }
        }
        for log in files where log.lastPathComponent.hasPrefix("probe-") && log.pathExtension == "log" {
            if let modified = try? log.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
               Date.now.timeIntervalSince(modified) > 86_400 {
                try? FileManager.default.removeItem(at: log)
            }
        }
    }

    private static func stopOrphan(_ pid: Int32, config: URL, root: URL,
                                   recorded: HarborProcessIdentity?) async -> Bool {
        guard let identity = HarborProcessIdentity.capture(pid: pid),
              recorded == nil || recorded == identity else { return Darwin.kill(pid, 0) != 0 }
        func stillOwned() async -> Bool {
            guard identity.isCurrent else { return false }
            guard let info = try? await HarborProxyCommand.run(URL(fileURLWithPath: "/bin/ps"),
                arguments: ["-ww", "-p", String(pid), "-o", "ppid=", "-o", "command="], timeout: 1),
                  info.status == 0 else { return false }
            let fields = String(decoding: info.data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .split(maxSplits: 1, whereSeparator: \.isWhitespace)
            guard fields.count == 2, fields[0] == "1" else { return false }
            return ["xray", "mihomo"].contains {
                fields[1].hasPrefix(root.appendingPathComponent($0).path + " ")
            } && (fields[1].hasSuffix(" -config " + config.path) || fields[1].hasSuffix(" -f " + config.path))
        }
        guard pid > 1, await stillOwned(), identity.isCurrent else { return Darwin.kill(pid, 0) != 0 }
        _ = Darwin.kill(pid, SIGTERM)
        try? await Task.sleep(for: .milliseconds(250))
        if Darwin.kill(pid, 0) == 0, await stillOwned(), identity.isCurrent {
            _ = Darwin.kill(pid, SIGKILL)
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Darwin.kill(pid, 0) != 0
    }
}

/// A temporary child keeps writing to a drained pipe, with only its latest
/// bytes in memory. A broken node cannot fill the disk with engine messages.
final class HarborProbeDiagnostics: @unchecked Sendable {
    let pipe = Pipe()
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var tail = Data()
    private let capacity = 16_384

    init?() {
        let reader = pipe.fileHandleForReading
        let descriptor = reader.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else { return nil }
        source = DispatchSource.makeReadSource(fileDescriptor: descriptor,
                                                queue: DispatchQueue.global(qos: .utility))
        source.setEventHandler { [weak self] in self?.drain(descriptor) }
        source.setCancelHandler { try? reader.close() }
        source.resume()
    }

    deinit { source.cancel() }

    func indicatesAuthenticationFailure() -> Bool {
        lock.withLock { tail.range(of: Data("AUTH_FAILED".utf8)) != nil }
    }

    private func drain(_ descriptor: Int32) {
        var buffer = [UInt8](repeating: 0, count: 4_096)
        for _ in 0..<8 {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(descriptor, $0.baseAddress, $0.count) }
            if count == 0 { source.cancel(); return }
            if count < 0 {
                if errno == EINTR { continue }
                if errno != EAGAIN && errno != EWOULDBLOCK { source.cancel() }
                return
            }
            lock.withLock {
                tail.append(contentsOf: buffer.prefix(count))
                let excess = tail.count - capacity
                if excess > 0 { tail.removeFirst(excess) }
            }
        }
    }
}
