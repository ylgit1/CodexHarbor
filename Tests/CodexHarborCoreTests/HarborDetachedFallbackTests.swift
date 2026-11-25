import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Detached proxy fallback authorization")
struct HarborDetachedFallbackTests {
    private func node(_ id: String) -> HarborProxyNode {
        .init(id: id, name: id, protocolName: "vless", host: "example.com",
              port: 443, credential: "test-fixture")
    }

    @Test func exactEndpointAuthorization() {
        let original = node("a")
        var policy = HarborProxyFallbackPolicy(authorizedEndpoints: [original.id: original.endpointSignature])
        #expect(!policy.permits(nodeID: original.id, signature: original.endpointSignature))
        policy.enabled = true
        #expect(policy.permits(nodeID: original.id, signature: original.endpointSignature))
        var changed = original
        changed.port = 8443
        #expect(!policy.permits(nodeID: changed.id, signature: changed.endpointSignature))
    }

    @Test func detachedGrantRoundTrip() throws {
        let a = node("a"), b = node("b")
        let evidence = HarborProxyNetworkEvidence(kind: .residential, isp: nil,
            confidence: .singleSource, countryCode: "US", observedIP: "192.0.2.1")
        let grant = HarborDetachedFallbackGrant(primaryID: UUID(), sourceNode: a,
            sourceEvidence: evidence, candidates: [b])
        let request = HarborProxyAgentRequest(.grantDetachedFallback(grant))
        let restored = try JSONDecoder().decode(HarborProxyAgentRequest.self, from: JSONEncoder().encode(request))
        guard case .grantDetachedFallback(let payload) = restored.command else {
            Issue.record("Unexpected request"); return
        }
        let result = try #require(payload)
        #expect(result.primaryID == grant.primaryID)
        #expect(result.sourceNode.endpointSignature == a.endpointSignature)
        #expect(result.candidates.map(\.id) == ["b"])
        #expect(result.underlayNode == nil)
        #expect(result.warpAccount == nil)
    }

    @Test func fallbackRejectsDifferentOrExpiredExitEvidence() throws {
        let now = Date()
        let source = HarborProxyNetworkEvidence(kind: .hosting, isp: nil, checkedAt: now,
            confidence: .singleSource, countryCode: "US", observedIP: "192.0.2.1")
        let rule = try #require(HarborProxyFallbackPolicy.ExitConstraint(
            evidence: source, observedIP: "192.0.2.1", now: now))
        let matching = HarborProxyNetworkEvidence(kind: .hosting, isp: nil, checkedAt: now,
            confidence: .singleSource, countryCode: "US", observedIP: "192.0.2.2")
        #expect(rule.matches(evidence: matching, observedIP: "192.0.2.2", now: now))
        #expect(!rule.matches(evidence: matching, observedIP: "192.0.2.3", now: now))
        #expect(!rule.matches(evidence: matching, observedIP: "192.0.2.2",
                              now: now.addingTimeInterval(90_000)))
        let conflicting = HarborProxyNetworkEvidence(kind: .unknown, isp: nil, checkedAt: now,
            confidence: .conflicting, countryCode: "US", observedIP: "192.0.2.2")
        #expect(!rule.matches(evidence: conflicting, observedIP: "192.0.2.2", now: now))
    }
}
