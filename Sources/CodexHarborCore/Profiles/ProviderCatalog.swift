import Foundation

public enum ProviderBrand: String, Codable, CaseIterable, Sendable {
    case openAI
    case kimi
    case qwen
    case deepSeek
    case zhipu
    case miniMax
    case openRouter
    case siliconFlow
    case custom

    public var title: String {
        switch self {
        case .openAI: "OpenAI"
        case .kimi: "Kimi"
        case .qwen: "通义千问"
        case .deepSeek: "DeepSeek"
        case .zhipu: "智谱 GLM"
        case .miniMax: "MiniMax"
        case .openRouter: "OpenRouter"
        case .siliconFlow: "SiliconFlow"
        case .custom: "自定义供应商"
        }
    }

    public var symbolName: String {
        switch self {
        case .openAI: "sparkles"
        case .kimi: "moon.stars.fill"
        case .qwen: "q.circle.fill"
        case .deepSeek: "wave.3.right.circle.fill"
        case .zhipu: "brain.head.profile.fill"
        case .miniMax: "bolt.horizontal.circle.fill"
        case .openRouter: "point.3.connected.trianglepath.dotted"
        case .siliconFlow: "water.waves"
        case .custom: "network"
        }
    }
}

public struct ProviderIdentity: Equatable, Sendable {
    public let brand: ProviderBrand
    public let host: String
    public let protocolTitle: String
    public let faviconURL: URL?

    public init(brand: ProviderBrand, host: String, protocolTitle: String, faviconURL: URL?) {
        self.brand = brand
        self.host = host
        self.protocolTitle = protocolTitle
        self.faviconURL = faviconURL
    }
}

public enum ProviderCatalog {
    public static func identity(for apiBaseURL: URL) -> ProviderIdentity {
        let host = apiBaseURL.host?.lowercased() ?? "未知地址"
        let brand: ProviderBrand

        if host == "api.openai.com" || host.hasSuffix(".openai.com") {
            brand = .openAI
        } else if host.contains("moonshot") || host.contains("kimi") {
            brand = .kimi
        } else if host.contains("dashscope") || host.contains("aliyuncs") || host.contains("qwen") {
            brand = .qwen
        } else if host.contains("deepseek") {
            brand = .deepSeek
        } else if host.contains("bigmodel") || host.contains("zhipu") {
            brand = .zhipu
        } else if host.contains("minimax") {
            brand = .miniMax
        } else if host.contains("openrouter") {
            brand = .openRouter
        } else if host.contains("siliconflow") {
            brand = .siliconFlow
        } else {
            brand = .custom
        }

        var components = URLComponents()
        components.scheme = "https"
        components.host = apiBaseURL.host
        components.port = apiBaseURL.port
        components.path = "/favicon.ico"

        let protocolTitle: String
        switch brand {
        case .openAI: protocolTitle = "Responses"
        case .kimi, .qwen, .deepSeek, .zhipu, .miniMax, .siliconFlow: protocolTitle = "Chat Completions · Relay 转换"
        case .openRouter: protocolTitle = "Responses / Chat Completions"
        case .custom: protocolTitle = "Relay 自动识别"
        }

        return ProviderIdentity(
            brand: brand,
            host: host,
            protocolTitle: protocolTitle,
            faviconURL: components.url
        )
    }
}
