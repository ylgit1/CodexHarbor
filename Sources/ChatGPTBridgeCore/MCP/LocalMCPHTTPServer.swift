import Foundation
import Network

private struct LocalHTTPRequest {
    let method: String
    let path: String
    let headers: [String: String]
    let body: Data
}

private struct LocalHTTPResponse {
    let statusCode: Int
    let headers: [String: String]
    let body: Data
}

public final class LocalMCPHTTPServer: @unchecked Sendable {
    public static let host = "127.0.0.1"
    public static let maximumRequestBytes = 8 * 1_024 * 1_024

    private let server: MCPServer
    private let accessToken: String?
    private let publicAccessToken: String?
    private let onPublicClientInitialized: (@Sendable () -> Void)?
    private let queue = DispatchQueue(label: "com.codexharbor.chatgptbridge.mcp", qos: .userInitiated)
    private let lock = NSLock()
    private var listener: NWListener?
    private var boundPort: UInt16?

    public init(
        server: MCPServer,
        accessToken: String? = nil,
        publicAccessToken: String? = nil,
        onPublicClientInitialized: (@Sendable () -> Void)? = nil
    ) {
        self.server = server
        self.accessToken = accessToken?.isEmpty == false ? accessToken : nil
        self.publicAccessToken = publicAccessToken?.isEmpty == false ? publicAccessToken : nil
        self.onPublicClientInitialized = onPublicClientInitialized
    }

