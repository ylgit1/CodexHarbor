import Foundation

/// Describes the node's source and screening evidence, independently of the
/// selected sidebar group, node name, protocol, or an OpenVPN underlay.
public enum HarborProxyConnectionType: Sendable, Equatable {
    case subscription
    case residentialCandidate
    case vpnGateResidential
    case vpnGateVolunteer
    case vpnGateDatacenter
    case imported

    public var title: String {
        switch self {
        case .subscription: "订阅节点"
        case .residentialCandidate: "住宅候选"
        case .vpnGateResidential: "VPN Gate · 家宽候选"
        case .vpnGateVolunteer: "VPN Gate · 志愿节点"
        case .vpnGateDatacenter: "VPN Gate · 机房候选"
        case .imported: "手动导入"
        }
    }

    public var detail: String {
        switch self {
        case .subscription: "来自订阅的代理节点。"
        case .residentialCandidate: "来自住宅候选订阅，住宅属性为上游标签，未保证当前出口属性。"
        case .vpnGateResidential: "VPN Gate 志愿节点，公开网络数据将其入口标记为家宽候选，未保证当前出口属性。"
        case .vpnGateVolunteer: "VPN Gate 志愿节点，尚未识别为家宽入口。"
        case .vpnGateDatacenter: "VPN Gate 志愿节点，来源或公开网络数据将其标记为机房候选。"
        case .imported: "通过节点链接手动导入，未关联订阅。"
        }
    }

    public static func classify(
        node: HarborProxyNode,
        subscription: HarborProxySubscription?,
        evidence: HarborProxyNetworkEvidence?
    ) -> Self {
        guard let subscription, subscription.id == node.subscriptionID else {
            return node.subscriptionID.isEmpty ? .imported : .subscription
        }
        switch HarborProxyCommunitySource.matching(subscription.url) {
        case .vpnGate:
            // Preserve the same precedence as the workspace's category filter.
            if node.security == "vpngate-datacenter" { return .vpnGateDatacenter }
            switch evidence?.kind {
            case .residential: return .vpnGateResidential
            case .hosting: return .vpnGateDatacenter
            default: return .vpnGateVolunteer
            }
        case .residential: return .residentialCandidate
        case nil: return .subscription
        }
    }
}
