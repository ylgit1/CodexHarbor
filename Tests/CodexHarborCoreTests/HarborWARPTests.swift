import CryptoKit
import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Independent VPN Gate bootstrap")
struct HarborWARPTests {
    private func account() -> HarborWARPAccount {
        let key = P256.Signing.PrivateKey()
        return HarborWARPAccount(
            id: UUID().uuidString,
            privateKey: HarborWARPRegistration.sec1(key).base64EncodedString(),
            peerPublicKey: P256.Signing.PrivateKey().publicKey.derRepresentation.base64EncodedString(),
            ipv4: "172.16.0.2", ipv6: "2606:4700:110::1234")
    }

    private func node() -> HarborProxyNode {
        let profile = """
        client
        dev tun
        proto tcp
        remote 219.100.37.7 443
        <ca>
        -----BEGIN CERTIFICATE-----
        fixture
        -----END CERTIFICATE-----
        </ca>
        <cert>
        -----BEGIN CERTIFICATE-----
        fixture
        -----END CERTIFICATE-----
        </cert>
        <key>
        -----BEGIN PRIVATE KEY-----
        fixture
        -----END PRIVATE KEY-----
        </key>
        """
        return HarborProxyNode(
            name: "volunteer", protocolName: "openvpn", host: "219.100.37.7",
            port: 443, credential: Data(profile.utf8).base64EncodedString(),
            network: "tcp", security: "vpngate-unverified", path: "JP")
    }

    @Test("Fresh registration switches from WireGuard enrollment to a unique MASQUE public key")
    func registration() async throws {
        let recorder = WARPEnrollmentRecorder()
        let value = try await HarborWARPRegistration.register { try await recorder.respond($0) }
        try value.validate()
        let requests = await recorder.requests
        #expect(requests.count == 2)
        #expect(requests[0].httpMethod == "POST")
        #expect(requests[1].httpMethod == "PATCH")
        #expect(requests[0].url?.host == "api.cloudflareclient.com")
        #expect(requests[1].value(forHTTPHeaderField: "Authorization") == "Bearer fixture-token")
        let first = try #require(try JSONSerialization.jsonObject(with: requests[0].httpBody!) as? [String: Any])
        let second = try #require(try JSONSerialization.jsonObject(with: requests[1].httpBody!) as? [String: Any])
        #expect(first["tunnel_type"] as? String == "wireguard")
        #expect(second["tunnel_type"] as? String == "masque")
        #expect(second["key_type"] as? String == "secp256r1")
        #expect(first["key"] as? String != second["key"] as? String)
        #expect(second["key"] as? String != value.privateKey)
        #expect(second["warp_enabled"] as? Bool == true)
        let serialized = try JSONEncoder().encode(value)
        #expect(!String(decoding: serialized, as: UTF8.self).contains("fixture-token"))
        let otherRecorder = WARPEnrollmentRecorder()
        let other = try await HarborWARPRegistration.register { try await otherRecorder.respond($0) }
        #expect(value.privateKey != other.privateKey)
    }

    @Test("Enrollment failures never echo a provider response containing secrets")
    func registrationFailure() async throws {
        do {
            _ = try await HarborWARPRegistration.register { request in
                (Data(#"{"token":"do-not-display-this"}"#.utf8),
                 HTTPURLResponse(url: request.url!, statusCode: 403, httpVersion: nil, headerFields: nil)!)
            }
            Issue.record("Expected a denied registration to fail")
        } catch {
            #expect(error.localizedDescription.contains("403"))
            #expect(!error.localizedDescription.contains("do-not-display-this"))
        }
    }

    @Test("Incomplete or mismatched enrollment cannot create a usable tunnel")
    func badEnrollment() async throws {
        for mode in [WARPEnrollmentRecorder.Failure.missingToken, .wrongID, .missingPeer, .invalidAddress] {
            let recorder = WARPEnrollmentRecorder(failure: mode)
            await #expect(throws: (any Error).self) {
                _ = try await HarborWARPRegistration.register { try await recorder.respond($0) }
            }
        }
    }

    @Test("TCP and QUIC discovery is bounded and keeps the previous success first")
    func endpoints() {
        let preferred = HarborWARPEndpoint(host: "162.159.198.1", transport: .h3)
        let values = HarborWARPEndpoint.candidates(preferred: preferred)
        #expect(values.first == preferred)
        #expect(values.count <= 9)
        #expect(Set(values).count == values.count)
        #expect(values.contains { $0.transport == .h2 })
        #expect(values.contains { $0.transport == .h3 })
        #expect(values.allSatisfy { $0.isValid })
        #expect(!HarborWARPEndpoint(host: "127.0.0.1").isValid)
        #expect(!HarborWARPEndpoint(host: "example.com").isValid)
        #expect(!HarborWARPEndpoint(host: "162.159.198.1", port: 1).isValid)
    }

