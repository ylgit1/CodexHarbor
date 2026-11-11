import CryptoKit
import Foundation

/// A per-installation WARP identity. Persist only inside Harbor's encrypted
/// proxy state; never ship a shared private key or retain the enrollment token.
public struct HarborWARPAccount: Codable, Equatable, Sendable {
    public var id: String
    public var privateKey: String
    public var peerPublicKey: String
    public var ipv4: String
    public var ipv6: String?

    public init(id: String, privateKey: String, peerPublicKey: String,
                ipv4: String, ipv6: String? = nil) {
        self.id = id
        self.privateKey = privateKey
        self.peerPublicKey = peerPublicKey
        self.ipv4 = ipv4
        self.ipv6 = ipv6
    }

    public func validate() throws {
        guard UUID(uuidString: id) != nil,
              let secret = Data(base64Encoded: privateKey), secret.count == 121,
              let key = try? P256.Signing.PrivateKey(rawRepresentation: secret.subdata(in: 7..<39)),
              HarborWARPRegistration.sec1(key) == secret,
              let peer = Data(base64Encoded: peerPublicKey),
              (try? P256.Signing.PublicKey(derRepresentation: peer)) != nil,
              HarborIPAddress.normalizedLiteral(ipv4)?.contains(":") == false,
              ipv6 == nil || HarborIPAddress.normalizedLiteral(ipv6!)?.contains(":") == true else {
            throw HarborProxyError.invalid("独立通道凭据不完整或无效")
        }
    }
}

public struct HarborWARPEndpoint: Codable, Equatable, Hashable, Sendable {
    public enum Transport: String, Codable, Sendable { case h2, h3 }
    public var host: String
    public var port: Int
    public var transport: Transport

    public init(host: String, port: Int = 443, transport: Transport = .h2) {
        self.host = host
        self.port = port
        self.transport = transport
    }

    public var id: String { "\(transport.rawValue):[\(host)]:\(port)" }

    /// Bounded, DNS-free discovery. Reuse a verified endpoint first, and retain
    /// both TCP and QUIC choices so a blocked UDP path is not a prerequisite.
    public static func candidates(preferred: Self? = nil) -> [Self] {
        var values = [
            Self(host: "162.159.198.2"), Self(host: "162.159.198.1"),
            Self(host: "162.159.198.2", transport: .h3),
            Self(host: "162.159.198.1", transport: .h3),
            Self(host: "162.159.198.2", port: 8443),
            Self(host: "162.159.198.1", port: 8443),
            Self(host: "2606:4700:103::2"), Self(host: "2606:4700:104::2")
        ]
        if let preferred { values.insert(preferred, at: 0) }
        var seen = Set<Self>()
        return values.filter { $0.isValid && seen.insert($0).inserted }
    }

    public var isValid: Bool {
        guard [443, 4443, 8443, 500, 1701, 4500, 8095].contains(port),
              let ip = HarborIPAddress.normalizedLiteral(host) else { return false }
        return ip.hasPrefix("162.159.198.") || ip.hasPrefix("162.159.199.")
            || ip.hasPrefix("2606:4700:103:") || ip.hasPrefix("2606:4700:104:")
    }
}

public struct HarborWARPProfile: Equatable, Sendable {
    public let account: HarborWARPAccount
    public let endpoint: HarborWARPEndpoint

    public init(account: HarborWARPAccount, endpoint: HarborWARPEndpoint) {
        self.account = account
        self.endpoint = endpoint
    }

    public var routeID: String { "warp:\(account.id):\(endpoint.id)" }

    public func outbound(name: String = "warp") throws -> [String: Any] {
        try account.validate()
        guard endpoint.isValid else { throw HarborProxyError.invalid("独立通道地址无效") }
        var value: [String: Any] = [
            "name": name, "type": "masque", "server": endpoint.host,
            "port": endpoint.port, "network": endpoint.transport.rawValue,
            "private-key": account.privateKey, "public-key": account.peerPublicKey,
            "ip": account.ipv4, "udp": true, "mtu": 1280,
            "handshake-timeout": 6, "skip-cert-verify": false,
            "sni": "consumer-masque.cloudflareclient.com",
            "remote-dns-resolve": true, "dns": ["1.1.1.1", "1.0.0.1"]
        ]
        if let ipv6 = account.ipv6 { value["ipv6"] = ipv6 }
        return value
    }
}

public enum HarborWARPConfig {
    public static func make(profile: HarborWARPProfile, httpPort: Int) throws -> Data {
        _ = try HarborProxyPortPolicy.validate(httpPort: httpPort)
        let value: [String: Any] = [
            "port": httpPort, "socks-port": httpPort + 1,
            "allow-lan": false, "bind-address": "127.0.0.1",
            "mode": "rule", "log-level": "warning",
            "dns": [
                "enable": true, "ipv6": false, "respect-rules": true,
                "use-system-hosts": false,
                "default-nameserver": ["1.1.1.1"],
                "proxy-server-nameserver": ["1.1.1.1"],
                "nameserver": ["https://1.1.1.1/dns-query#warp"]
            ],
            "proxies": [try profile.outbound()],
            "rules": ["MATCH,warp"]
        ]
        return try JSONSerialization.data(withJSONObject: value,
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }
}

/// Explicit HTTP CONNECT routing is supported by URLSession on macOS.
/// Disable all implicit proxies, PAC and discovery, including for enrollment.
public enum HarborProxyHTTP {
    public static func configuration(httpPort: Int? = nil) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.waitsForConnectivity = false
        config.timeoutIntervalForRequest = 8
        config.timeoutIntervalForResource = 12
        var proxy: [String: Any] = [
            "HTTPEnable": 0, "HTTPSEnable": 0, "SOCKSEnable": 0,
            "ProxyAutoConfigEnable": 0, "ProxyAutoDiscoveryEnable": 0
        ]
        if let httpPort {
            proxy["HTTPEnable"] = 1
            proxy["HTTPProxy"] = "127.0.0.1"
            proxy["HTTPPort"] = httpPort
            proxy["HTTPSEnable"] = 1
            proxy["HTTPSProxy"] = "127.0.0.1"
            proxy["HTTPSPort"] = httpPort
        }
        config.connectionProxyDictionary = proxy
        return config
    }

