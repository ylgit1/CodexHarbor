import CodexHarborCore
import Darwin
import Foundation

/// Persistent authenticated XPC control connection to the resident proxy
/// runtime. Never touches the separate ChatGPT Bridge launch agent.
@MainActor
final class HarborProxyAgentClient {
    static let shared = HarborProxyAgentClient()

    enum Failure: LocalizedError {
        case helperMissing, registrationFailed, disconnected, timeout, invalidReply, remote(String)
        var errorDescription: String? {
            switch self {
            case .helperMissing: "安装包缺少独立代理服务"
            case .registrationFailed: "无法注册用户级代理服务"
            case .disconnected: "代理服务控制连接已断开"
            case .timeout: "代理服务控制请求超时，需重新核对运行状态"
            case .invalidReply: "代理服务返回无效响应"
            case .remote("SWITCH_VERIFICATION_FAILED"): "新线路通过固定入口的验证失败，未提交切换"
            case .remote("SWITCH_ROLLBACK_FAILED"): "新线路验证失败，旧线路未能恢复；已暂停转发"
            case .remote(let code): "代理服务操作失败（\(code)）"
            }
        }
    }

    private final class ReplyGate: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Data, any Error>?
        private var result: Result<Data, any Error>?
        func attach(_ value: CheckedContinuation<Data, any Error>) {
            let early = lock.withLock { () -> Result<Data, any Error>? in
                if let result { return result }
                continuation = value
                return nil
            }
            if let early { value.resume(with: early) }
        }
        func finish(_ value: Result<Data, any Error>) {
            let target = lock.withLock { () -> CheckedContinuation<Data, any Error>? in
                guard result == nil else { return nil }
                result = value
                defer { continuation = nil }
                return continuation
            }
            target?.resume(with: value)
        }
    }

    private var connection: NSXPCConnection?
    private var connectionID: UUID?
    private var registering: Task<Void, any Error>?
    private var heartbeatTask: Task<Void, Never>?

    private var plistURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
            .appendingPathComponent(HarborProxyAgentConstants.label + ".plist")
    }
    private var domain: String { "gui/\(getuid())" }

    private func ensureRegistered() async throws {
        if let registering { return try await registering.value }
        let task = Task { try await self.registerIfNeeded() }
        registering = task
        defer { registering = nil }
        try await task.value
    }

    private func registerIfNeeded() async throws {
        let target = domain + "/" + HarborProxyAgentConstants.label
        let executable = URL(fileURLWithPath: "/bin/launchctl")
        let status = try? await HarborProxyCommand.run(executable, arguments: ["print", target], timeout: 3, outputLimit: 0)
        if status?.status == 0 { return }

        let helper = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/HarborProxyAgent")
        guard FileManager.default.isExecutableFile(atPath: helper.path) else { throw Failure.helperMissing }
        // Fail before registration if the helper has a different signer or
        // identifier. The same requirement is enforced on the XPC channel.
        do {
            try HarborAgentSigningRequirement.verifyPeer(at: helper, identifier: HarborProxyAgentConstants.label)
        } catch {
            throw Failure.registrationFailed
        }
        try FileManager.default.createDirectory(at: plistURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let plist: [String: Any] = [
            "Label": HarborProxyAgentConstants.label,
            "ProgramArguments": [helper.path],
            "MachServices": [HarborProxyAgentConstants.label: true],
            "RunAtLoad": false,
            "KeepAlive": ["PathState": [HarborProxyAgentConstants.activeMarker.path: true]],
            "ProcessType": "Background", "ThrottleInterval": 10
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try HarborProbeFiles.replace(data, at: plistURL)
        let bootstrap = try await HarborProxyCommand.run(executable,
            arguments: ["bootstrap", domain, plistURL.path], timeout: 5, outputLimit: 0)
        if bootstrap.status != 0 {
            let checked = try? await HarborProxyCommand.run(executable, arguments: ["print", target], timeout: 3, outputLimit: 0)
            guard checked?.status == 0 else { throw Failure.registrationFailed }
        }
    }

    private func connect() async throws -> NSXPCConnection {
        if let connection { return connection }
        try await ensureRegistered()
        if let connection { return connection }
        let current = NSXPCConnection(machServiceName: HarborProxyAgentConstants.label, options: [])
        try HarborAgentSigningRequirement.authenticate(current, identifier: HarborProxyAgentConstants.label)
        current.remoteObjectInterface = NSXPCInterface(with: HarborProxyAgentRPC.self)
        let id = UUID()
        current.invalidationHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.invalidate(id) }
        }
        current.interruptionHandler = { [weak self] in
            Task { @MainActor [weak self] in self?.invalidate(id) }
        }
        connectionID = id
        connection = current
        current.resume()
        heartbeatTask = Task { @MainActor [weak self] in
            // Run on the UI actor itself so a stalled UI actually loses its
            // lease. Never reconnect from an obsolete heartbeat.
            while !Task.isCancelled {
                do { try await Task.sleep(for: HarborProxyControllerLease.heartbeatInterval) }
                catch { return }
                guard let self, self.connectionID == id else { return }
                guard HarborProxyManager.shared.canMaintainResidentProxy else { continue }
                _ = try? await self.call(.heartbeat)
            }
        }
        return current
    }

    private func invalidate(_ id: UUID) {
        guard connectionID == id else { return }
        connectionID = nil
        heartbeatTask?.cancel()
        heartbeatTask = nil
        let old = connection
        connection = nil
        old?.invalidate()
    }

    func disconnect() {
        if let id = connectionID { invalidate(id) }
    }

    func call(_ command: HarborProxyAgentCommand) async throws -> HarborProxyAgentReply {
        try Task.checkCancellation()
        let activeConnection = try await connect()
        try Task.checkCancellation()
        let activeConnectionID = connectionID
        let request = try JSONEncoder().encode(HarborProxyAgentRequest(command))
        guard request.count <= HarborProxyAgentConstants.messageLimit else {
            throw Failure.invalidReply
        }

        let responseData: Data
        do {
            // Keep the continuation lifecycle separate from decoding. This
            // also avoids a Swift 6.3.3 Release optimizer ownership-check crash
            // when an optional snapshot is inspected in the same async SIL.
            responseData = try await perform(request, over: activeConnection)
        } catch {
            if let activeConnectionID {
                invalidate(activeConnectionID)
            }
            throw error
        }

        return try Self.decodeReply(responseData)
    }

    private func perform(_ request: Data, over connection: NSXPCConnection) async throws -> Data {
        let gate = ReplyGate()
        let deadline = Task {
            do {
                try await Task.sleep(for: .seconds(15))
            } catch {
                return
            }
            gate.finish(.failure(Failure.timeout))
        }
        defer { deadline.cancel() }

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Data, any Error>) in
                gate.attach(continuation)
                guard !Task.isCancelled else { return }
                guard let proxy = connection.remoteObjectProxyWithErrorHandler({ _ in
                    gate.finish(.failure(Failure.disconnected))
                }) as? HarborProxyAgentRPC else {
                    gate.finish(.failure(Failure.disconnected))
                    return
                }
                proxy.perform(request) { response in
                    gate.finish(.success(response))
                }
            }
        } onCancel: {
            gate.finish(.failure(CancellationError()))
        }
    }

    private static func decodeReply(_ data: Data) throws -> HarborProxyAgentReply {
        guard data.count <= HarborProxyAgentConstants.messageLimit else {
            throw Failure.invalidReply
        }

        let reply: HarborProxyAgentReply
        do {
            reply = try JSONDecoder().decode(HarborProxyAgentReply.self, from: data)
        } catch {
            throw Failure.invalidReply
        }

        if let snapshot = reply.snapshot,
           snapshot.version != HarborProxyAgentConstants.protocolVersion {
            throw Failure.invalidReply
        }
        if let errorCode = reply.errorCode {
            throw Failure.remote(errorCode)
        }
        return reply
    }

    func inspect() async throws -> HarborProxyAgentSnapshot {
        guard let snapshot = try await call(.inspect).snapshot else { throw Failure.invalidReply }
        return snapshot
    }
}

