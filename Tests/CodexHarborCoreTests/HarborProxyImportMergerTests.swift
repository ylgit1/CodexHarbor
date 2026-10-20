import Foundation
import Testing
@testable import CodexHarborCore

@Suite("v2rayN repeatable migration")
struct HarborProxyImportMergerTests {
    private func node(id: String, group: String, host: String = "node.example.com") -> HarborProxyNode {
        HarborProxyNode(id: id, name: "节点", protocolName: "vless",
                        host: host, port: 443,
                        credential: "fixture-credential",
                        network: "ws", security: "tls",
                        subscriptionID: group)
    }

    @Test("Repeated imports do not duplicate profiles when subscription IDs remain stable")
    func repeatable() {
        let subscription = HarborProxySubscription(id: "groupA", name: "A", url: "https://example.com")
        let initial = HarborV2rayNImport(
            nodes: [node(id: "idA", group: "groupA")],
            subscriptions: [subscription], selectedID: "idA", unsupportedCount: 0
        )
        let first = HarborProxyImportMerger.merge(
            currentNodes: [], currentSubscriptions: [], selectedID: nil, imported: initial
        )
        let second = HarborProxyImportMerger.merge(
            currentNodes: first.nodes, currentSubscriptions: first.subscriptions,
            selectedID: first.selectedID, imported: initial
        )
        #expect(second.nodes.count == 1)
        #expect(second.subscriptions.count == 1)
        #expect(second.selectedID == "idA")
    }

    @Test("Reimport removes stale profiles when provider rotates profile IDs")
    func rotatedIDs() {
        let previous = node(id: "old", group: "groupA")
        let updated = node(id: "new", group: "groupA")
        let manual = node(id: "handmade", group: "", host: "mine.example.com")
        let imported = HarborV2rayNImport(
            nodes: [updated],
            subscriptions: [HarborProxySubscription(id: "groupA", name: "A", url: "https://example.com")],
            selectedID: "new", unsupportedCount: 0
        )
        let merged = HarborProxyImportMerger.merge(
            currentNodes: [previous, manual], currentSubscriptions: [],
            selectedID: "old", imported: imported
        )
        #expect(merged.nodes.count == 2)
        #expect(merged.nodes.contains(where: { $0.id == "new" }))
        #expect(merged.nodes.contains(where: { $0.id == "handmade" }))
        #expect(!merged.nodes.contains(where: { $0.id == "old" }))
        #expect(merged.selectedID == "new")
    }

    @Test("Equivalent legacy endpoints without source group are deduplicated")
    func legacyEndpoints() {
        let legacy = node(id: "legacy", group: "")
        let new = node(id: "new", group: "groupA")
        let merged = HarborProxyImportMerger.merge(
            currentNodes: [legacy], currentSubscriptions: [],
            selectedID: "legacy",
            imported: HarborV2rayNImport(nodes: [new], subscriptions: [], selectedID: "new",
                                         unsupportedCount: 0)
        )
        #expect(merged.nodes.count == 1)
        #expect(merged.selectedID == "new")
    }
}
