import Foundation

/// Generated rules protect the gateway and its internal listeners without
/// disabling legitimate local-network access on other ports.
public enum HarborGatewayConfiguration {
    public static let verificationHosts = [
        "www.gstatic.com", "www.google.com", "example.com",
        "checkip.amazonaws.com", "api.ipify.org", "ip-info.com", "ipwho.is"
    ]

    public static func isLoopback(_ host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name == "localhost" || name.hasSuffix(".localhost") { return true }
        guard let address = HarborIPAddress.normalizedLiteral(host) else { return false }
        return address == "::1" || address.hasPrefix("127.") || address.hasPrefix("::ffff:127.")
    }

    public static func protectXray(_ data: Data, ports: Set<Int>, aliases: [String] = []) throws -> Data {
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var routing = config["routing"] as? [String: Any],
              let existing = routing["rules"] as? [[String: Any]],
              var outbounds = config["outbounds"] as? [[String: Any]] else {
            throw HarborProxyError.invalid("固定入口 Xray 配置无效")
        }
        let protected = validPorts(ports).map(String.init).joined(separator: ",")
        guard !protected.isEmpty else { throw HarborProxyError.invalid("固定入口端口无效") }
        let denied = "codexharbor-gateway-denied"
        let localDomains = ["domain:localhost"] + aliases.map { "full:\($0)" }
        let rules: [[String: Any]] = [
            ["type": "field", "ip": ["127.0.0.0/8", "::1/128"],
             "port": protected, "outboundTag": denied],
            ["type": "field", "domain": localDomains, "port": protected, "outboundTag": denied],
            ["type": "field", "domain": verificationHosts.map { "full:\($0)" }, "outboundTag": "proxy"]
        ]
        outbounds.append(["protocol": "blackhole", "tag": denied])
        config["outbounds"] = outbounds
        routing["rules"] = rules + existing
        config["routing"] = routing
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
    }

    public static func protectMihomo(_ data: Data, ports: Set<Int>, aliases: [String] = [], verificationOutbound: String = "selected") throws -> Data {
        guard var config = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let existing = config["rules"] as? [String] else {
            throw HarborProxyError.invalid("固定入口 Mihomo 配置无效")
        }
        let protected = validPorts(ports)
        guard !protected.isEmpty else { throw HarborProxyError.invalid("固定入口端口无效") }
        var rules: [String] = []
        for port in protected {
            rules.append("AND,((IP-CIDR,127.0.0.0/8),(DST-PORT,\(port))),REJECT")
            rules.append("AND,((IP-CIDR6,::1/128),(DST-PORT,\(port))),REJECT")
            rules.append("AND,((DOMAIN-SUFFIX,localhost),(DST-PORT,\(port))),REJECT")
            rules += aliases.map { "AND,((DOMAIN,\($0)),(DST-PORT,\(port))),REJECT" }
        }
        rules += verificationHosts.map { "DOMAIN,\($0),\(verificationOutbound)" }
        config["rules"] = rules + existing
        return try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys, .withoutEscapingSlashes])
    }

    private static func validPorts(_ ports: Set<Int>) -> [Int] {
        ports.filter { (1...65535).contains($0) }.sorted()
    }
}
