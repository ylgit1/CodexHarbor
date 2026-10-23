import CodexHarborCore
import Foundation
import Darwin

/// Event-driven GeoIP lookup for the NODE SERVER, not the proxy's exit IP.
/// DNS is resolved off the main actor; the HTTPS country lookup is made only
/// for previously unseen IPs. No timer, per-row lookup or Xray process.
enum HarborNodeGeoIPResolver {
    private struct Response: Decodable {
        let success: Bool
        let ip: String?
        let country_code: String?
    }

    static func resolvedIP(for host: String) async -> String? {
        await Task.detached(priority: .utility) {
            let name = HarborIPAddress.socketHost(host)
            guard !name.isEmpty, name.utf8.count < 254 else { return nil as String? }
            // A literal IPv6 address (including URL-style [brackets]) needs
            // no DNS lookup and must not be passed to getaddrinfo with brackets.
            if let literal = HarborIPAddress.normalizedLiteral(name) {
                return isPublic(literal) ? literal : nil
            }
            var hints = addrinfo()
            hints.ai_family = AF_UNSPEC
            hints.ai_socktype = SOCK_STREAM
            var list: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(name, nil, &hints, &list) == 0, let head = list else {
                return nil
            }
            defer { freeaddrinfo(head) }
            var cursor: UnsafeMutablePointer<addrinfo>? = head
            var ipv6: String?
            while let current = cursor {
                let item = current.pointee
                if item.ai_family == AF_INET, let addr = item.ai_addr {
                    var raw = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in.self).pointee.sin_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                    if inet_ntop(AF_INET, &raw, &buffer, socklen_t(buffer.count)) != nil {
                        let ip = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if isPublic(ip) { return ip }
                    }
                } else if item.ai_family == AF_INET6, let addr = item.ai_addr {
                    var raw = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_addr
                    var buffer = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    if inet_ntop(AF_INET6, &raw, &buffer, socklen_t(buffer.count)) != nil {
                        let ip = String(decoding: buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }, as: UTF8.self)
                        if isPublic(ip) { ipv6 = ip }
                    }
                }
                cursor = item.ai_next
            }
            return ipv6
        }.value
    }

    static func countryCode(for ip: String, proxyPort: Int? = nil) async -> String? {
        // Only the public IP is sent to the geolocation provider; node labels,
        // subscriptions, credentials and DNS host names are never transmitted.
        guard let canonicalIP = HarborIPAddress.normalizedLiteral(ip),
              isPublic(canonicalIP),
              let encoded = canonicalIP.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed),
              let url = URL(string: "https://ipwho.is/\(encoded)?fields=success,ip,country_code") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 6
        config.waitsForConnectivity = false
        if let proxyPort {
            config.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort
            ]
        }
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 16_384,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              result.success,
              let returnedIP = result.ip,
              HarborIPAddress.equivalent(returnedIP, canonicalIP),
              let code = result.country_code?.uppercased(),
              code.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else {
            return nil
        }
        return code
    }

    /// Query the IP actually observed by the geolocation provider via an
    /// isolated Xray SOCKS inbound. Callers must use a forced-proxy outbound,
    /// never the macOS system proxy or a direct-route runtime listener.
    static func exitLocation(socksPort: Int) async -> HarborProxyIPLocation? {
        guard (1...65_535).contains(socksPort), !Task.isCancelled,
              let url = URL(string: "https://ipwho.is/?fields=success,ip,country_code") else {
            return nil
        }
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [
            "SOCKSEnable": 1,
            "SOCKSProxy": "127.0.0.1",
            "SOCKSPort": socksPort
        ]
        config.timeoutIntervalForRequest = 6
        config.timeoutIntervalForResource = 6
        config.waitsForConnectivity = false
        let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData)
        request.timeoutInterval = 6
        guard let (data, response) = try? await session.data(for: request),
              !Task.isCancelled,
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count < 4_096,
              let result = try? JSONDecoder().decode(Response.self, from: data),
              result.success, let observedIP = result.ip,
              let canonical = HarborIPAddress.normalizedLiteral(observedIP),
              isPublic(canonical),
              let code = result.country_code?.uppercased(),
              code.count == 2,
              code.utf8.allSatisfy({ (65...90).contains($0) }),
              code != "ZZ" else { return nil }
        return HarborProxyIPLocation(ip: canonical, countryCode: code)
    }

    static func isPublic(_ ip: String) -> Bool {
        guard let normalized = HarborIPAddress.normalizedLiteral(ip) else { return false }
        var v4 = in_addr()
        if inet_pton(AF_INET, normalized, &v4) == 1 {
            let bits = UInt32(bigEndian: v4.s_addr)
            let a = (bits >> 24) & 0xff
            let b = (bits >> 16) & 0xff
            return a != 0 && a != 10 && a != 127 && a < 224
                && !(a == 100 && (64...127).contains(b))
                && !(a == 169 && b == 254)
                && !(a == 172 && (16...31).contains(b))
                && !(a == 192 && (b == 168 || b == 0))
                && !(a == 198 && (b == 18 || b == 19))
            }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, normalized, &v6) == 1 {
            let bytes = withUnsafeBytes(of: &v6) { Array($0) }
            // Unspecified, loopback, unique-local, multicast and link-local.
            return !(bytes.prefix(15).allSatisfy { $0 == 0 })
                && (bytes[0] & 0xfe) != 0xfc
                && bytes[0] != 0xff
                && !(bytes[0] == 0xfe && (bytes[1] & 0xc0) == 0x80)
                && !(bytes[0] == 0x20 && bytes[1] == 0x01 && bytes[2] == 0x0d && bytes[3] == 0xb8)
        }
        return false
    }
}
