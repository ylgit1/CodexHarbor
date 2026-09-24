import Foundation

public struct ServiceProbe: Equatable, Sendable {
    public let latencyMilliseconds: Int
    public let modelCount: Int?

    public init(latencyMilliseconds: Int, modelCount: Int?) {
        self.latencyMilliseconds = latencyMilliseconds
        self.modelCount = modelCount
    }
}

public struct HarborProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var keyFingerprint: String
    public var apiBaseURL: URL
    public var model: String
    public var kind: HarborProfileKind
    public var provider: CustomAPIProvider
    public var relayProtocol: HarborRelayProtocol
    public var models: [String]
    public var modelsUpdatedAt: Date?
    public var modelsVerified: Bool
    public var expiresAt: String?
    public var createdAt: Date

    public var modelsNeedRefresh: Bool {
        guard kind == .customResponses else { return false }
        guard let modelsUpdatedAt else { return models.isEmpty }
        return models.isEmpty || Date().timeIntervalSince(modelsUpdatedAt) > 24 * 60 * 60
    }

    public init(
        id: UUID = UUID(),
        name: String,
        keyFingerprint: String,
        apiBaseURL: URL,
        model: String,
        kind: HarborProfileKind = .harbor,
        provider: CustomAPIProvider = .openAI,
        relayProtocol: HarborRelayProtocol = .automatic,
        models: [String] = [],
        modelsUpdatedAt: Date? = nil,
        modelsVerified: Bool = false,
        expiresAt: String? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.keyFingerprint = keyFingerprint
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.kind = kind
        self.provider = provider
        self.relayProtocol = relayProtocol
        self.models = models
        self.modelsUpdatedAt = modelsUpdatedAt
        self.modelsVerified = modelsVerified
        self.expiresAt = expiresAt
        self.createdAt = createdAt
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, keyFingerprint, apiBaseURL, model, kind, provider, relayProtocol, models, modelsUpdatedAt, modelsVerified, expiresAt, createdAt
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        keyFingerprint = try values.decode(String.self, forKey: .keyFingerprint)
        apiBaseURL = try values.decode(URL.self, forKey: .apiBaseURL)
        model = try values.decode(String.self, forKey: .model)
        kind = try values.decodeIfPresent(HarborProfileKind.self, forKey: .kind) ?? .harbor
        provider = try values.decodeIfPresent(CustomAPIProvider.self, forKey: .provider)
            ?? (kind == .customResponses ? .openAICompatible : .openAI)
        relayProtocol = try values.decodeIfPresent(HarborRelayProtocol.self, forKey: .relayProtocol)
            ?? (provider == .openAI ? .responses : .automatic)
        models = try values.decodeIfPresent([String].self, forKey: .models) ?? []
        modelsUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .modelsUpdatedAt)
        modelsVerified = try values.decodeIfPresent(Bool.self, forKey: .modelsVerified) ?? false
        expiresAt = try values.decodeIfPresent(String.self, forKey: .expiresAt)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
    }
}

public enum CodexAccountMethod: String, Codable, Sendable {
    case chatGPT
    case apiKey
    case unknown

    public var title: String {
        switch self {
        case .chatGPT: "ChatGPT 账户"
        case .apiKey: "OpenAI API 密钥"
        case .unknown: "Codex 登录"
        }
    }
}

public enum CodexSubscriptionExpiryState: Equatable, Sendable {
    case active
    case expiringSoon
    case expired
    case unknown
}

public struct CodexAccountProfile: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var method: CodexAccountMethod
    public var credentialFingerprint: String
    /// Subscription metadata reported by the ChatGPT identity token. This is
    /// separate from JWT `exp`, which describes token validity rather than the
    /// user's Plus/Pro billing period.
    public var subscriptionPlan: String?
    public var subscriptionExpiresAt: String?
    public var subscriptionLastCheckedAt: String?
    public var createdAt: Date
    public var lastUsedAt: Date

    public init(
        id: UUID = UUID(),
        name: String,
        method: CodexAccountMethod,
        credentialFingerprint: String,
        subscriptionPlan: String? = nil,
        subscriptionExpiresAt: String? = nil,
        subscriptionLastCheckedAt: String? = nil,
        createdAt: Date = Date(),
        lastUsedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.method = method
        self.credentialFingerprint = credentialFingerprint
        self.subscriptionPlan = subscriptionPlan
        self.subscriptionExpiresAt = subscriptionExpiresAt
        self.subscriptionLastCheckedAt = subscriptionLastCheckedAt
        self.createdAt = createdAt
        self.lastUsedAt = lastUsedAt
    }

    public var subscriptionPlanTitle: String? {
        guard let subscriptionPlan, !subscriptionPlan.isEmpty else { return nil }
        switch subscriptionPlan.lowercased() {
        case "plus": return "Plus"
        case "pro": return "Pro"
        case "team": return "Team"
        case "business": return "Business"
        case "enterprise": return "Enterprise"
        default: return subscriptionPlan
        }
    }

    public func subscriptionExpiryState(now: Date = Date()) -> CodexSubscriptionExpiryState {
        guard let subscriptionExpiresAt,
              let expiry = Self.subscriptionDate(subscriptionExpiresAt) else {
            return .unknown
        }
        let remaining = expiry.timeIntervalSince(now)
        if remaining <= 0 { return .expired }
        if remaining <= 24 * 60 * 60 { return .expiringSoon }
        return .active
    }

    public func subscriptionExpiryDate() -> Date? {
        guard let subscriptionExpiresAt else { return nil }
        return Self.subscriptionDate(subscriptionExpiresAt)
    }

    public func subscriptionLastCheckedDate() -> Date? {
        guard let subscriptionLastCheckedAt else { return nil }
        return Self.subscriptionDate(subscriptionLastCheckedAt)
    }

    /// An expired date is not authoritative when the token says it was last
    /// checked before that date. Codex may refresh subscription claims later.
    public func subscriptionExpiryNeedsRefresh(now: Date = Date()) -> Bool {
        guard let expiry = subscriptionExpiryDate(), expiry <= now,
              let checkedAt = subscriptionLastCheckedDate() else { return false }
        return checkedAt < expiry
    }

    private static func subscriptionDate(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: value)
    }

    public var connectionKind: CodexConnectionKind { .account }
}
