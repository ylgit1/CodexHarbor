import Foundation
import CodexHarborCore

enum QuotaAgentFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {
        if case let .message(value) = self { return value }
        return nil
    }
}

struct UsageCardConfiguration: Codable, Sendable {
    let enabled: Bool
    let position: String
}

struct UsageCardReport: Codable {
    let state: String
    let detail: String
    let updatedAt: Date
    let remainingFiveHours: Double?
    let remainingWeekly: Double?
}

enum UsageCardPaths {
    static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/CodexHarbor/UsageCard", isDirectory:true)
    static let settings = directory.appendingPathComponent("configuration.json")
    static let status = directory.appendingPathComponent("status.json")
}

/// Only its own lock protects streaming data; the readability callback is Sendable.
private final class RateLimitReply: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var result: Data?
    private var completed = false
    private let writer: FileHandle
    private let signal: DispatchSemaphore
    private let method: String
    private let params: [String: Any]
    private var serverError: String?

    init(writer: FileHandle, signal: DispatchSemaphore,
         method: String, params: [String: Any]) {
        self.writer = writer
        self.signal = signal
        self.method = method
        self.params = params
    }

    func send(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        writer.write(data + Data([10]))
    }

    func accept(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 10) {
            let line = Data(buffer[..<newline])
            buffer.removeSubrange(...newline)
            guard let message = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any],
                  let id = message["id"] as? Int else { continue }
            if id == 1 {
                send(["method":"initialized","params":[:]])
                send(["id":2,"method":method,"params":params])
            } else if id == 2 && !completed {
                completed = true
                if let error = message["error"] as? [String: Any] {
                    serverError = String(describing: error["message"] ?? "Codex 服务拒绝请求")
                } else if let payload = message["result"] as? [String: Any] {
                    result = try? JSONSerialization.data(withJSONObject:payload)
                }
                signal.signal()
            }
        }
    }

    func response() throws -> Data {
        lock.lock()
        defer { lock.unlock() }
        if let serverError {
            throw QuotaAgentFailure.message(serverError)
        }
        guard let result else {
            throw QuotaAgentFailure.message("Codex 服务未返回有效响应")
        }
        return result
    }
}

final class CodexQuotaReader {
    private static func codexExecutable() -> String? {
        let candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex-cli/bin/codex",
            "/Applications/Codex.app/Contents/Resources/codex-cli/bin/codex",
            "/opt/homebrew/bin/codex", "/usr/local/bin/codex"
        ]
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) })
    }

    /// Starts the official app-server on local stdio; no browser cookies, tokens or chat history.
    private static func request(
        method: String, params: [String: Any], timeout: TimeInterval
    ) throws -> Data {
        guard let executable = codexExecutable() else {
            throw QuotaAgentFailure.message("没有找到 Codex 命令行程序")
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = ["app-server"]
        let input = Pipe(), output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        let completion = DispatchSemaphore(value: 0)
        let reply = RateLimitReply(
            writer: input.fileHandleForWriting, signal: completion,
            method: method, params: params
        )
        output.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if !chunk.isEmpty { reply.accept(chunk) }
        }
        reply.send(["id": 1, "method": "initialize",
                    "params": ["clientInfo": ["name": "codexharbor", "title": "Codex Harbor", "version": "1.0"]]])
        let finished = completion.wait(timeout: .now() + timeout) == .success
        output.fileHandleForReading.readabilityHandler = nil
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        guard finished else {
            throw QuotaAgentFailure.message("Codex 额度服务请求超时")
        }
        return try reply.response()
    }

    static func read(timeout: TimeInterval = 25) throws -> CodexQuotaSnapshot {
        let data = try request(method: "account/rateLimits/read", params: [:], timeout: timeout)
        guard let snapshot = CodexQuotaSnapshot.parse(data: data) else {
            throw QuotaAgentFailure.message("当前账户没有返回可用的 5 小时/每周额度")
        }
        return snapshot
    }


}

enum UsageCardAgent {
    static func report(state: String, detail: String, snapshot: CodexQuotaSnapshot?) {
        let status = UsageCardReport(
            state:state, detail:detail, updatedAt:Date(),
            remainingFiveHours:snapshot?.fiveHours?.remainingPercent,
            remainingWeekly:snapshot?.weekly?.remainingPercent
        )
        try? FileManager.default.createDirectory(at: UsageCardPaths.directory, withIntermediateDirectories:true)
        if let data = try? JSONEncoder().encode(status) {
            try? data.write(to: UsageCardPaths.status, options:.atomic)
        }
    }

    static func configuration() -> UsageCardConfiguration? {
        guard let data = try? Data(contentsOf:UsageCardPaths.settings) else { return nil }
        return try? JSONDecoder().decode(UsageCardConfiguration.self, from:data)
    }
}

let arguments = Array(CommandLine.arguments.dropFirst())
switch arguments.first {
case "--read":
    do {
        let snapshot = try CodexQuotaReader.read()
        let data = try JSONEncoder().encode(snapshot)
        print(String(decoding:data,as:UTF8.self))
    } catch {
        fputs("额度读取失败：\(error.localizedDescription)\n",stderr)
        exit(1)
    }
case "--notch-preview":
    NotchUsageCoordinator(preview: true).run()
default:
    NotchUsageCoordinator().run()
}