    public static func verifiesWARPTrace(_ data: Data) -> Bool {
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { return false }
        return text.split(whereSeparator: \.isNewline).contains { $0 == "warp=on" || $0 == "warp=plus" }
    }
}

/// Implements the two-step WARP MASQUE enrollment contract. All keys are made
/// locally. Only public keys and a random installation identifier leave the Mac.
public enum HarborWARPRegistration {
    public typealias Transport = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private static let base = "https://api.cloudflareclient.com/v0a4471/reg"

    public static func register(transport: Transport? = nil) async throws -> HarborWARPAccount {
        let session = URLSession(configuration: HarborProxyHTTP.configuration())
        defer { session.invalidateAndCancel() }
        let send: Transport = transport ?? { request in
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw HarborProxyError.invalid("独立通道注册响应无效")
            }
            return (data, http)
        }
        let bootstrapKey = Curve25519.KeyAgreement.PrivateKey()
        let key = P256.Signing.PrivateKey()
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let first = try await request(method: "POST", path: "", token: nil, payload: [
            "key": bootstrapKey.publicKey.rawRepresentation.base64EncodedString(),
            "key_type": "curve25519", "tunnel_type": "wireguard",
            "install_id": "", "fcm_token": "", "locale": "en_US", "model": "PC",
            "serial_number": UUID().uuidString, "os_version": "10",
            "tos": formatter.string(from: .now)
        ], send: send)
        guard let id = first["id"] as? String, UUID(uuidString: id) != nil,
              let token = first["token"] as? String, !token.isEmpty, token.count < 2048,
              !token.contains(where: { $0.isWhitespace || $0.isNewline }) else {
            throw HarborProxyError.invalid("独立通道注册缺少设备凭据")
        }
        let enrolled = try await request(method: "PATCH", path: "/\(id)", token: token, payload: [
            "key": key.publicKey.derRepresentation.base64EncodedString(),
            "key_type": "secp256r1", "tunnel_type": "masque", "name": "Codex Harbor",
            "warp_enabled": true
        ], send: send)
        guard (enrolled["id"] as? String).map({ $0 == id }) ?? true,
              let config = enrolled["config"] as? [String: Any],
              let peers = config["peers"] as? [[String: Any]],
              let publicKey = peers.first?["public_key"] as? String,
              let interface = config["interface"] as? [String: Any],
              let addresses = interface["addresses"] as? [String: Any],
              let ipv4 = addresses["v4"] as? String else {
            throw HarborProxyError.invalid("独立通道注册缺少网络配置")
        }
        let normalizedPeer = publicKey.components(separatedBy: .newlines)
            .filter { !$0.hasPrefix("-----") }
            .joined().filter { !$0.isWhitespace }
        let ipv6 = (addresses["v6"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let account = HarborWARPAccount(
            id: id, privateKey: sec1(key).base64EncodedString(),
            peerPublicKey: normalizedPeer, ipv4: ipv4, ipv6: ipv6)
        try account.validate()
        return account
    }

    // RFC 5915 ECPrivateKey (SEC1), which Mihomo's MASQUE outbound accepts.
    // CryptoKit's PKCS#8 private DER is a different container.
    static func sec1(_ key: P256.Signing.PrivateKey) -> Data {
        Data([0x30, 0x77, 0x02, 0x01, 0x01, 0x04, 0x20]) + key.rawRepresentation
            + Data([0xa0, 0x0a, 0x06, 0x08, 0x2a, 0x86, 0x48, 0xce, 0x3d, 0x03,
                    0x01, 0x07, 0xa1, 0x44, 0x03, 0x42, 0x00])
            + key.publicKey.x963Representation
    }

    private static func request(method: String, path: String, token: String?,
                                payload: [String: Any], send: Transport) async throws -> [String: Any] {
        try Task.checkCancellation()
        var request = URLRequest(url: URL(string: base + path)!)
        request.httpMethod = method
        request.timeoutInterval = 12
        request.httpBody = try JSONSerialization.data(withJSONObject: payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("WARP for Android", forHTTPHeaderField: "User-Agent")
        request.setValue("a-6.35-4471", forHTTPHeaderField: "CF-Client-Version")
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        let (data, response) = try await send(request)
        try Task.checkCancellation()
        guard (200..<300).contains(response.statusCode), data.count <= 65536 else {
            // Never surface a response body: providers may echo credentials.
            throw HarborProxyError.invalid("独立通道注册失败（HTTP \(response.statusCode)）")
        }
        guard let result = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw HarborProxyError.invalid("独立通道注册响应格式无效")
        }
        return result
    }
}