    @Test("Enrollment and independent HTTP sessions disable implicit system proxies and PAC")
    func proxyIsolation() {
        let direct = HarborProxyHTTP.configuration().connectionProxyDictionary!
        for key in ["HTTPEnable", "HTTPSEnable", "SOCKSEnable", "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"] {
            #expect(direct[key] as? Int == 0)
        }
        let proxied = HarborProxyHTTP.configuration(httpPort: 19080).connectionProxyDictionary!
        #expect(proxied["HTTPSProxy"] as? String == "127.0.0.1")
        #expect(proxied["HTTPSPort"] as? Int == 19080)
        #expect(proxied["ProxyAutoConfigEnable"] as? Int == 0)
        #expect(proxied["SOCKSEnable"] as? Int == 0)
    }

    @Test("A listening port or an ordinary Cloudflare exit is not verified WARP")
    func traceVerification() {
        #expect(HarborProxyHTTP.verifiesWARPTrace(Data("ip=1.2.3.4\nwarp=on\n".utf8)))
        #expect(HarborProxyHTTP.verifiesWARPTrace(Data("warp=plus\n".utf8)))
        #expect(!HarborProxyHTTP.verifiesWARPTrace(Data("warp=off\n".utf8)))
        #expect(!HarborProxyHTTP.verifiesWARPTrace(Data("prefix-warp=on\n".utf8)))
        #expect(!HarborProxyHTTP.verifiesWARPTrace(Data("warp=on-not-really\n".utf8)))
    }

    @Test("OpenVPN embeds WARP without a subscription or a temporary SOCKS dependency")
    func embeddedRoute() throws {
        let value = account(), relay = node()
        let profile = HarborWARPProfile(account: value, endpoint: .init(host: "162.159.198.2"))
        let config = try HarborMihomoConfig.make(node: relay, httpPort: 19080, warpProfile: profile)
        let object = try #require(try JSONSerialization.jsonObject(with: config) as? [String: Any])
        let proxies = try #require(object["proxies"] as? [[String: Any]])
        #expect(proxies.count == 2)
        #expect(proxies[0]["dialer-proxy"] as? String == "warp")
        #expect(proxies[1]["type"] as? String == "masque")
        #expect(proxies[1]["skip-cert-verify"] as? Bool == false)
        #expect(proxies[1]["public-key"] as? String == value.peerPublicKey)
        #expect(proxies.allSatisfy { $0["type"] as? String != "socks5" })
        #expect(HarborMihomoConfig.matches(configuration: config, node: relay, warpProfile: profile))
        #expect(!HarborMihomoConfig.matches(configuration: config, node: relay))
        let other = HarborWARPProfile(account: value, endpoint: .init(host: "162.159.198.1"))
        #expect(!HarborMihomoConfig.matches(configuration: config, node: relay, warpProfile: other))
        #expect(profile.routeID != other.routeID)
        #expect(throws: (any Error).self) {
            try HarborMihomoConfig.make(node: relay, httpPort: 19080, underlaySocksPort: 19083, warpProfile: profile)
        }
    }

    @Test("Bundled Mihomo accepts the generated EC private key and both transports")
    func bundledCoreAcceptsConfig() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        #if arch(arm64)
        let arch = "arm64"
        #else
        let arch = "x86_64"
        #endif
        let binary = root.appendingPathComponent("Resources/Mihomo/\(arch)/mihomo")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else { return }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("harbor-warp-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let value = account()
        for transport in [HarborWARPEndpoint.Transport.h2, .h3] {
            let profile = HarborWARPProfile(account: value, endpoint: .init(host: "162.159.198.2", transport: transport))
            let data = try HarborWARPConfig.make(profile: profile, httpPort: 19080)
            let config = directory.appendingPathComponent("config.json")
            try data.write(to: config)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: config.path)
            let process = Process()
            process.executableURL = binary
            process.arguments = ["-t", "-d", directory.path, "-f", config.path]
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            try process.run()
            process.waitUntilExit()
            #expect(process.terminationStatus == 0)
        }
    }
}

private actor WARPEnrollmentRecorder {
    enum Failure: Sendable { case missingToken, wrongID, missingPeer, invalidAddress }
    var requests: [URLRequest] = []
    let failure: Failure?
    let id = UUID().uuidString
    let peer = P256.Signing.PrivateKey().publicKey.pemRepresentation

    init(failure: Failure? = nil) { self.failure = failure }

    func respond(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        requests.append(request)
        let payload: [String: Any]
        if request.httpMethod == "POST" {
            payload = failure == .missingToken ? ["id": id] : ["id": id, "token": "fixture-token"]
        } else {
            payload = [
                "id": failure == .wrongID ? UUID().uuidString : id,
                "config": [
                    "peers": failure == .missingPeer ? [] : [["public_key": peer]],
                    "interface": ["addresses": ["v4": failure == .invalidAddress ? "example.com" : "172.16.0.2"]]
                ]
            ]
        }
        return (try JSONSerialization.data(withJSONObject: payload),
                HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
