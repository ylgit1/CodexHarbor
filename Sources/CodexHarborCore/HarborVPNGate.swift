import Foundation

/// VPN Gate publishes volunteer OpenVPN profiles, not proof of residential
/// ownership. A profile is only a candidate until an actual exit test passes.
public enum HarborVPNGate {
    public static let feedURL = "https://www.vpngate.net/api/iphone/"

    public static func unclassifiedVolunteerIPs(in nodes: [HarborProxyNode],
                                                cached: Set<String>, limit: Int) -> [String] {
        guard limit > 0 else { return [] }
        var seen = Set<String>()
        var ips: [String] = []
        for node in nodes where node.security != "vpngate-datacenter" {
            guard !cached.contains(node.host), seen.insert(node.host).inserted else { continue }
            ips.append(node.host)
            if ips.count == limit { break }
        }
        return ips
    }

    public static func parse(_ text: String, subscriptionID: String) -> [HarborProxyNode] {
        var parsed: [(node: HarborProxyNode, score: Int)] = []
        var seen = Set<String>()
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = String(rawLine).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("*"), !line.hasPrefix("#") else { continue }
            let row = csvFields(line)
            guard row.count >= 15,
                  let encoded = Data(base64Encoded: row[14]),
                  encoded.count < 64_000,
                  let profile = String(data: encoded, encoding: .utf8),
                  let settings = OpenVPNProfile(profile),
                  isPublicIPv4(settings.server),
                  let country = countryCode(row[6]) else { continue }
            let hostname = row[0].trimmingCharacters(in: .whitespacesAndNewlines)
            let datacenter = hostname.lowercased().hasPrefix("public-vpn")
            let key = "\(settings.server):\(settings.port):\(settings.proto)"
            guard seen.insert(key).inserted else { continue }
            let score = Int(row[2]) ?? 0
            let node = HarborProxyNode(
                name: "\(country) · \(hostname.isEmpty ? settings.server : hostname)",
                protocolName: "openvpn", host: settings.server,
                port: settings.port, credential: row[14],
                network: settings.proto,
                security: datacenter ? "vpngate-datacenter" : "vpngate-unverified",
                path: country, subscriptionID: subscriptionID
            )
            parsed.append((node, score))
        }
        // Keep country diversity. The publisher's score is for ordering, not
        // evidence that the relay works on this user's current network.
        parsed.sort {
            if ($0.node.network == "tcp") != ($1.node.network == "tcp") {
                return $0.node.network == "tcp"
            }
            return $0.score > $1.score
        }
        var countryCounts: [String: Int] = [:]
        var volunteer: [HarborProxyNode] = []
        var datacenter: [HarborProxyNode] = []
        for item in parsed {
            let key = "\(item.node.security):\(item.node.path)"
            guard countryCounts[key, default: 0] < 12 else { continue }
            countryCounts[key, default: 0] += 1
            if item.node.security == "vpngate-datacenter" {
                if datacenter.count < 30 { datacenter.append(item.node) }
            } else if volunteer.count < 150 {
                volunteer.append(item.node)
            }
        }
        return volunteer + datacenter
    }

    private static func countryCode(_ raw: String) -> String? {
        let code = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard code.count == 2, code.utf8.allSatisfy({ (65...90).contains($0) }) else { return nil }
        return code
    }

    private static func isPublicIPv4(_ raw: String) -> Bool {
        let octets = raw.split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { UInt8($0) }
        guard octets.count == 4 else { return false }
        let a = octets[0], b = octets[1], c = octets[2]
        return a > 0 && a < 224 && a != 10 && a != 127
            && !(a == 100 && (64...127).contains(b))
            && !(a == 169 && b == 254)
            && !(a == 172 && (16...31).contains(b))
            && !(a == 192 && (b == 168 || b == 0))
            && !(a == 198 && (b == 18 || b == 19 || (b == 51 && c == 100)))
            && !(a == 203 && b == 0 && c == 113)
    }

    /// CSV fields may contain quoted commas in the operator or country name.
    private static func csvFields(_ line: String) -> [String] {
        var fields: [String] = []
        var value = ""
        var quoted = false
        let chars = Array(line)
        var index = 0
        while index < chars.count {
            let char = chars[index]
            if char == "\"" {
                if quoted && index + 1 < chars.count && chars[index + 1] == "\"" {
                    value.append("\"")
                    index += 1
                } else {
                    quoted.toggle()
                }
            } else if char == "," && !quoted {
                fields.append(value)
                value = ""
            } else {
                value.append(char)
            }
            index += 1
        }
        fields.append(value)
        return fields
    }
}