/// App-side handle for an agent-owned fixed listener. All IPC is bounded and
/// asynchronous; packet forwarding never runs on the SwiftUI main actor.
@MainActor
final class HarborAgentGateway {
    let port: Int
    private let client = HarborProxyAgentClient.shared
    private(set) var isReady = false
    private(set) var routingBackendID: UUID?

    init(httpPort: Int) throws {
        port = try HarborProxyPortPolicy.validate(httpPort: httpPort)
    }

    func start() async throws {
        let reply = try await client.call(.openGateway(port: port))
        guard let snapshot = reply.snapshot else { throw HarborProxyAgentClient.Failure.invalidReply }
        refresh(snapshot)
        guard isReady else { throw HarborProxyAgentClient.Failure.disconnected }
    }

    func refresh(_ snapshot: HarborProxyAgentSnapshot) {
        let entry = snapshot.gateways.first(where: { $0.port == port })
        isReady = entry?.ready == true
        routingBackendID = isReady ? entry?.routingBackendID : nil
    }

    func route(to route: HarborProxyAgentRoute, closeOldConnections: Bool = false,
               cancellation: HarborLatencyCancellation? = nil) async throws {
        let request = Task { try await client.call(.commit(port: port, route: route, closeOld: closeOldConnections)) }
        let observer = cancellation?.observe { request.cancel() }
        defer { if let observer { cancellation?.removeObserver(observer) } }
        do {
            let reply = try await withTaskCancellationHandler {
                try await request.value
            } onCancel: { request.cancel() }
            guard let snapshot = reply.snapshot,
                  snapshot.gateways.contains(where: {
                      $0.port == port && $0.ready && $0.route?.primaryID == route.primaryID
                          && $0.routingBackendID == route.primaryID
                  }) else { throw HarborProxyAgentClient.Failure.invalidReply }
            refresh(snapshot)
        } catch {
            // Durable intent alone is not proof of a live route. Reconcile
            // both the journal and the actual forwarding target.
            if !Task.isCancelled, let snapshot = try? await client.inspect() {
                refresh(snapshot)
                if snapshot.gateways.contains(where: {
                    $0.port == port && $0.ready && $0.route?.primaryID == route.primaryID
                        && $0.routingBackendID == route.primaryID
                }) { return }
            }
            throw error
        }
    }

    func suspendRouting(closeExisting: Bool = false) async {
        if let snapshot = try? await client.call(.suspend(port: port, closeExisting: closeExisting)).snapshot {
            refresh(snapshot)
        } else if let snapshot = try? await client.inspect() {
            refresh(snapshot)
        } else {
            routingBackendID = nil
        }
    }

    func connectionCount(backendID: UUID) async -> Int? {
        try? await client.call(.connectionCount(port: port, backendID: backendID)).count
    }

    @discardableResult
    func closeConnections(backendID: UUID) async -> Bool {
        (try? await client.call(.closeConnections(port: port, backendID: backendID))) != nil
    }

    @discardableResult
    func stop() async -> Bool {
        do {
            let reply = try await client.call(.stopGateway(port: port))
            guard let snapshot = reply.snapshot else { return false }
            refresh(snapshot)
            return !snapshot.gateways.contains(where: { $0.port == port })
        } catch {
            if let snapshot = try? await client.inspect() {
                refresh(snapshot)
                return !snapshot.gateways.contains(where: { $0.port == port })
            }
            return false
        }
    }
}
