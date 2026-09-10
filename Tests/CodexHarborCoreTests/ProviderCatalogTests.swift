import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Provider catalog")
struct ProviderCatalogTests {
    @Test("Known API hosts are recognized")
    func recognizesKnownHosts() throws {
        #expect(ProviderCatalog.identity(for: URL(string: "https://api.openai.com/v1")!).brand == .openAI)
        #expect(ProviderCatalog.identity(for: URL(string: "https://api.moonshot.cn/v1")!).brand == .kimi)
        #expect(ProviderCatalog.identity(for: URL(string: "https://dashscope.aliyuncs.com/compatible-mode/v1")!).brand == .qwen)
        #expect(ProviderCatalog.identity(for: URL(string: "https://api.deepseek.com/v1")!).brand == .deepSeek)
    }

    @Test("Unknown hosts use a direct favicon with no third-party proxy")
    func usesDirectFavicon() throws {
        let identity = ProviderCatalog.identity(for: URL(string: "https://gateway.example.com/v1")!)
        #expect(identity.brand == .custom)
        #expect(identity.faviconURL?.absoluteString == "https://gateway.example.com/favicon.ico")
    }
}
