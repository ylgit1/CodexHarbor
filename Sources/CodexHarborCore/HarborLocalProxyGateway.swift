import Foundation
import Network

/// A fixed loopback-only TCP gateway. Proxy protocol parsing stays in the
/// selected engine, so HTTP CONNECT, ordinary HTTP proxying and SOCKS5 TCP
/// retain their existing authentication, routing and DNS semantics.
public final class HarborLocalProxyGateway: @unchecked Sendable {
    public struct Backend: Equatable, Sendable {
        public let id: UUID
        public let httpPort: UInt16
        public let socksPort: UInt16

        public init(id: UUID = UUID(), httpPort: UInt16, socksPort: UInt16) {
            self.id = id
            self.httpPort = httpPort
            self.socksPort = socksPort
        }
    }

    public enum GatewayError: Error, Equatable {
        case invalidPort, alreadyStarted, listenerFailed, startupTimedOut
        case notReady, recursiveRoute, invalidBackend, backendDraining
    }

    private enum ProtocolKind: Sendable { case http, socks }
    private final class StartRequest: @unchecked Sendable {
        let id = UUID()
        private let lock = NSLock()
        private var cancelled = false
        var isCancelled: Bool { lock.withLock { cancelled } }
        func cancel() { lock.withLock { cancelled = true } }
    }
    private let queue = DispatchQueue(label: "com.codexharbor.proxy.gateway", qos: .utility)
    private let httpPort: UInt16
    private let socksPort: UInt16
    private let connectionLimit: Int
    private let drainSeconds: Int
    private var listeners: [NWListener] = []
    private var readyKinds: Set<ProtocolKind> = []
    private var startContinuation: CheckedContinuation<Void, any Error>?
    private var listenerGeneration = UUID()
    private var backend: Backend?
    private var connections: [UUID: Relay] = [:]
    private var drainTokens: [UUID: UUID] = [:]

    public init(httpPort: Int, connectionLimit: Int = 512, drainSeconds: Int = 60) throws {
        guard (1024...65534).contains(httpPort) else { throw GatewayError.invalidPort }
        self.httpPort = UInt16(httpPort)
        self.socksPort = UInt16(httpPort + 1)
        self.connectionLimit = max(1, min(connectionLimit, 4096))
        self.drainSeconds = max(1, min(drainSeconds, 300))
    }

