import CodexHarborCore
import Foundation

/// Screens only public relay entry IPs. A positive result is still a candidate
/// until an end-to-end exit test passes; it is never a purity guarantee.
enum HarborVPNGateNetworkClassifier {
    private struct Response: Decodable {
        let ip: String
        let isp: String?
        let connectionType: String?
        let userType: String?
        let isAnycast: Bool?

        enum CodingKeys: String, CodingKey {
            case ip, isp
            case connectionType = "connection_type"
            case userType = "user_type"
            case isAnycast = "is_anycast"
        }
    }

    static func classify(_ nodes: [HarborProxyNode],
                         cached: [String: HarborProxyNetworkEvidence],
                         proxyPort: Int?) async -> [String: HarborProxyNetworkEvidence] {
        let fresh = cached.filter { Date.now.timeIntervalSince($0.value.checkedAt) < 24 * 60 * 60 }
        let ips = HarborVPNGate.unclassifiedVolunteerIPs(
            in: nodes, cached: Set(fresh.keys), limit: 48)
        guard !ips.isEmpty else { return [:] }
        var updates: [String: HarborProxyNetworkEvidence] = [:]
        await withTaskGroup(of: (String, HarborProxyNetworkEvidence?).self) { group in
            var next = 0
            for _ in 0..<min(4, ips.count) {
                let ip = ips[next]
                next += 1
                group.addTask { (ip, await lookup(ip: ip, proxyPort: proxyPort)) }
            }
            while let (ip, evidence) = await group.next() {
                if let evidence { updates[ip] = evidence }
                if next < ips.count {
                    let ip = ips[next]
                    next += 1
                    group.addTask { (ip, await lookup(ip: ip, proxyPort: proxyPort)) }
                }
            }
        }
        return updates
    }

    private static func lookup(ip: String, proxyPort: Int?) async -> HarborProxyNetworkEvidence? {
        guard var url = URLComponents(string: "https://ip-info.com/json") else { return nil }
        url.queryItems = [URLQueryItem(name: "ip", value: ip)]
        guard let endpoint = url.url else { return nil }
        let configuration = URLSessionConfiguration.ephemeral
        if let proxyPort {
            configuration.connectionProxyDictionary = [
                "HTTPEnable": 1, "HTTPProxy": "127.0.0.1", "HTTPPort": proxyPort,
                "HTTPSEnable": 1, "HTTPSProxy": "127.0.0.1", "HTTPSPort": proxyPort
            ]
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = 5
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              data.count <= 4_096,
              let value = try? JSONDecoder().decode(Response.self, from: data),
              value.ip == ip else { return nil }
        return HarborProxyNetworkEvidence(
            kind: HarborProxyNetworkEvidence.classify(
                userType: value.userType,
                connectionType: value.connectionType,
                isAnycast: value.isAnycast),
            isp: value.isp.map { String($0.prefix(80)) }
        )
    }
}
