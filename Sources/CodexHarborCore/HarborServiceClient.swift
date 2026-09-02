import Foundation

public actor HarborServiceClient {
    private let serviceURL: URL
    private let session: URLSession

    public init(
        serviceURL: URL = URL(string: "https://codex.ai02.cn")!,
        session: URLSession = .shared
    ) {
        self.serviceURL = serviceURL
        self.session = session
    }

    public func redeem(activationKey: String, deviceHash: String) async throws -> ActivationReceipt {
        let key = activationKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw HarborError.invalidActivationKey }
        let object = try await post(path: "/api/redeem", body: ["code": key, "device_hash": deviceHash])
        guard Self.bool(in: object, keys: ["success"]) != false else {
            throw HarborError.serverRejected(Self.string(in: object, keys: ["message", "error"]) ?? "激活密钥不可用。")
        }
        let payload = (object["data"] as? [String: Any]) ?? object
        guard let token = Self.string(in: payload, keys: ["key", "token", "api_key"]), !token.isEmpty else {
            throw HarborError.invalidServerResponse
        }
        return ActivationReceipt(
            token: token,
            expiresAt: Self.string(in: payload, keys: ["expires_at", "expiresAt"]),
            message: Self.string(in: payload, keys: ["message"]) ?? Self.string(in: object, keys: ["message"])
        )
    }

    public func fetchConfiguration() async throws -> HarborRemoteConfiguration {
        let object = try await get(path: "/api/client_config")
        guard Self.bool(in: object, keys: ["enabled"]) != false else {
            throw HarborError.serverRejected(Self.string(in: object, keys: ["notice", "message"]) ?? "服务当前不可用。")
        }
        let rawURL = Self.string(in: object, keys: ["base_url", "baseURL", "codex_base_url", "api_base_url"])
            ?? (object["codex"] as? [String: Any]).flatMap { Self.string(in: $0, keys: ["base_url", "baseURL"]) }
            ?? HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
        guard let parsedURL = URL(string: rawURL), parsedURL.scheme?.lowercased() == "https" else {
            throw HarborError.invalidBaseURL
        }
        let url = try Self.normalizedAPIBaseURL(parsedURL)
        let model = Self.string(in: object, keys: ["model", "codex_model", "default_model"])
            ?? (object["codex"] as? [String: Any]).flatMap { Self.string(in: $0, keys: ["model", "default_model"]) }
            ?? HarborRemoteConfiguration.fallback.model
        guard Self.isSafeModel(model) else { throw HarborError.invalidModel }
        return HarborRemoteConfiguration(
            apiBaseURL: url,
            model: model,
            notice: Self.string(in: object, keys: ["notice", "message"])
        )
    }

    public func usage(activationKey: String, deviceHash: String) async throws -> UsageSnapshot {
        let object = try await post(
            path: "/api/usage",
            body: ["code": activationKey, "card_code": activationKey, "device_hash": deviceHash]
        )
        guard Self.bool(in: object, keys: ["success"]) != false else {
            throw HarborError.serverRejected(Self.string(in: object, keys: ["message", "error"]) ?? "查询用量失败。")
        }
        return Self.usageSnapshot(in: object)
    }

    static func usageSnapshot(in object: [String: Any]) -> UsageSnapshot {
        let payload = (object["data"] as? [String: Any]) ?? object
        return UsageSnapshot(
            used: Self.double(in: payload, keys: ["used", "usage", "used_amount", "used_quota"]),
            remaining: Self.double(in: payload, keys: ["remaining", "balance", "remain_amount", "remaining_amount", "remaining_quota"]),
            expiresAt: Self.string(in: payload, keys: ["expires_at", "expiresAt", "expiry"]),
            message: Self.string(in: payload, keys: ["message"]) ?? Self.string(in: object, keys: ["message"])
        )
    }

    public func validateService(baseURL: URL, token: String) async throws {
        let baseURL = try Self.normalizedAPIBaseURL(baseURL)
        let modelsURL = Self.modelsURL(for: baseURL)
        var request = URLRequest(url: modelsURL)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HarborError.serverRejected("服务凭据验证失败。")
        }
    }

    public func fetchModels(baseURL: URL, token: String) async throws -> [String] {
        let baseURL = try Self.normalizedAPIBaseURL(baseURL)
        var request = URLRequest(url: Self.modelsURL(for: baseURL))
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
            throw HarborError.serverRejected("模型列表获取失败。")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborError.invalidServerResponse
        }
        let entries = (object["data"] as? [[String: Any]]) ?? []
        let models = entries.compactMap { $0["id"] as? String }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0.count <= 100 }
        guard !models.isEmpty else { throw HarborError.invalidModel }
        return models
    }

    private static func modelsURL(for baseURL: URL) -> URL {
        baseURL.path.hasSuffix("/v1")
            ? baseURL.appendingPathComponent("models")
            : baseURL.appendingPathComponent("v1/models")
    }

    private func get(path: String) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint(path))
        request.timeoutInterval = 15
        return try await send(request)
    }

    private func post(path: String, body: [String: String]) async throws -> [String: Any] {
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        return try await send(request)
    }

    private func endpoint(_ path: String) -> URL {
        serviceURL.appendingPathComponent(path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
    }

    private func send(_ request: URLRequest) async throws -> [String: Any] {
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HarborError.invalidServerResponse }
        let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        guard (200..<300).contains(http.statusCode) else {
            throw HarborError.serverRejected(Self.string(in: raw ?? [:], keys: ["message", "error"]) ?? "服务请求失败（\(http.statusCode)）。")
        }
        guard let raw else { throw HarborError.invalidServerResponse }
        return raw
    }

    private static func string(in object: [String: Any], keys: [String]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value }
        }
        return nil
    }

    private static func bool(in object: [String: Any], keys: [String]) -> Bool? {
        for key in keys {
            if let value = object[key] as? Bool { return value }
            if let value = object[key] as? NSNumber { return value.boolValue }
        }
        return nil
    }

    private static func double(in object: [String: Any], keys: [String]) -> Double? {
        for key in keys {
            if let value = object[key] as? NSNumber { return value.doubleValue }
            if let value = object[key] as? String, let number = Double(value) { return number }
        }
        return nil
    }

    private static func isSafeModel(_ value: String) -> Bool {
        !value.isEmpty && value.count <= 100 && value.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._/")).contains($0)
        }
    }

    public static func normalizedAPIBaseURL(_ url: URL) throws -> URL {
        guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.scheme?.lowercased() == "https",
              let host = components.host,
              !host.isEmpty,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil else {
            throw HarborError.invalidBaseURL
        }
        components.scheme = "https"
        while components.path.count > 1, components.path.hasSuffix("/") {
            components.path.removeLast()
        }
        if components.path.isEmpty || components.path == "/" {
            components.path = "/v1"
        }
        guard let normalized = components.url else { throw HarborError.invalidBaseURL }
        return normalized
    }
}
