import Foundation

/// Repeatable v2rayN imports replace source subscription groups, not only
/// profile IDs. Many subscription providers recreate IndexId values on update.
public enum HarborProxyImportMerger {
    private struct Endpoint: Hashable {
        var proto: String
        var host: String
        var port: Int
        var credential: String
        var network: String
        var security: String
        var path: String
        var headerHost: String
        var sni: String

        init(_ node: HarborProxyNode) {
            proto = node.protocolName
            host = node.host
            port = node.port
            credential = node.credential
            network = node.network
            security = node.security
            path = node.path
            headerHost = node.headerHost
            sni = node.sni
        }
    }

    public static func merge(
        currentNodes: [HarborProxyNode],
        currentSubscriptions: [HarborProxySubscription],
        selectedID: String?,
        imported: HarborV2rayNImport
    ) -> (nodes: [HarborProxyNode], subscriptions: [HarborProxySubscription], selectedID: String?) {
        let importedNodes = HarborProxyNodeNaming.preservingCustomNames(
            from: currentNodes, in: imported.nodes
        )
        let incomingIDs = Set(importedNodes.map(\.id))
        let incomingSubscriptions = Set(imported.subscriptions.map(\.id))
        let incomingEndpoints = Set(importedNodes.map(Endpoint.init))

        // Preserve manually added nodes, while replacing old nodes from every
        // imported subscription even if its provider regenerated profile IDs.
        let retained = currentNodes.filter { node in
            if incomingIDs.contains(node.id) { return false }
            if !node.subscriptionID.isEmpty &&
                incomingSubscriptions.contains(node.subscriptionID) { return false }
            if incomingEndpoints.contains(Endpoint(node)) { return false }
            return true
        }
        var seen = Set<String>()
        let nodes = (retained + importedNodes).filter { seen.insert($0.id).inserted }
        let subscriptions = currentSubscriptions.filter {
            !incomingSubscriptions.contains($0.id)
        } + imported.subscriptions
        let chosen: String?
        if let fromV2rayN = imported.selectedID, nodes.contains(where: { $0.id == fromV2rayN }) {
            chosen = fromV2rayN
        } else if let selectedID, nodes.contains(where: { $0.id == selectedID }) {
            chosen = selectedID
        } else {
            chosen = nodes.first?.id
        }
        return (nodes, subscriptions, chosen)
    }
}
