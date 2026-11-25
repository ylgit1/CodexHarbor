import CodexHarborCore
import Foundation

/// Verification for an explicitly granted alternative. Every network request
/// uses the candidate's own listener; there is no direct-network retry.
enum HarborDetachedFallbackVerification {
    private struct NetworkType: Decodable {
        let ip: String
        let isp: String?
        let connection_type: String?
        let user_type: String?
        let is_anycast: Bool?
        let country_code: String?
    }

    private struct Geography: Decodable {
        struct Connection: Decodable {
            let isp: String?
            let org: String?
        }
        let success: Bool
        let ip: String?
        let country_code: String?
        let connection: Connection?
    }

    static func observedIP(socksPort: Int) async -> String? {
        for target in ["https://checkip.amazonaws.com/", "https://api.ipify.org/"] {
            guard !Task.isCancelled else { return nil }
            let response = try? await HarborProxyCommand.run(URL(fileURLWithPath: "/usr/bin/curl"),
                arguments: ["--disable", "--silent", "--fail", "--max-time", "7", "--max-filesize", "256",
                    "--proto", "=https", "--proxy", "socks5h://127.0.0.1:\(socksPort)", "--noproxy", "", "--url", target],
                timeout: 8, outputLimit: 256)
            guard let response, response.status == 0,
                  let ip = HarborIPAddress.normalizedLiteral(String(decoding: response.data, as: UTF8.self)
                    .trimmingCharacters(in: .whitespacesAndNewlines)),
                  !HarborIPAddress.isLocal(ip) else { continue }
            return ip
        }
        return nil
    }

    static func evidence(ip: String, httpPort: Int) async -> HarborProxyNetworkEvidence {
        async let type = typeObservation(ip: ip, httpPort: httpPort)
        async let geo = geoObservation(ip: ip, httpPort: httpPort)
        let (a, b) = await (type, geo)
        return HarborProxyNetworkEvidence.combine(ip: ip, observations: [a, b].compactMap { $0 })
    }

    private static func typeObservation(ip: String, httpPort: Int) async -> HarborProxyNetworkEvidence.Observation? {
        guard var parts = URLComponents(string: "https://ip-info.com/json") else { return nil }
        parts.queryItems = [URLQueryItem(name: "ip", value: ip)]
        guard let url = parts.url, let data = await fetch(url, httpPort: httpPort),
              let result = try? JSONDecoder().decode(NetworkType.self, from: data),
              HarborIPAddress.equivalent(ip, result.ip) else { return nil }
        return .init(source: "ip-info.com", kind: HarborProxyNetworkEvidence.classify(
            userType: result.user_type, connectionType: result.connection_type, isAnycast: result.is_anycast),
            isp: result.isp, countryCode: result.country_code)
    }

    private static func geoObservation(ip: String, httpPort: Int) async -> HarborProxyNetworkEvidence.Observation? {
        guard let url = URL(string: "https://ipwho.is/\(ip)?fields=success,ip,country_code,connection"),
              let data = await fetch(url, httpPort: httpPort),
              let result = try? JSONDecoder().decode(Geography.self, from: data),
              result.success, let observed = result.ip, HarborIPAddress.equivalent(ip, observed)
        else { return nil }
        return .init(source: "ipwho.is", kind: nil,
                     isp: result.connection?.isp ?? result.connection?.org, countryCode: result.country_code)
    }

    private static func fetch(_ url: URL, httpPort: Int) async -> Data? {
        guard !Task.isCancelled else { return nil }
        let result = try? await HarborProxyHTTPBody.data(for: URLRequest(url: url),
            configuration: HarborProxyHTTP.configuration(httpPort: httpPort),
            limit: 4096, timeout: 5, status: 200..<201)
        return result?.0
    }
}
