import AppKit
import CodexHarborCore
import CryptoKit
import Foundation
import Network
import Security

/// Browser OAuth with a loopback callback. Pending credentials stay in memory until imported.
@MainActor
final class AccountLoginSessionManager {
    private let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    private var listener: NWListener?
    private var exchangeTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?
    private var pendingAuthentication: Data?
    private var failure: String?
    private var state = ""
    private var verifier = ""
    private var generation = UUID()
    private(set) var previousAccountID: UUID?
    var isActive: Bool { listener != nil || pendingAuthentication != nil }

    func start(previousAccountID: UUID?) async throws {
        guard !isActive else { return }
        await finish()
        failure = nil
        state = try randomValue()
        verifier = try randomValue()
        generation = UUID()
        let sessionID = generation
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: 1455)
        let server = try NWListener(using: parameters)
        listener = server
        self.previousAccountID = previousAccountID
        server.newConnectionHandler = { [weak self] connection in
            Task { @MainActor in self?.receive(connection, sessionID: sessionID) }
        }
        do {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                server.stateUpdateHandler = { status in
                    switch status {
                    case .ready:
                        server.stateUpdateHandler = nil
                        continuation.resume()
                    case .failed:
                        server.stateUpdateHandler = nil
                        continuation.resume(throwing: HarborError.invalidConfiguration("无法启动登录回调，端口 1455 可能被占用，请结束其他登录后重试"))
                    default: break
                    }
                }
                server.start(queue: .main)
            }
            var url = URLComponents(string: "https://auth.openai.com/oauth/authorize")!
            let values = [
                "response_type": "code", "client_id": clientID,
                "redirect_uri": "http://127.0.0.1:1455/auth/callback",
                "scope": "openid profile email offline_access",
                "code_challenge": base64URL(Data(SHA256.hash(data: Data(verifier.utf8)))),
                "code_challenge_method": "S256", "state": state,
                "id_token_add_organizations": "true", "codex_cli_simplified_flow": "true",
                "originator": "codex_cli_rs"
            ]
            url.queryItems = values.map { URLQueryItem(name: $0.key, value: $0.value) }
            guard let authorizationURL = url.url, NSWorkspace.shared.open(authorizationURL) else {
                throw HarborError.invalidConfiguration("无法打开浏览器，请检查默认浏览器设置")
            }
            timeoutTask = Task { [weak self] in
                do { try await Task.sleep(for: .seconds(600)) } catch { return }
                guard let self, self.generation == sessionID else { return }
                self.failure = "登录已超时，请取消后重新添加账户"
                self.listener?.cancel()
                self.listener = nil
                self.exchangeTask?.cancel()
            }
        } catch {
            await finish()
            throw error
        }
    }

    private func receive(_ connection: NWConnection, sessionID: UUID, buffer: Data = Data()) {
        if buffer.isEmpty { connection.start(queue: .main) }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 8192) { [weak self] data, _, complete, error in
            Task { @MainActor in
                guard let self, self.generation == sessionID else { connection.cancel(); return }
                var bytes = buffer
                if let data { bytes.append(data) }
                guard bytes.count <= 16384, error == nil else { connection.cancel(); return }
                guard bytes.range(of: Data("\r\n\r\n".utf8)) != nil else {
                    if complete { connection.cancel() } else { self.receive(connection, sessionID: sessionID, buffer: bytes) }
                    return
                }
                let parts = String(decoding: bytes, as: UTF8.self).components(separatedBy: "\r\n")[0].split(separator: " ")
                guard parts.count == 3, parts[0] == "GET",
                      let url = URLComponents(string: "http://127.0.0.1:1455" + String(parts[1])),
                      url.path == "/auth/callback" else {
                    self.respond(connection, status: 404, message: "Not found"); return
                }
                let items = url.queryItems ?? []
                func value(_ key: String) -> String? {
                    let matching = items.filter { $0.name == key }
                    return matching.count == 1 ? matching[0].value : nil
                }
                guard value("state") == self.state else {
                    self.respond(connection, status: 400, message: "Invalid login state"); return
                }
                guard self.exchangeTask == nil else {
                    self.respond(connection, status: 409, message: "Login already received"); return
                }
                guard value("error") == nil, let code = value("code"), !code.isEmpty else {
                    self.failure = "官方授权未完成或已取消，请取消后重试"
                    self.respond(connection, status: 400, message: "Authorization failed. Return to Harbor.")
                    return
                }
                self.respond(connection, status: 200, message: "Authorization received. Return to Codex Harbor to finish adding your account.")
                self.exchangeTask = Task { [weak self] in
                    guard let self else { return }
                    do {
                        let credentials = try await self.exchange(code: code)
                        guard !Task.isCancelled, self.generation == sessionID else { return }
                        self.pendingAuthentication = credentials
                        self.timeoutTask?.cancel()
                        self.listener?.cancel()
                        self.listener = nil
                    } catch {
                        guard self.generation == sessionID, !Task.isCancelled else { return }
                        self.failure = "登录凭据交换失败，请检查网络后取消并重试"
                    }
                }
            }
        }
    }

    private func exchange(code: String) async throws -> Data {
        var request = URLRequest(url: URL(string: "https://auth.openai.com/oauth/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = 60
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let fields = ["grant_type": "authorization_code", "client_id": clientID, "code": code,
                      "redirect_uri": "http://127.0.0.1:1455/auth/callback", "code_verifier": verifier]
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        request.httpBody = fields.map { key, value in
            key + "=" + value.addingPercentEncoding(withAllowedCharacters: allowed)!
        }.joined(separator: "&").data(using: .utf8)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              var tokens = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let idToken = tokens["id_token"] as? String, !idToken.isEmpty,
              let access = tokens["access_token"] as? String, !access.isEmpty,
              let refresh = tokens["refresh_token"] as? String, !refresh.isEmpty else {
            throw HarborError.invalidAccountCredentials
        }
        let segments = idToken.split(separator: ".")
        guard segments.count == 3 else { throw HarborError.invalidAccountCredentials }
        var encoded = String(segments[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let payload = Data(base64Encoded: encoded),
              let claims = try JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let auth = claims["https://api.openai.com/auth"] as? [String: Any],
              let accountID = auth["chatgpt_account_id"] as? String, !accountID.isEmpty else {
            throw HarborError.invalidAccountCredentials
        }
        tokens = ["id_token": idToken, "access_token": access, "refresh_token": refresh, "account_id": accountID]
        return try JSONSerialization.data(withJSONObject: ["auth_mode": "chatgpt", "tokens": tokens,
            "last_refresh": ISO8601DateFormatter().string(from: Date())])
    }

    func authenticationData() throws -> Data {
        if let failure { throw HarborError.invalidConfiguration(failure) }
        guard let pendingAuthentication else {
            throw HarborError.invalidConfiguration("尚未检测到登录完成，请在浏览器完成授权后重试")
        }
        return pendingAuthentication
    }

    func finish() async {
        generation = UUID()
        timeoutTask?.cancel()
        exchangeTask?.cancel()
        listener?.cancel()
        listener = nil
        timeoutTask = nil
        exchangeTask = nil
        pendingAuthentication = nil
        failure = nil
        state = ""
        verifier = ""
        previousAccountID = nil
    }

    private func respond(_ connection: NWConnection, status: Int, message: String) {
        let body = Data(message.utf8)
        let header = "HTTP/1.1 \(status) Result\r\nContent-Type: text/plain; charset=utf-8\r\nCache-Control: no-store\r\nContent-Length: \(body.count)\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(header.utf8) + body, completion: .contentProcessed { _ in connection.cancel() })
    }

    private func randomValue() throws -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
            throw HarborError.invalidConfiguration("无法生成安全登录会话，请重试")
        }
        return base64URL(Data(bytes))
    }

    private func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    }
}
