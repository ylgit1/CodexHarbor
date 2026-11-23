import CodexHarborCore
import Darwin
import Foundation

actor HarborProbeBudget {
    static let engines = HarborProbeBudget(limit: HarborProxyLatencyPolicy.temporaryEngineLimit)
    static let requests = HarborProbeBudget(limit: HarborProxyLatencyPolicy.probeRequestLimit)

    private let limit: Int
    private var held: Set<UUID> = []
    private var waiting: [(UUID, CheckedContinuation<UUID?, Never>)] = []

    init(limit: Int) { self.limit = limit }

    func acquire(_ cancellation: HarborLatencyCancellation? = nil) async -> UUID? {
        guard !Task.isCancelled, cancellation?.isCancelled != true else { return nil }
        let id = UUID()
        let observer = cancellation?.observe { Task { await self.withdraw(id) } }
        defer { if let observer { cancellation?.removeObserver(observer) } }
        let granted: UUID? = await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled || cancellation?.isCancelled == true {
                    continuation.resume(returning: nil)
                } else if held.count < limit {
                    held.insert(id)
                    continuation.resume(returning: id)
                } else {
                    waiting.append((id, continuation))
                }
            }
        } onCancel: {
            Task { await self.withdraw(id) }
        }
        if let granted, Task.isCancelled || cancellation?.isCancelled == true {
            release(granted)
            return nil
        }
        return granted
    }

    func release(_ id: UUID) {
        guard held.remove(id) != nil, !waiting.isEmpty else { return }
        let (next, continuation) = waiting.removeFirst()
        held.insert(next)
        continuation.resume(returning: next)
    }

    private func withdraw(_ id: UUID) {
        guard let index = waiting.firstIndex(where: { $0.0 == id }) else { return }
        waiting.remove(at: index).1.resume(returning: nil)
    }
}

enum HarborProbeFiles {
    static func write(_ data: Data, to file: URL) throws {
        guard FileManager.default.createFile(atPath: file.path, contents: nil,
                                             attributes: [.posixPermissions: 0o600]) else {
            throw HarborProxyError.invalid("无法创建私有代理配置")
        }
        do { try data.write(to: file) }
        catch {
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
        try? Data(String(process.processIdentifier).utf8).write(to: recordURL(for: config), options: .atomic)
    }

    static func remove(_ config: URL) {
        try? FileManager.default.removeItem(at: config)
        try? FileManager.default.removeItem(at: recordURL(for: config))
    }

    private static func recordURL(for config: URL) -> URL { config.appendingPathExtension("pid") }

    static func cleanOrphans(root: URL) async {
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
            guard let info = try? config.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey]),
                  info.isRegularFile == true, let modified = info.contentModificationDate else { continue }
            let recordedPID = (try? String(contentsOf: recordURL(for: config), encoding: .utf8)).flatMap(Int32.init)
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
                alive = !(await stopOrphan(pid, config: config, root: root)) || alive
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

    private static func stopOrphan(_ pid: Int32, config: URL, root: URL) async -> Bool {
        func stillOwned() async -> Bool {
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
        guard pid > 1, await stillOwned() else { return Darwin.kill(pid, 0) != 0 }
        _ = Darwin.kill(pid, SIGTERM)
        try? await Task.sleep(for: .milliseconds(250))
        if Darwin.kill(pid, 0) == 0, await stillOwned() {
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
