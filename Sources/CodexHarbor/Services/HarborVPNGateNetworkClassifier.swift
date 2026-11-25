import CodexHarborCore
import Foundation

/// Lookup explicit public IPs only. The two providers have different
/// capabilities: ISP/country metadata does not establish residential status.
enum HarborVPNGateNetworkClassifier {
    private struct Response: Decodable {
        let ip: String
        let isp: String?
        let connectionType: String?
        let userType: String?
        let isAnycast: Bool?
        let countryCode: String?

        enum CodingKeys: String, CodingKey {
            case ip, isp
            case connectionType = "connection_type"
            case userType = "user_type"
            case isAnycast = "is_anycast"
            case countryCode = "country_code"
        }
    }

    private struct GeoResponse: Decodable {
        struct Connection: Decodable {
            let isp: String?
            let org: String?
        }
        let success: Bool
        let ip: String?
        let countryCode: String?
        let connection: Connection?
        enum CodingKeys: String, CodingKey {
            case success, ip, connection
            case countryCode = "country_code"
        }
    }

    static func classify(_ nodes: [HarborProxyNode],
                         cached: [String: HarborProxyNetworkEvidence],
                         proxyPort: Int?, cancellation: HarborLatencyCancellation,
                         networkEpoch: UInt64? = nil, probeRouteID: String? = nil) async -> [String: HarborProxyNetworkEvidence] {
        let fresh = cached.filter { $0.value.isFresh() }
        let ips = HarborVPNGate.unclassifiedVolunteerIPs(
            in: nodes, cached: Set(fresh.keys), limit: 48)
        guard !ips.isEmpty else { return [:] }
        var updates: [String: HarborProxyNetworkEvidence] = [:]
        await withTaskGroup(of: (String, HarborProxyNetworkEvidence?).self) { group in
            var next = 0
            func submit(_ ip: String) {
                group.addTask {
                    (ip, await lookup(ip: ip, proxyPort: proxyPort, cancellation: cancellation,
                                      networkEpoch: networkEpoch, probeRouteID: probeRouteID))
                }
            }
            for _ in 0..<min(4, ips.count) {
                submit(ips[next]); next += 1
            }
            while let (ip, evidence) = await group.next() {
                if cancellation.isCancelled || Task.isCancelled {
                    group.cancelAll()
                    break
                }
                if let evidence { updates[ip] = evidence }
                if next < ips.count {
                    submit(ips[next]); next += 1
                }
            }
        }
        return updates
    }

    static func lookup(ip: String, proxyPort: Int?, cancellation: HarborLatencyCancellation,
                       networkEpoch: UInt64? = nil, probeRouteID: String? = nil) async -> HarborProxyNetworkEvidence? {
        guard let canonical = HarborIPAddress.normalizedLiteral(ip),
              HarborNodeGeoIPResolver.isPublic(canonical),
              !cancellation.isCancelled, !Task.isCancelled else { return nil }
        async let type = typeObservation(ip: canonical, proxyPort: proxyPort, cancellation: cancellation)
        async let geo = geoObservation(ip: canonical, proxyPort: proxyPort, cancellation: cancellation)
        let (a, b) = await (type, geo)
        guard !cancellation.isCancelled, !Task.isCancelled else { return nil }
        return HarborProxyNetworkEvidence.combine(ip: canonical, observations: [a, b].compactMap { $0 },
                    networkEpoch: networkEpoch, probeRouteID: probeRouteID)
    }

    private static func typeObservation(ip: String, proxyPort: Int?, cancellation: HarborLatencyCancellation)
        async -> HarborProxyNetworkEvidence.Observation? {
        guard var url = URLComponents(string: "https://ip-info.com/json") else { return nil }
        url.queryItems = [URLQueryItem(name: "ip", value: ip)]
        guard let endpoint = url.url,
              let data = await fetch(endpoint, proxyPort: proxyPort, cancellation: cancellation),
              let value = try? JSONDecoder().decode(Response.self, from: data),
              HarborIPAddress.equivalent(value.ip, ip) else { return nil }
        return .init(source: "ip-info.com", kind: HarborProxyNetworkEvidence.classify(
            userType: value.userType, connectionType: value.connectionType, isAnycast: value.isAnycast),
            isp: value.isp, countryCode: value.countryCode)
    }

    private static func geoObservation(ip: String, proxyPort: Int?, cancellation: HarborLatencyCancellation)
        async -> HarborProxyNetworkEvidence.Observation? {
        guard let endpoint = URL(string: "https://ipwho.is/\(ip)?fields=success,ip,country_code,connection"),
              let data = await fetch(endpoint, proxyPort: proxyPort, cancellation: cancellation),
              let value = try? JSONDecoder().decode(GeoResponse.self, from: data),
              value.success, let observed = value.ip, HarborIPAddress.equivalent(observed, ip) else { return nil }
        return .init(source: "ipwho.is", kind: nil,
                     isp: value.connection?.isp ?? value.connection?.org, countryCode: value.countryCode)
    }

    private static func fetch(_ endpoint: URL, proxyPort: Int?,
                              cancellation: HarborLatencyCancellation) async -> Data? {
        guard let lease = await HarborProbeBudget.requests.acquire(cancellation, priority: .geoIP) else { return nil }
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
        guard !cancellation.isCancelled, !Task.isCancelled else { return nil }
        return result?.0
    }
}
