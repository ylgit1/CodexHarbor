import Foundation

/// Automatic switching is a separate opt-in, scoped to the exact endpoint
/// configuration. Unknown or conflicting exit attributes never qualify.
public struct HarborProxyFallbackPolicy: Codable, Equatable, Sendable {
    public var enabled: Bool
    public var authorizedEndpoints: [String: String]

    public init(enabled: Bool = false, authorizedEndpoints: [String: String] = [:]) {
        self.enabled = enabled
        self.authorizedEndpoints = authorizedEndpoints
    }

    public func permits(nodeID: String, signature: String) -> Bool {
        enabled && authorizedEndpoints[nodeID] == signature
    }

    public struct ExitConstraint: Equatable, Sendable {
        public let countryCode: String
        public let kind: HarborProxyNetworkEvidence.Kind

        public init?(evidence: HarborProxyNetworkEvidence, observedIP: String, now: Date = .now) {
            guard evidence.isFresh(now: now), let ip = evidence.observedIP,
                  HarborIPAddress.equivalent(ip, observedIP),
                  let country = evidence.countryCode, country.count == 2,
                  country.utf8.allSatisfy({ (65...90).contains($0) }), country != "ZZ",
                  [.residential, .cellular, .hosting].contains(evidence.kind),
                  evidence.confidence == .singleSource || evidence.confidence == .corroborated
            else { return nil }
            self.countryCode = country
            self.kind = evidence.kind
        }

        public func matches(evidence: HarborProxyNetworkEvidence, observedIP: String, now: Date = .now) -> Bool {
            Self(evidence: evidence, observedIP: observedIP, now: now) == self
        }
    }
}
