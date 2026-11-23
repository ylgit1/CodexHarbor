import Darwin
import Foundation

public enum HarborProxyCommand {
    public struct Output: Sendable {
        public let status: Int32
        public let data: Data
    }

    private static let queue = DispatchQueue(
        label: "com.codexharbor.proxy.commands", qos: .utility, attributes: .concurrent
    )

    public static func run(
        _ executable: URL, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = 4_096, cancelled: @escaping @Sendable () -> Bool = { false }
    ) async throws -> Output {
        let state = CommandCancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                queue.async {
                    continuation.resume(with: Result {
                        try runBlocking(executable, arguments: arguments, timeout: timeout, outputLimit: outputLimit,
                                        cancelled: { state.isCancelled || cancelled() })
                    })
                }
            }
        } onCancel: {
            state.cancel()
        }
    }

    private final class CommandCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false
        var isCancelled: Bool { lock.withLock { value } }
        func cancel() { lock.withLock { value = true } }
    }

    public static func runBlocking(
        _ executable: URL, arguments: [String], timeout: TimeInterval,
        outputLimit: Int = 4_096, captureDiagnostics: Bool = false,
        environment: [String: String]? = nil, cancelled: () -> Bool = { false }
    ) throws -> Output {
        if cancelled() { throw CancellationError() }
        let process = Process()
        let pipe = Pipe()
        let reader = pipe.fileHandleForReading
        let descriptor = reader.fileDescriptor
        let flags = fcntl(descriptor, F_GETFL)
        guard flags >= 0, fcntl(descriptor, F_SETFL, flags | O_NONBLOCK) == 0 else {
            throw HarborProxyError.invalid("无法初始化子进程输出")
        }
        defer { try? reader.close() }
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = outputLimit > 0 ? pipe : FileHandle.nullDevice
        process.standardError = captureDiagnostics && outputLimit > 0 ? pipe : FileHandle.nullDevice
        try process.run()
        let deadline = ContinuousClock.now + .seconds(timeout)
        var result = Data()
        var buffer = [UInt8](repeating: 0, count: 8_192)
        while true {
            if cancelled() || ContinuousClock.now >= deadline {
                _ = stopBlocking(process)
                if cancelled() { throw CancellationError() }
                throw HarborProxyError.invalid("子进程执行超时")
            }
            let running = process.isRunning
            let count = outputLimit > 0 ? buffer.withUnsafeMutableBytes { bytes in
                Darwin.read(descriptor, bytes.baseAddress, bytes.count)
            } : 0
            if count > 0 {
                guard count <= outputLimit - result.count else {
                    _ = stopBlocking(process)
                    throw HarborProxyError.invalid("子进程输出超过限制")
                }
                result.append(contentsOf: buffer.prefix(count))
                continue
            }
            if count < 0 && errno == EINTR { continue }
            if !running { return Output(status: process.terminationStatus, data: result) }
            Thread.sleep(forTimeInterval: 0.015)
        }
    }

    @discardableResult
    public static func stop(_ process: Process) async -> Bool {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: stopBlocking(process)) }
        }
    }

    @discardableResult
    public static func stopBlocking(_ process: Process) -> Bool {
        guard process.processIdentifier > 0, process.isRunning else { return true }
        process.terminate()
        let graceful = ContinuousClock.now + .milliseconds(750)
        while process.isRunning, ContinuousClock.now < graceful {
            Thread.sleep(forTimeInterval: 0.025)
        }
        if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        let forced = ContinuousClock.now + .seconds(1)
        while process.isRunning, ContinuousClock.now < forced {
            Thread.sleep(forTimeInterval: 0.025)
        }
        return !process.isRunning
    }
}

public enum HarborProxyHTTPBody {
    public static func data(
        for request: URLRequest, configuration: URLSessionConfiguration,
        limit: Int, timeout: TimeInterval, status: Range<Int> = 200..<300
    ) async throws -> (Data, HTTPURLResponse) {
        let loader = Loader(limit: limit, status: status,
                            requireHTTPS: request.url?.scheme?.lowercased() == "https")
        configuration.timeoutIntervalForResource = timeout
        configuration.waitsForConnectivity = false
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(timeout)) } catch { return }
            loader.cancel(with: URLError(.timedOut))
        }
        defer { deadline.cancel() }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                loader.start(request, configuration: configuration, continuation: continuation)
            }
        } onCancel: {
            loader.cancel(with: CancellationError())
        }
    }

    private final class Loader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        typealias ResultContinuation = CheckedContinuation<(Data, HTTPURLResponse), any Error>
        private let lock = NSLock()
        private let limit: Int
        private let status: Range<Int>
        private let requireHTTPS: Bool
        private var data = Data()
        private var response: HTTPURLResponse?
        private var session: URLSession?
        private var continuation: ResultContinuation?
        private var failure: (any Error)?

        init(limit: Int, status: Range<Int>, requireHTTPS: Bool) {
            self.limit = limit
            self.status = status
            self.requireHTTPS = requireHTTPS
        }

        func start(_ request: URLRequest, configuration: URLSessionConfiguration,
                   continuation: ResultContinuation) {
            lock.lock()
            if let failure {
                lock.unlock()
                continuation.resume(throwing: failure)
                return
            }
            self.continuation = continuation
            let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
            self.session = session
            session.dataTask(with: request).resume()
            lock.unlock()
        }

        func cancel(with error: any Error) {
            lock.lock()
            guard failure == nil else { lock.unlock(); return }
            failure = error
            let continuation = self.continuation
            let session = self.session
            self.continuation = nil
            self.session = nil
            lock.unlock()
            session?.invalidateAndCancel()
            continuation?.resume(throwing: error)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
            completionHandler(!requireHTTPS || request.url?.scheme?.lowercased() == "https" ? request : nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                        didReceive response: URLResponse,
                        completionHandler: @escaping @Sendable (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse, status.contains(http.statusCode) else {
                let code = (response as? HTTPURLResponse)?.statusCode ?? 0
                cancel(with: HarborProxyError.invalid("服务器返回无效响应（HTTP \(code)）"))
                completionHandler(.cancel)
                return
            }
            guard response.expectedContentLength <= Int64(limit) else {
                cancel(with: HarborProxyError.invalid("响应内容超过大小限制"))
                completionHandler(.cancel)
                return
            }
            self.response = http
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            guard data.count <= limit - self.data.count else {
                cancel(with: HarborProxyError.invalid("响应内容超过大小限制"))
                return
            }
            self.data.append(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            lock.lock()
            let continuation = self.continuation
            self.continuation = nil
            self.session = nil
            lock.unlock()
            session.finishTasksAndInvalidate()
            guard let continuation else { return }
            if let error { continuation.resume(throwing: error) }
            else if let response { continuation.resume(returning: (data, response)) }
            else { continuation.resume(throwing: URLError(.badServerResponse)) }
        }
    }
}
