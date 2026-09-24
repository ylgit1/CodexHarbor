import Foundation

struct CloudflareZoneService {
    private struct ZoneListResponse: Decodable {
        struct Zone: Decodable {
            let name: String
        }

        struct APIError: Decodable {
            let message: String
        }

        let success: Bool
        let result: [Zone]
        let errors: [APIError]
    }

    enum ServiceError: LocalizedError {
        case invalidEndpoint
        case requestFailed
        case api(String)

        var errorDescription: String? {
            switch self {
            case .invalidEndpoint:
                return "Cloudflare Zones API 地址无效。"
            case .requestFailed:
                return "Cloudflare 域名获取失败，请检查 API Token 的 Zone:Read 权限。"
            case .api(let message):
                return message
            }
        }
    }

    func activeZones(apiToken: String) async throws -> [String] {
        var components = URLComponents(string: "https://api.cloudflare.com/client/v4/zones")
        components?.queryItems = [
            URLQueryItem(name: "per_page", value: "50"),
            URLQueryItem(name: "status", value: "active")
        ]
        guard let url = components?.url else {
            throw ServiceError.invalidEndpoint
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Bearer \(apiToken)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode) else {
            throw ServiceError.requestFailed
        }

        let decoded = try JSONDecoder().decode(ZoneListResponse.self, from: data)
        guard decoded.success else {
            throw ServiceError.api(decoded.errors.first?.message ?? "Cloudflare 域名获取失败。")
        }

        return Array(Set(decoded.result.map(\.name))).sorted()
    }
}