public enum HarborVPNGateProbePolicy {
    /// Try untested home-line candidates first, then other untested relays.
    /// A second rescan advances through the pool instead of retesting the
    /// same failed first page forever.
    public static func select(nodes: [HarborProxyNode],
                              evidence: [String: HarborProxyNetworkEvidence],
                              results: [String: HarborProxyProbeResult],
                              limit: Int, probeRouteID: String? = nil) -> [HarborProxyNode] {
        guard limit > 0 else { return [] }
        let ranked = nodes.enumerated().sorted { lhs, rhs in
            let left = classRank(lhs.element, evidence: evidence)
            let right = classRank(rhs.element, evidence: evidence)
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        // A change from direct to a working SOCKS underlay is a new test path.
        // Previously failed nodes must receive another chance, not retain their
        // old red verdict or inherit their previous failure counter.
        let untested = ranked.filter { node in
            guard let result = results[node.id], result.realTested else { return true }
            return probeRouteID != nil && result.probeRouteID != probeRouteID
        }
        let failed = ranked.enumerated().filter { _, node in
            guard let result = results[node.id] else { return false }
            return result.realTested && result.milliseconds == nil
                && (probeRouteID == nil || result.probeRouteID == probeRouteID)
        }.sorted { lhs, rhs in
            let left = results[lhs.element.id]?.effectiveRealCheckedAt ?? .distantPast
            let right = results[rhs.element.id]?.effectiveRealCheckedAt ?? .distantPast
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        let stale = ranked.filter { node in
            guard let result = results[node.id] else { return false }
            return result.milliseconds != nil && result.isStale()
                && (probeRouteID == nil || result.probeRouteID == probeRouteID)
        }
        return Array((untested + failed + stale).prefix(limit))
    }

    private static func classRank(_ node: HarborProxyNode,
                                  evidence: [String: HarborProxyNetworkEvidence]) -> Int {
        if evidence[node.host]?.kind == .residential { return 0 }
        if node.security == "vpngate-datacenter" || evidence[node.host]?.kind == .hosting {
            return 2
        }
        return 1
    }
}

/// Deliberately accepts only inline certificates and keys. It never follows
/// file paths or other commands embedded in an untrusted VPN Gate profile.
public struct OpenVPNProfile: Sendable {
    public let server: String
    public let port: Int
    public let proto: String
    public let ca: String
    public let cert: String
    public let key: String
    public let tlsAuth: String
    public let tlsCrypt: String
    public let tlsCryptV2: String
    public let keyDirection: String
    public let cipher: String
    public let dataCiphers: [String]
    public let auth: String
    public let compLZO: String
    public let device: String

    public init?(_ raw: String) {
        var values: [String: String] = [:]
        var blocks: [String: String] = [:]
        var block: String?
        var body = ""
        for rawLine in raw.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if let current = block {
                if line.lowercased() == "</\(current)>" {
                    blocks[current] = body
                    block = nil
                    body = ""
                } else {
                    body += line + "\n"
                }
                continue
            }
            if line.hasPrefix("<"), line.hasSuffix(">"), !line.hasPrefix("</") {
                block = String(line.dropFirst().dropLast()).lowercased()
                continue
            }
            guard !line.isEmpty, !line.hasPrefix("#"), !line.hasPrefix(";") else { continue }
            let parts = line.split(whereSeparator: \.isWhitespace).map(String.init)
            guard let directive = parts.first else { continue }
            if directive.lowercased() == "remote", parts.count >= 3,
               values["remote"] == nil {
                values["remote"] = parts[1]
                values["port"] = parts[2]
            } else if parts.count >= 2, values[directive.lowercased()] == nil {
                values[directive.lowercased()] = parts[1]
            }
        }
        guard let server = values["remote"], !server.isEmpty,
              let port = Int(values["port"] ?? ""), (1...65535).contains(port),
              let ca = blocks["ca"], ca.contains("BEGIN CERTIFICATE"),
              let cert = blocks["cert"], cert.contains("BEGIN CERTIFICATE"),
              let key = blocks["key"], key.contains("BEGIN PRIVATE KEY") || key.contains("BEGIN RSA PRIVATE KEY") else {
            return nil
        }
        let protocolValue = values["proto"]?.lowercased() ?? "tcp"
        guard protocolValue == "udp" || protocolValue.hasPrefix("tcp") else { return nil }
        self.server = server
        self.port = port
        self.proto = protocolValue == "udp" ? "udp" : "tcp"
        self.ca = ca
        self.cert = cert
        self.key = key
        self.tlsAuth = blocks["tls-auth"] ?? ""
        self.tlsCrypt = blocks["tls-crypt"] ?? ""
        self.tlsCryptV2 = blocks["tls-crypt-v2"] ?? ""
        self.keyDirection = values["key-direction"] ?? ""
        self.cipher = values["cipher"] ?? ""
        self.dataCiphers = values["data-ciphers"]?.split(separator: ":").map(String.init) ?? []
        self.auth = values["auth"] ?? ""
        self.compLZO = values["comp-lzo"] ?? ""
        self.device = values["dev"] ?? "tun"
    }
}

public enum HarborMihomoConfig {
    public static func make(node: HarborProxyNode, httpPort: Int,
                            underlaySocksPort: Int? = nil) throws -> Data {
        guard node.protocolName == "openvpn", (1024...65534).contains(httpPort),
              let data = Data(base64Encoded: node.credential),
              let text = String(data: data, encoding: .utf8),
              let profile = OpenVPNProfile(text),
              profile.server == node.host, profile.port == node.port,
              profile.proto == node.network else {
            throw HarborProxyError.invalid("OpenVPN 节点配置无效")
        }
        if let underlaySocksPort, !(1024...65535).contains(underlaySocksPort) {
            throw HarborProxyError.invalid("底座代理端口无效")
        }
        var outbound: [String: Any] = [
            "name": "selected", "type": "openvpn", "server": profile.server,
            "port": profile.port, "proto": profile.proto,
            "ca": profile.ca, "cert": profile.cert, "key": profile.key,
            "dev": profile.device,
            "handshake-timeout": 30
        ]
        if underlaySocksPort != nil { outbound["dialer-proxy"] = "underlay" }
        if !profile.tlsAuth.isEmpty { outbound["tls-auth"] = profile.tlsAuth }
        if !profile.tlsCrypt.isEmpty { outbound["tls-crypt"] = profile.tlsCrypt }
        if !profile.tlsCryptV2.isEmpty { outbound["tls-crypt-v2"] = profile.tlsCryptV2 }
        if !profile.keyDirection.isEmpty { outbound["key-direction"] = profile.keyDirection }
        if !profile.cipher.isEmpty { outbound["cipher"] = profile.cipher }
        if !profile.dataCiphers.isEmpty { outbound["data-ciphers"] = profile.dataCiphers }
        if !profile.auth.isEmpty { outbound["auth"] = profile.auth }
        if !profile.compLZO.isEmpty { outbound["comp-lzo"] = profile.compLZO }
        var proxies: [[String: Any]] = [outbound]
        if let underlaySocksPort {
            proxies.append([
                "name": "underlay", "type": "socks5", "server": "127.0.0.1",
                "port": underlaySocksPort
            ])
        }
        // Resolve destination domains inside Mihomo instead of inheriting the
        // macOS resolver. The DoH upstreams are explicitly sent through the
        // selected OpenVPN outbound; bootstrap resolvers are IP literals so
        // resolving the DoH host never depends on the system DNS or on itself.
        let dns: [String: Any] = [
            "enable": true,
            "ipv6": false,
            "enhanced-mode": "redir-host",
            "use-hosts": true,
            "use-system-hosts": false,
            "respect-rules": true,
            "default-nameserver": ["1.1.1.1", "8.8.8.8"],
            "proxy-server-nameserver": ["1.1.1.1", "8.8.8.8"],
            "nameserver": [
                "https://cloudflare-dns.com/dns-query#selected",
                "https://dns.google/dns-query#selected"
            ]
        ]
        let config: [String: Any] = [
            "port": httpPort, "socks-port": httpPort + 1,
            "allow-lan": false, "mode": "rule", "log-level": "warning",
            "dns": dns, "proxies": proxies, "rules": ["MATCH,selected"]
        ]
        // JSON is valid YAML; it also avoids hand-quoting certificate blocks.
        return try JSONSerialization.data(withJSONObject: config,
                                          options: [.sortedKeys, .withoutEscapingSlashes])
    }

    public static func matches(configuration: Data, node: HarborProxyNode,
                               underlaySocksPort: Int? = nil) -> Bool {
        guard node.protocolName == "openvpn",
              let expected = try? make(node: node, httpPort: HarborProxyPortPolicy.defaultHTTPPort,
                                       underlaySocksPort: underlaySocksPort),
              let actualObject = try? JSONSerialization.jsonObject(with: configuration) as? [String: Any],
              let expectedObject = try? JSONSerialization.jsonObject(with: expected) as? [String: Any],
              let actual = actualObject["proxies"] as? [[String: Any]],
              let wanted = expectedObject["proxies"] as? [[String: Any]],
              let actualDNS = actualObject["dns"] as? [String: Any],
              let wantedDNS = expectedObject["dns"] as? [String: Any],
              actual.count == wanted.count,
              NSDictionary(dictionary: actualDNS).isEqual(to: wantedDNS) else { return false }
        return zip(actual, wanted).allSatisfy { pair in
            NSDictionary(dictionary: pair.0).isEqual(to: pair.1)
        }
    }
}
