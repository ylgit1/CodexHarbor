import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Tunnel proxy resolver")
struct TunnelProxyResolverTests {
    private let controlPlane = URL(string: "https://api.openai.com")!

    @Test("automatic strategy keeps a reachable system proxy")
    func automaticKeepsReachableProxy() async throws {
        let resolver = TunnelProxyResolver { _, environment in
            environment["HTTPS_PROXY"] != nil
        }
        let result = try await resolver.resolve(
            strategy: .automatic,
            controlPlaneURL: controlPlane,
            baseEnvironment: [
                "HTTPS_PROXY": "http://user:secret@127.0.0.1:10808"
            ]
        )

        #expect(result.status.selectedRoute == .systemProxy)
        #expect(result.status.proxyReachable == true)
        #expect(result.status.systemProxyDetected)
        #expect(result.status.systemProxyDescription == "http://127.0.0.1:10808")
        #expect(result.status.systemProxyDescription?.contains("secret") == false)
        #expect(result.environment["NO_PROXY"]?.contains("127.0.0.1") == true)
        #expect(result.environment["NO_PROXY"]?.contains("localhost") == true)
        #expect(result.environment["NO_PROXY"]?.contains("::1") == true)
    }

    @Test("automatic strategy falls back to direct when proxy is unreachable")
    func automaticFallsBackToDirect() async throws {
        let resolver = TunnelProxyResolver { _, environment in
            environment["HTTPS_PROXY"] == nil
        }
        let result = try await resolver.resolve(
            strategy: .automatic,
            controlPlaneURL: controlPlane,
            baseEnvironment: ["HTTPS_PROXY": "http://127.0.0.1:10808"]
        )

        #expect(result.status.selectedRoute == .direct)
        #expect(result.status.proxyReachable == false)
        #expect(result.status.directReachable == true)
        #expect(result.environment["HTTPS_PROXY"] == nil)
        #expect(result.environment["https_proxy"] == nil)
        #expect(result.status.message.contains("自动切换为直连"))
    }

    @Test("direct strategy strips inherited proxy variables")
    func directStripsProxyVariables() async throws {
        let resolver = TunnelProxyResolver { _, environment in
            environment["HTTP_PROXY"] == nil
                && environment["HTTPS_PROXY"] == nil
                && environment["ALL_PROXY"] == nil
        }
        let result = try await resolver.resolve(
            strategy: .direct,
            controlPlaneURL: controlPlane,
            baseEnvironment: [
                "HTTP_PROXY": "http://127.0.0.1:8080",
                "HTTPS_PROXY": "http://127.0.0.1:8080",
                "ALL_PROXY": "socks5://127.0.0.1:10808"
            ]
        )

        #expect(result.status.selectedRoute == .direct)
        #expect(result.environment["HTTP_PROXY"] == nil)
        #expect(result.environment["HTTPS_PROXY"] == nil)
        #expect(result.environment["ALL_PROXY"] == nil)
        #expect(result.environment["NO_PROXY"]?.contains("127.0.0.1") == true)
    }

    @Test("forced system proxy reports a clear failure when the proxy cannot reach OpenAI")
    func forcedSystemProxyFailsClearly() async {
        let resolver = TunnelProxyResolver { _, _ in false }

        do {
            _ = try await resolver.resolve(
                strategy: .system,
                controlPlaneURL: controlPlane,
                baseEnvironment: ["HTTPS_PROXY": "http://127.0.0.1:10808"]
            )
            Issue.record("Expected forced system proxy to fail")
        } catch {
            #expect(error.localizedDescription.contains("系统代理无法访问"))
            #expect(error.localizedDescription.contains("自动/直连"))
        }
    }

    @Test("automatic strategy reports a network failure when proxy and direct both fail")
    func automaticFailsWhenAllRoutesFail() async {
        let resolver = TunnelProxyResolver { _, _ in false }

        await #expect(throws: BridgeError.self) {
            _ = try await resolver.resolve(
                strategy: .automatic,
                controlPlaneURL: controlPlane,
                baseEnvironment: ["ALL_PROXY": "socks5://127.0.0.1:10808"]
            )
        }
    }

    @Test("legacy secure tunnel configuration defaults to automatic proxy strategy")
    func legacyConfigurationDefaultsToAutomatic() throws {
        let data = Data(#"""
        {
          "tunnelID": "tunnel_0123456789abcdef0123456789abcdef",
          "controlPlaneBaseURL": "https://api.openai.com"
        }
        """#.utf8)

        let configuration = try JSONDecoder().decode(SecureTunnelConfiguration.self, from: data)
        #expect(configuration.proxyStrategy == .automatic)
    }
}