    public var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return boundPort
    }

    public var localURL: URL? {
        guard let port else { return nil }
        return URL(string: "http://\(Self.host):\(port)/mcp")
    }

    @discardableResult
    public func start(preferredPort: UInt16? = nil) throws -> UInt16 {
        lock.lock()
        if let existingPort = boundPort {
            lock.unlock()
            return existingPort
        }
        lock.unlock()

        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listenPort: NWEndpoint.Port = preferredPort.flatMap(NWEndpoint.Port.init(rawValue:)) ?? .any
        parameters.requiredLocalEndpoint = .hostPort(
            host: NWEndpoint.Host(Self.host),
            port: listenPort
        )

        let listener = try NWListener(using: parameters)
        let started = DispatchSemaphore(value: 0)
        let state = LocalMCPListenerStartState()
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { listenerState in
            switch listenerState {
            case .ready:
                state.setPort(listener.port?.rawValue)
                started.signal()
            case .failed(let error):
                state.setError(error)
                started.signal()
            default:
                break
            }
        }
        listener.start(queue: queue)

        guard started.wait(timeout: .now() + 2) == .success else {
            listener.cancel()
            throw BridgeError.writeFailed("MCP 本地服务启动超时")
        }
        if let error = state.error {
            listener.cancel()
            let portDescription = preferredPort.map(String.init) ?? "自动端口"
            throw BridgeError.writeFailed(
                "MCP 本地服务无法监听 127.0.0.1:\(portDescription)：\(error.localizedDescription)。请关闭占用该端口的程序后重试。"
            )
        }
        guard let readyPort = state.port else {
            listener.cancel()
            throw BridgeError.writeFailed("MCP 本地服务没有获得监听端口")
        }

        lock.lock()
        self.listener = listener
        self.boundPort = readyPort
        lock.unlock()
        return readyPort
    }

    public func stop() {
        lock.lock()
        let listener = self.listener
        self.listener = nil
        self.boundPort = nil
        lock.unlock()
        listener?.cancel()
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: queue)
        receive(on: connection, buffer: Data())
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_048_576) { [weak self] data, _, complete, error in
            guard let self else { return }
            var next = buffer
            if let data { next.append(data) }

            if next.count > Self.maximumRequestBytes {
                self.send(Self.errorResponse(413, "Request too large"), on: connection)
                return
            }

            if let request = Self.parseRequest(next) {
                Task {
                    let response = await self.handle(request)
                    self.send(response, on: connection)
                }
            } else if !complete && error == nil {
                self.receive(on: connection, buffer: next)
            } else {
                self.send(Self.errorResponse(400, "Invalid HTTP request"), on: connection)
            }
        }
    }

    private func handle(_ request: LocalHTTPRequest) async -> LocalHTTPResponse {
        if request.method == "GET", request.path == "/health" {
            let body = (try? JSONSerialization.data(withJSONObject: [
                "status": "ok",
                "protocolVersion": MCPProtocolVersion.modern,
                "host": Self.host,
                "port": port as Any
            ])) ?? Data("{}".utf8)
            return LocalHTTPResponse(
                statusCode: 200,
                headers: ["Content-Type": "application/json"],
                body: body
            )
        }

        let publicCompatibilityPath = publicAccessToken.map { "/mcp/\($0)" }
        let authenticatedByPath = publicCompatibilityPath == request.path
        guard request.path == "/mcp" || authenticatedByPath else {
            return Self.errorResponse(404, "Not found")
        }

        if request.method == "GET", authenticatedByPath {
            return LocalHTTPResponse(
                statusCode: 200,
                headers: [
                    "Content-Type": "text/event-stream",
                    "X-Accel-Buffering": "no"
                ],
                body: Data(": codex-harbor-ready\n\n".utf8)
            )
        }

        guard request.method == "POST" else {
            return Self.errorResponse(405, "Method not allowed")
        }
        guard request.headers["content-type"]?.lowercased().contains("application/json") == true else {
            return Self.errorResponse(415, "Content-Type must be application/json")
        }
        if let accessToken, !authenticatedByPath {
            guard request.headers["x-harbor-bridge-token"] == accessToken else {
                return Self.errorResponse(401, "Invalid local Bridge token")
            }
        }

        let decodedRequest = try? JSONDecoder().decode(MCPJSONRPCRequest.self, from: request.body)
        let incomingSessionID = request.headers["mcp-session-id"]
        let sessionID = incomingSessionID ?? (decodedRequest?.method == "initialize" ? UUID().uuidString : nil)
        if authenticatedByPath,
           let method = decodedRequest?.method,
           method == "initialize" || method == "notifications/initialized" {
            onPublicClientInitialized?()
        }
        if authenticatedByPath,
           decodedRequest?.method == "notifications/initialized",
           decodedRequest?.id == nil {
            return LocalHTTPResponse(statusCode: 202, headers: [:], body: Data())
        }

        let methodHeader = request.headers["mcp-method"] ?? (authenticatedByPath ? decodedRequest?.method : nil)
        guard let methodHeader, !methodHeader.isEmpty else {
            return Self.errorResponse(400, "Missing Mcp-Method header")
        }

        var protocolVersion = request.headers["mcp-protocol-version"]
        if authenticatedByPath, protocolVersion == nil {
            if methodHeader == "initialize" || methodHeader == "notifications/initialized" {
                protocolVersion = MCPProtocolVersion.legacy
            } else if methodHeader != "server/discover" {
                protocolVersion = MCPProtocolVersion.modern
            }
        }
        if methodHeader != "server/discover",
           methodHeader != "initialize",
           methodHeader != "notifications/initialized",
           !MCPProtocolVersion.supported.contains(protocolVersion ?? "") {
            return Self.errorResponse(400, "Missing or unsupported MCP-Protocol-Version header")
        }

        let nameHeader = request.headers["mcp-name"]
            ?? (authenticatedByPath && methodHeader == "tools/call"
                ? decodedRequest?.params?["name"]?.stringValue
                : nil)
        if methodHeader == "tools/call", nameHeader?.isEmpty != false {
            return Self.errorResponse(400, "Missing Mcp-Name header")
        }

        let body = await server.handle(
            data: request.body,
            context: MCPRequestContext(
                protocolVersion: protocolVersion,
                methodHeader: methodHeader,
                nameHeader: nameHeader,
                approvalGranted: false,
                sessionID: sessionID
            )
        )
        var responseHeaders = ["Content-Type": "application/json"]
        if let sessionID {
            responseHeaders["Mcp-Session-Id"] = sessionID
        }
        return LocalHTTPResponse(
            statusCode: 200,
            headers: responseHeaders,
            body: body
        )
    }

    private func send(_ response: LocalHTTPResponse, on connection: NWConnection) {
        let reason = HTTPURLResponse.localizedString(forStatusCode: response.statusCode)
        var headers = response.headers
        headers["Content-Length"] = "\(response.body.count)"
        headers["Connection"] = "close"
        headers["Cache-Control"] = "no-store"
        let headerText = (["HTTP/1.1 \(response.statusCode) \(reason)"] +
            headers.sorted(by: { $0.key < $1.key }).map { "\($0.key): \($0.value)" } +
            ["", ""]).joined(separator: "\r\n")
        var data = Data(headerText.utf8)
        data.append(response.body)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func parseRequest(_ data: Data) -> LocalHTTPRequest? {
        let separator = Data("\r\n\r\n".utf8)
        guard let headerRange = data.range(of: separator) else { return nil }
        let headerData = data[..<headerRange.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else { return nil }
        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return nil }
        let requestParts = requestLine.split(separator: " ")
        guard requestParts.count >= 2 else { return nil }

        let headers = lines.dropFirst().reduce(into: [String: String]()) { result, line in
            guard let colon = line.firstIndex(of: ":") else { return }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces).lowercased()
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            result[key] = value
        }
        guard headers["transfer-encoding"] == nil else { return nil }
        let contentLength = Int(headers["content-length"] ?? "0") ?? -1
        guard contentLength >= 0, contentLength <= maximumRequestBytes else { return nil }
        let bodyStart = headerRange.upperBound
        guard data.count >= bodyStart + contentLength else { return nil }

        return LocalHTTPRequest(
            method: String(requestParts[0]),
            path: String(requestParts[1]),
            headers: headers,
            body: data.subdata(in: bodyStart..<(bodyStart + contentLength))
        )
    }

    private static func errorResponse(_ code: Int, _ message: String) -> LocalHTTPResponse {
        let body = (try? JSONSerialization.data(withJSONObject: [
            "error": ["message": message, "type": "harbor_mcp_http_error"]
        ])) ?? Data()
        return LocalHTTPResponse(
            statusCode: code,
            headers: ["Content-Type": "application/json"],
            body: body
        )
    }
}

private final class LocalMCPListenerStartState: @unchecked Sendable {
    private let lock = NSLock()
    private var storedPort: UInt16?
    private var storedError: NWError?

    var port: UInt16? {
        lock.lock()
        defer { lock.unlock() }
        return storedPort
    }

    var error: NWError? {
        lock.lock()
        defer { lock.unlock() }
        return storedError
    }

    func setPort(_ port: UInt16?) {
        lock.lock()
        storedPort = port
        lock.unlock()
    }

    func setError(_ error: NWError) {
        lock.lock()
        storedError = error
        lock.unlock()
    }
}
