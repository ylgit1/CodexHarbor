import Testing
@testable import CodexHarborCore

struct HarborProxyConnectionTypeTests {
    private let gate = HarborProxySubscription(id: "gate", name: "自定义名称", url: HarborVPNGate.feedURL)

    private func node(subscriptionID: String = "gate", security: String = "") -> HarborProxyNode {
        HarborProxyNode(name: "住宅候选-名称不能决定类型", protocolName: "openvpn",
                        host: "192.0.2.1", port: 443, credential: "test",
                        security: security, subscriptionID: subscriptionID)
    }

    @Test("VPN Gate uses network evidence without treating volunteers as confirmed residential",
          arguments: [HarborProxyNetworkEvidence.Kind.residential, .hosting, .cellular, .other])
    func gateEvidence(kind: HarborProxyNetworkEvidence.Kind) {
        let result = HarborProxyConnectionType.classify(
            node: node(), subscription: gate, evidence: .init(kind: kind, isp: nil)
        )
        let expected: HarborProxyConnectionType = switch kind {
        case .residential: .vpnGateResidential
        case .hosting: .vpnGateDatacenter
        default: .vpnGateVolunteer
        }
        #expect(result == expected)
    }

    @Test("VPN Gate without evidence stays a volunteer; datacenter source tags take precedence")
    func gateWithoutEvidenceAndDatacenterTag() {
        #expect(HarborProxyConnectionType.classify(node: node(), subscription: gate, evidence: nil)
                == .vpnGateVolunteer)
        #expect(HarborProxyConnectionType.classify(
            node: node(security: "vpngate-datacenter"), subscription: gate,
            evidence: .init(kind: .residential, isp: nil)
        ) == .vpnGateDatacenter)
    }

    @Test("Ordinary subscriptions are not reclassified by an OpenVPN protocol, node name, or entry evidence")
    func ordinarySubscription() {
        let subscription = HarborProxySubscription(id: "gate", name: "VPN Gate 住宅节点",
                                                  url: "https://example.com/feed")
        #expect(HarborProxyConnectionType.classify(
            node: node(), subscription: subscription, evidence: .init(kind: .residential, isp: nil)
        ) == .subscription)
    }

    @Test("Both recognized residential feed URLs are labeled as candidates",
          arguments: [HarborProxyCommunitySource.residential.url,
                      HarborProxyCommunitySource.residential.fallbackURL])
    func residentialFeed(url: String) {
        let subscription = HarborProxySubscription(id: "gate", name: "住宅来源", url: url)
        #expect(HarborProxyConnectionType.classify(node: node(), subscription: subscription, evidence: nil)
                == .residentialCandidate)
    }

    @Test("Imported and orphaned subscription nodes have honest fallback types")
    func missingSubscription() {
        #expect(HarborProxyConnectionType.classify(node: node(subscriptionID: ""), subscription: nil, evidence: nil)
                == .imported)
        #expect(HarborProxyConnectionType.classify(node: node(), subscription: nil, evidence: nil)
                == .subscription)
    }

    @Test("Browsing another subscription cannot change the current node's type")
    func unrelatedSubscription() {
        #expect(HarborProxyConnectionType.classify(
            node: node(subscriptionID: "paid"), subscription: gate,
            evidence: .init(kind: .residential, isp: nil)
        ) == .subscription)
    }
}
