import Foundation

public enum CodexMode: String, Codable, CaseIterable, Sendable {
    case harbor
    case chatGPT

    public var title: String {
        switch self {
        case .harbor: "托管连接"
        case .chatGPT: "账户登录"
        }
    }
}

/// Defaults used when Harbor creates or explicitly switches the first-party
/// account and hosted-key connections. Custom API profiles keep their own
/// provider model instead of being rewritten to this value.
public enum CodexDefaults {
    public static let model = "gpt-5.6-sol"
    public static let reasoningEffort = "medium"
    public static let serviceTier = "default"
}

/// User-facing connection categories. Harbor and custom API connections both
/// use Codex's managed provider internally, but their credentials and service
/// capabilities are different and must remain distinguishable.
public enum CodexConnectionKind: String, Codable, CaseIterable, Sendable {
    case account
    case harborKey
    case apiKey

    public var title: String {
        switch self {
        case .account: "账户登录"
        case .harborKey: "托管密钥"
        case .apiKey: "自定义 API 密钥"
        }
    }

    public var icon: String {
        switch self {
        case .account: "person.crop.circle.fill"
        case .harborKey: "key.fill"
        case .apiKey: "network"
        }
    }

    public var executionMode: CodexMode {
        switch self {
        case .account: .chatGPT
        case .harborKey, .apiKey: .harbor
        }
    }
}

public enum ConnectionHealth: Equatable, Sendable {
    case unchecked
    case checking
    case available(String? = nil)
    case expired(String? = nil)
    case unavailable(String? = nil)
}

/// A selected profile is not "healthy" merely because it exists or because
/// credentials were valid at some indefinite point in the past.
/// Layout budget for the minimum supported Mac window. Keep the three
/// summary cards visible without squeezing their controls below tap targets.
public struct HarborDashboardSizing: Sendable {
    public let compact: Bool
    public let flowHeight: Double
    public let cardHeight: Double
    public let gap: Double
    public let topInset: Double
    public let bottomInset: Double

    public static func resolve(width: Double, height: Double) -> Self {
        let compact = height < 700
        return Self(
            compact: compact,
            flowHeight: compact
                ? max(208, min(246, height * 0.38))
                : max(306, min(430, height * 0.45)),
            cardHeight: compact ? 228 : 270,
            gap: compact ? 10 : max(12, min(24, width * 0.013)),
            topInset: compact ? 12 : max(15, min(30, height * 0.024)),
            bottomInset: compact ? 14 : 22
        )
    }

    public var requiredHeight: Double {
        50 + flowHeight + cardHeight + 2 * gap + topInset + bottomInset
    }
}

/// Avoid unreadable, ellipsized node names in the proxy table when
/// the sidebar leaves too little space for all fixed-width columns.
public enum HarborProxyTableSizing {
    public static func usesCompactRows(workspaceWidth: Double) -> Bool {
        workspaceWidth < 950
    }
}

public enum HarborConnectionReadiness {
    public static func recentlyVerified(
        health: ConnectionHealth?,
        checkedAt: Date?,
        now: Date = Date(),
        maxAge: TimeInterval = 15 * 60
    ) -> Bool {
        guard case .available = health,
              let checkedAt else { return false }
        let age = now.timeIntervalSince(checkedAt)
        return age >= 0 && age <= maxAge
    }
}

public enum HarborProfileKind: String, Codable, Sendable {
    case harbor
    case customResponses

    public var title: String {
        switch self {
        case .harbor: CodexConnectionKind.harborKey.title
        case .customResponses: CodexConnectionKind.apiKey.title
        }
    }

    public var connectionKind: CodexConnectionKind {
        switch self {
        case .harbor: .harborKey
        case .customResponses: .apiKey
        }
    }
}

/// Protocol spoken by the upstream service behind Harbor Relay. Codex always
/// talks Responses to the local relay; the relay either forwards that request
/// unchanged or translates it to Chat Completions.
public enum HarborRelayProtocol: String, Codable, CaseIterable, Sendable {
    case automatic
    case responses
    case chatCompletions

    public var title: String {
        switch self {
        case .automatic: "自动识别"
        case .responses: "Responses"
        case .chatCompletions: "Chat Completions"
        }
    }
}

/// Provider templates for user-managed API connections. All templates use the
/// OpenAI Responses-compatible wire format that Codex can execute today.
public enum CustomAPIProvider: String, Codable, CaseIterable, Sendable {
    case openAI
    case openAICompatible
    case otherCompatibleGateway

    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .openAICompatible: "OpenAI 兼容"
        case .otherCompatibleGateway: "其他兼容网关"
        }
    }

    public var subtitle: String {
        switch self {
        case .openAI: "官方 API"
        case .openAICompatible: "支持 Responses API 的第三方服务"
        case .otherCompatibleGateway: "Claude / Gemini 等协议的兼容网关"
        }
    }

    public var icon: String {
        switch self {
        case .openAI: "sparkles"
        case .openAICompatible: "arrow.triangle.2.circlepath"
        case .otherCompatibleGateway: "point.3.connected.trianglepath.dotted"
        }
    }

    public var defaultBaseURL: String {
        switch self {
        case .openAI: "https://api.openai.com/v1"
        case .openAICompatible, .otherCompatibleGateway: "https://api.example.com/v1"
        }
    }

    public var defaultModel: String {
        "gpt-5.3-codex"
    }

    public var capabilityNote: String {
        switch self {
        case .openAI: "使用 OpenAI 官方 Responses API。"
        case .openAICompatible: "服务商必须提供 OpenAI Responses API 兼容接口。"
        case .otherCompatibleGateway: "仅适用于已转换为 OpenAI Responses API 的 Claude / Gemini 网关；不代表原生协议支持。"
        }
    }
}
