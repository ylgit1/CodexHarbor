import Foundation

public struct ActivationReceipt: Equatable, Sendable {
    public let token: String
    public let expiresAt: String?
    public let message: String?

    public init(token: String, expiresAt: String? = nil, message: String? = nil) {
        self.token = token
        self.expiresAt = expiresAt
        self.message = message
    }
}

public struct HarborRemoteConfiguration: Equatable, Sendable {
    public var apiBaseURL: URL
    public var model: String
    public var notice: String?

    public init(apiBaseURL: URL, model: String, notice: String? = nil) {
        self.apiBaseURL = apiBaseURL
        self.model = model
        self.notice = notice
    }

    public static let fallback = HarborRemoteConfiguration(
        apiBaseURL: URL(string: "https://codex.ai02.cn/v1")!,
        model: CodexDefaults.model
    )
}

public struct UsageSnapshot: Equatable, Sendable {
    public var used: Double?
    public var remaining: Double?
    public var expiresAt: String?
    public var message: String?

    public init(used: Double? = nil, remaining: Double? = nil, expiresAt: String? = nil, message: String? = nil) {
        self.used = used
        self.remaining = remaining
        self.expiresAt = expiresAt
        self.message = message
    }
}
