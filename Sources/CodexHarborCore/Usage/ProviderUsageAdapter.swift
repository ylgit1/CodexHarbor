import Foundation

/// A provider-reported balance. This is intentionally separate from Relay's
/// per-request Token counters: currency/credits are billing facts, while Token
/// counts describe request volume and are not interchangeable.
public struct ProviderBillingSnapshot: Codable, Equatable, Sendable {
    public let provider: ProviderBrand
    public let used: Double?
    public let remaining: Double?
    public let currency: String
    public let retrievedAt: Date

    public init(provider: ProviderBrand, used: Double?, remaining: Double?, currency: String, retrievedAt: Date = Date()) {
        self.provider = provider
        self.used = used
        self.remaining = remaining
        self.currency = currency
        self.retrievedAt = retrievedAt
    }
}

/// Provider billing APIs are not standardized. Only endpoints documented by
/// the provider are queried; unknown OpenAI-compatible gateways are never
/// probed with speculative paths or sent a credential unnecessarily.
public actor ProviderUsageAdapterClient {
    private let session: URLSession

    public init(session: URLSession = .shared) {
        self.session = session
    }

    public func billing(profile: HarborProfile, token: String) async throws -> ProviderBillingSnapshot? {
        let brand = ProviderCatalog.identity(for: profile.apiBaseURL).brand
        switch brand {
        case .deepSeek:
            return try await deepSeekBalance(baseURL: profile.apiBaseURL, token: token)
        case .openRouter:
            return try await openRouterCredits(baseURL: profile.apiBaseURL, token: token)
        case .openAI, .kimi, .qwen, .zhipu, .miniMax, .siliconFlow, .custom:
            return nil
        }
    }

    private func deepSeekBalance(baseURL: URL, token: String) async throws -> ProviderBillingSnapshot {
        var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false)
        components?.path = "/user/balance"
        guard let url = components?.url else { throw HarborError.invalidBaseURL }
        let object = try await get(url: url, token: token)
        let balances = object["balance_infos"] as? [[String: Any]] ?? []
        guard let balance = balances.first else { throw HarborError.invalidServerResponse }
        return ProviderBillingSnapshot(
            provider: .deepSeek,
            used: nil,
            remaining: Self.number(balance["total_balance"]),
            currency: (balance["currency"] as? String) ?? "CNY"
        )
    }

    private func openRouterCredits(baseURL: URL, token: String) async throws -> ProviderBillingSnapshot {
        var value = baseURL.absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        guard let url = URL(string: "\(value)/credits") else { throw HarborError.invalidBaseURL }
        let object = try await get(url: url, token: token)
        let data = object["data"] as? [String: Any] ?? object
        let total = Self.number(data["total_credits"])
        let used = Self.number(data["total_usage"])
        return ProviderBillingSnapshot(
            provider: .openRouter,
            used: used,
            remaining: total.map { max(0, $0 - (used ?? 0)) },
            currency: "USD"
        )
    }

    private func get(url: URL, token: String) async throws -> [String: Any] {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw HarborError.invalidServerResponse }
        guard (200..<300).contains(http.statusCode) else {
            throw HarborError.serverRejected("供应商账单接口返回 HTTP \(http.statusCode)")
        }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborError.invalidServerResponse
        }
        return object
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}
