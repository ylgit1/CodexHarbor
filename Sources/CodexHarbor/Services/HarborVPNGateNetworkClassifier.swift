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
                         proxyPort: Int?, cancellation: HarborLatencyCancellation) async -> [String: HarborProxyNetworkEvidence] {
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
                group.addTask { (ip, await lookup(ip: ip, proxyPort: proxyPort, cancellation: cancellation)) }
            }
            while let (ip, evidence) = await group.next() {
                if cancellation.isCancelled || Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let evidence { updates[ip] = evidence }
                if next < ips.count {
                    let ip = ips[next]
                    next += 1
                    group.addTask { (ip, await lookup(ip: ip, proxyPort: proxyPort, cancellation: cancellation)) }
                }
            }
        }
        return updates
    }

    private static func lookup(ip: String, proxyPort: Int?,
                               cancellation: HarborLatencyCancellation) async -> HarborProxyNetworkEvidence? {
        guard var url = URLComponents(string: "https://ip-info.com/json") else { return nil }
        url.queryItems = [URLQueryItem(name: "ip", value: ip)]
        guard let endpoint = url.url else { return nil }
        guard let lease = await HarborProbeBudget.requests.acquire(cancellation) else { return nil }
        let load = Task {
            try await HarborProxyHTTPBody.data(for: URLRequest(url: endpoint),
                configuration: HarborProxyHTTP.configuration(httpPort: proxyPort),
                limit: 4_096, timeout: 5, status: 200..<201)
        }
        let observer = cancellation.observe { load.cancel() }
        let result = await withTaskCancellationHandler {
            try? await load.value
        } onCancel: { load.cancel() }
        if let observer { cancellation.removeObserver(observer) }
        await HarborProbeBudget.requests.release(lease)
        guard !cancellation.isCancelled, let (data, _) = result,
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
