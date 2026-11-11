import Foundation

/// Repeatable v2rayN imports replace source subscription groups, not only
/// profile IDs. Many subscription providers recreate IndexId values on update.
public enum HarborProxyImportMerger {
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
        let incomingEndpoints = Set(importedNodes.map { HarborProxyNodeDeduplication.endpoint($0) })

        // Preserve manually added nodes, while replacing old nodes from every
        // imported subscription even if its provider regenerated profile IDs.
        let retained = currentNodes.filter { node in
            if incomingIDs.contains(node.id) { return false }
            if !node.subscriptionID.isEmpty &&
                incomingSubscriptions.contains(node.subscriptionID) { return false }
            if node.subscriptionID.isEmpty &&
                incomingEndpoints.contains(HarborProxyNodeDeduplication.endpoint(node)) { return false }
            return true
        }
        var seen = Set<String>()
        let uniqueIDs = (retained + importedNodes).filter { seen.insert($0.id).inserted }
        let nodes = HarborProxyNodeDeduplication.coalesce(
            uniqueIDs, withinSubscriptions: true
        ) { $0.id == imported.selectedID ? 1 : 0 }.nodes
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