    /// Returns only once both sockets have bound successfully. Never falls
    /// back to another port or to a wildcard interface.
    public func start() async throws {
        try Task.checkCancellation()
        let request = StartRequest()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                queue.async {
                    guard !request.isCancelled else {
                        continuation.resume(throwing: CancellationError())
                        return
                    }
                    guard self.listeners.isEmpty, self.startContinuation == nil else {
                        continuation.resume(throwing: GatewayError.alreadyStarted)
                        return
                    }
                    let generation = request.id
                    self.listenerGeneration = generation
                    self.startContinuation = continuation
                    do {
                        let http = try self.makeListener(port: self.httpPort, kind: .http, generation: generation)
                        self.listeners.append(http)
                        let socks = try self.makeListener(port: self.socksPort, kind: .socks, generation: generation)
                        self.listeners.append(socks)
                        self.listeners.forEach { $0.start(queue: self.queue) }
                    } catch {
                        self.stopOnQueue(error: GatewayError.listenerFailed)
                        return
                    }
                    self.queue.asyncAfter(deadline: .now() + .seconds(5)) { [weak self] in
                        guard let self, self.listenerGeneration == generation,
                              self.startContinuation != nil else { return }
                        self.stopOnQueue(error: GatewayError.startupTimedOut)
                    }
                }
            }
        } onCancel: {
            request.cancel()
            self.queue.async {
                guard self.listenerGeneration == request.id else { return }
                self.stopOnQueue(error: CancellationError())
            }
        }
        if Task.isCancelled {
            queue.sync {
                if listenerGeneration == request.id { stopOnQueue(error: CancellationError()) }
            }
            throw CancellationError()
        }
    }

    public var isReady: Bool {
        queue.sync { readyKinds.count == 2 && listeners.count == 2 }
    }

    public var activeBackendID: UUID? { queue.sync { backend?.id } }

    /// An atomic route update. Existing TCP sessions never migrate to another
    /// backend. Callers must keep the previous engine alive until drained.
    @discardableResult
    public func route(to target: Backend, closeOldConnections: Bool = false) throws -> Backend? {
        try queue.sync {
            guard readyKinds.count == 2 else { throw GatewayError.notReady }
            guard target.httpPort != 0, target.socksPort != 0,
                  target.httpPort != target.socksPort else { throw GatewayError.invalidBackend }
            let entry = Set([httpPort, socksPort])
            guard !entry.contains(target.httpPort), !entry.contains(target.socksPort) else {
                throw GatewayError.recursiveRoute
            }
            if let current = backend, current.id == target.id, current != target {
                throw GatewayError.invalidBackend
            }
            // A validated previous backend can be restored during rollback.
            // Invalidate its old drain deadline before making it active again.
            drainTokens.removeValue(forKey: target.id)
            let previous = backend
            backend = target
            if let previous, previous.id != target.id {
                beginDrain(previous.id, immediate: closeOldConnections)
            }
            return previous
        }
    }

    /// Stops accepting new flows without permitting any direct fallback.
    public func suspendRouting(closeExisting: Bool = false) {
        queue.sync {
            if let old = backend {
                backend = nil
                beginDrain(old.id, immediate: closeExisting)
            }
        }
    }

    public func connectionCount(backendID: UUID) -> Int {
        queue.sync { connections.values.filter { $0.backendID == backendID }.count }
    }

    public func closeConnections(backendID: UUID) {
        queue.sync { closeFlows(backendID) }
    }

    public func stop() {
        queue.sync { stopOnQueue(error: CancellationError()) }
    }

    private func makeListener(port: UInt16, kind: ProtocolKind, generation: UUID) throws -> NWListener {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        let listener = try NWListener(using: parameters)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self, self.listenerGeneration == generation else { return }
            switch state {
            case .ready:
                self.readyKinds.insert(kind)
                if self.readyKinds.count == 2 {
                    self.startContinuation?.resume()
                    self.startContinuation = nil
                }
            case .failed, .cancelled:
                self.stopOnQueue(error: GatewayError.listenerFailed)
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] client in
            guard let self, self.listenerGeneration == generation else { client.cancel(); return }
            self.accept(client, kind: kind)
        }
        return listener
    }

    private func accept(_ client: NWConnection, kind: ProtocolKind) {
        guard readyKinds.count == 2, let backend, connections.count < connectionLimit else {
            client.cancel()
            return
        }
        let port = kind == .http ? backend.httpPort : backend.socksPort
        let upstream = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        let id = UUID()
        let relay = Relay(backendID: backend.id, client: client, upstream: upstream, queue: queue,
                          socks: kind == .socks, forbiddenPorts: [httpPort, socksPort, backend.httpPort],
                          backendSOCKSPort: backend.socksPort,
                          allowUDP: { [weak self] in
                              guard let self else { return false }
                              return self.connections.values.filter(\.hasUDPAssociation).count < min(64, self.connectionLimit)
                          }) { [weak self] in
            guard let self, let closed = self.connections.removeValue(forKey: id) else { return }
            if self.drainTokens[closed.backendID] != nil,
               !self.connections.values.contains(where: { $0.backendID == closed.backendID }) {
                self.drainTokens.removeValue(forKey: closed.backendID)
            }
        }
        connections[id] = relay
        relay.start()
    }

    private func beginDrain(_ id: UUID, immediate: Bool) {
        guard connections.values.contains(where: { $0.backendID == id }) else { return }
        if immediate {
            closeFlows(id)
            return
        }
        let token = UUID()
        drainTokens[id] = token
        queue.asyncAfter(deadline: .now() + .seconds(drainSeconds)) { [weak self] in
            guard let self, self.drainTokens[id] == token else { return }
            self.closeFlows(id)
        }
    }

    private func closeFlows(_ id: UUID) {
        let closing = connections.values.filter { $0.backendID == id }
        closing.forEach { $0.close() }
        drainTokens.removeValue(forKey: id)
    }

    private func stopOnQueue(error: any Error) {
        listenerGeneration = UUID()
        startContinuation?.resume(throwing: error)
        startContinuation = nil
        backend = nil
        readyKinds.removeAll()
        listeners.forEach { $0.cancel() }
        listeners.removeAll()
        Array(connections.values).forEach { $0.close() }
        drainTokens.removeAll()
    }

    /// All state is confined to the gateway's serial queue. Each direction
    /// keeps at most one 32 KiB receive/send outstanding; read resumes only
    /// after the opposite socket has consumed the send.
    private final class Relay: @unchecked Sendable {
        let backendID: UUID
        private let client: NWConnection
        private let upstream: NWConnection
        private let queue: DispatchQueue
        private let onClose: @Sendable () -> Void
        private let socks: Bool
        private let forbiddenPorts: Set<UInt16>
        private let backendSOCKSPort: UInt16
        private let allowUDP: @Sendable () -> Bool
        private var udpRelay: HarborSOCKS5UDPRelay?
        var hasUDPAssociation: Bool { udpRelay != nil }
        private var clientReady = false
        private var upstreamReady = false
        private var pumping = false
        private var negotiating = false
        private var closed = false
        private var completedDirections = 0

        init(backendID: UUID, client: NWConnection, upstream: NWConnection,
             queue: DispatchQueue, socks: Bool, forbiddenPorts: Set<UInt16>,
             backendSOCKSPort: UInt16, allowUDP: @escaping @Sendable () -> Bool,
             onClose: @escaping @Sendable () -> Void) {
            self.backendID = backendID
            self.socks = socks
            self.forbiddenPorts = forbiddenPorts
            self.backendSOCKSPort = backendSOCKSPort
            self.allowUDP = allowUDP
            self.client = client
            self.upstream = upstream
            self.queue = queue
            self.onClose = onClose
        }

        func start() {
            client.stateUpdateHandler = { [weak self] state in self?.handle(state, clientSide: true) }
            upstream.stateUpdateHandler = { [weak self] state in self?.handle(state, clientSide: false) }
            client.start(queue: queue)
            upstream.start(queue: queue)
            queue.asyncAfter(deadline: .now() + .seconds(10)) { [weak self] in
                guard let self, !self.pumping, !self.negotiating else { return }
                self.close()
            }
        }

        private func handle(_ state: NWConnection.State, clientSide: Bool) {
            guard !closed else { return }
            switch state {
            case .ready:
                if clientSide { clientReady = true } else { upstreamReady = true }
                if clientReady && upstreamReady && !pumping && !negotiating {
                    if socks { negotiateSOCKS() } else { startPumping() }
                }
            case .failed, .cancelled: close()
            default: break
            }
        }

        private func startPumping() {
            guard !closed, !pumping else { return }
            negotiating = false
            pumping = true
            pump(from: client, to: upstream)
            pump(from: upstream, to: client)
        }

        // Parse exactly the bounded SOCKS control exchange. Reading only the
        // specified bytes also preserves any pipelined TCP application data.
        private func readExact(_ source: NWConnection, count: Int,
                               completion: @escaping @Sendable (Data) -> Void) {
            guard !closed, (1...258).contains(count) else { close(); return }
            source.receive(minimumIncompleteLength: count, maximumLength: count) { [weak self] data, _, eof, error in
                guard let self, !self.closed else { return }
                guard error == nil, let data, data.count == count, !eof else { self.close(); return }
                completion(data)
            }
        }

        private func write(_ data: Data, to destination: NWConnection,
                           completion: @escaping @Sendable () -> Void) {
            guard !closed else { return }
            destination.send(content: data, completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close() } else { completion() }
            })
        }

        private func readFrame(_ source: NWConnection, completion: @escaping @Sendable (Data) -> Void) {
            readExact(source, count: 4) { [weak self] header in
                guard let self, header[0] == 5, header[2] == 0 else { self?.close(); return }
                switch header[3] {
                case 1:
                    self.readExact(source, count: 6) { body in completion(header + body) }
                case 4:
                    self.readExact(source, count: 18) { body in completion(header + body) }
                case 3:
                    self.readExact(source, count: 1) { [weak self] length in
                        guard let self, length[0] != 0 else { self?.close(); return }
                        self.readExact(source, count: Int(length[0]) + 2) { body in
                            completion(header + length + body)
                        }
                    }
                default: self.close()
                }
            }
        }

        private func negotiateSOCKS() {
            negotiating = true
            queue.asyncAfter(deadline: .now() + .seconds(30)) { [weak self] in
                guard let self, self.negotiating else { return }
                self.close()
            }
            readExact(client, count: 2) { [weak self] greeting in
                guard let self, greeting[0] == 5, greeting[1] > 0 else { self?.close(); return }
                self.readExact(self.client, count: Int(greeting[1])) { [weak self] methods in
                    guard let self else { return }
                    // Generated engine inbounds use loopback no-auth. Do not
                    // pass credentials or negotiate unexpected authentication.
                    guard methods.contains(0) else {
                        self.write(Data([5, 255]), to: self.client) { [weak self] in self?.close() }
                        return
                    }
                    self.write(Data([5, 1, 0]), to: self.upstream) { [weak self] in
                        guard let self else { return }
                        self.readExact(self.upstream, count: 2) { [weak self] reply in
                            guard let self else { return }
                            guard reply == Data([5, 0]) else {
                                self.write(Data([5, 255]), to: self.client) { [weak self] in self?.close() }
                                return
                            }
                            self.write(reply, to: self.client) { [weak self] in self?.readSOCKSRequest() }
                        }
                    }
                }
            }
        }

        private func rejectSOCKS(_ code: UInt8) {
            write(HarborSOCKS5Frame.failure(code), to: client) { [weak self] in self?.close() }
        }

        private func readSOCKSRequest() {
            readFrame(client) { [weak self] request in
                guard let self else { return }
                guard let command = HarborSOCKS5Frame.command(request),
                      let address = HarborSOCKS5Frame.parseAddress(request) else {
                    self.rejectSOCKS(7); return
                }
                switch command {
                case .bind:
                    self.rejectSOCKS(7); return
                case .connect:
                    guard address.port != 0,
                          !(address.isLoopback && (self.forbiddenPorts.contains(address.port) || address.port == self.backendSOCKSPort)) else {
                        self.rejectSOCKS(2); return
                    }
                case .udpAssociate:
                    guard address.isLocalAssociation, self.allowUDP(),
                          let peer = self.clientPeerHost,
                          address.isUnspecified || HarborIPAddress.equivalent(address.host, peer)
                            || (address.host.lowercased() == "localhost" && peer == "127.0.0.1") else {
                        self.rejectSOCKS(2); return
                    }
                }
                let forwarded = command == .udpAssociate ? HarborSOCKS5Frame.udpAssociationRequest() : request
                self.write(forwarded, to: self.upstream) { [weak self] in
                    guard let self else { return }
                    self.readFrame(self.upstream) { [weak self] response in
                        guard let self, HarborSOCKS5Frame.parseAddress(response) != nil else { self?.close(); return }
                        if response[1] != 0 {
                            self.write(response, to: self.client) { [weak self] in self?.close() }
                            return
                        }
                        if command == .udpAssociate {
                            self.startUDPAssociation(response: response, requestedPort: address.port)
                        } else {
                            self.write(response, to: self.client) { [weak self] in self?.startPumping() }
                        }
                    }
                }
            }
        }

        private var clientPeerHost: String? {
            guard case .hostPort(let host, _) = client.endpoint else { return nil }
            return HarborIPAddress.normalizedLiteral(String(describing: host))
        }

        private func startUDPAssociation(response: Data, requestedPort: UInt16) {
            guard allowUDP(), let peer = clientPeerHost,
                  HarborSOCKS5Frame.permitsUDPReply(response, forbiddenPorts: forbiddenPorts),
                  let target = HarborSOCKS5Frame.parseAddress(response),
                  let relay = HarborSOCKS5UDPRelay(peerHost: peer, requestedPort: requestedPort,
                      upstream: target, forbiddenPorts: forbiddenPorts, queue: queue) else {
                rejectSOCKS(7); return
            }
            udpRelay = relay
            relay.start()
            write(HarborSOCKS5Frame.loopbackReply(port: relay.port), to: client) { [weak self] in
                guard let self, !self.closed else { return }
                self.negotiating = false
                self.pumping = true
                // No TCP payload is defined after UDP ASSOCIATE. Either
                // control socket closing retires both UDP sockets immediately.
                self.watchUDPControl(self.client)
                self.watchUDPControl(self.upstream)
            }
        }

        private func watchUDPControl(_ connection: NWConnection) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, _, _ in
                self?.close()
            }
        }

        private func pump(from source: NWConnection, to destination: NWConnection) {
            guard !closed else { return }
            source.receive(minimumIncompleteLength: 1, maximumLength: 32_768) { [weak self] data, _, eof, error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                if let data, !data.isEmpty {
                    destination.send(content: data, completion: .contentProcessed { [weak self] error in
                        guard let self, !self.closed else { return }
                        if error != nil { self.close() }
                        else if eof { self.halfClose(destination) }
                        else { self.pump(from: source, to: destination) }
                    })
                } else if eof {
                    self.halfClose(destination)
                } else {
                    self.pump(from: source, to: destination)
                }
            }
        }

        private func halfClose(_ destination: NWConnection) {
            destination.send(content: nil, contentContext: .finalMessage, isComplete: true,
                             completion: .contentProcessed { [weak self] error in
                guard let self, !self.closed else { return }
                if error != nil { self.close(); return }
                self.completedDirections += 1
                if self.completedDirections == 2 { self.close() }
            })
        }

        func close() {
            guard !closed else { return }
            closed = true
            udpRelay?.close()
            udpRelay = nil
            client.cancel()
            upstream.cancel()
            onClose()
        }
    }
}
