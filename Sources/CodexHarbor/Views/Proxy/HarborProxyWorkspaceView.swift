import SwiftUI
import AppKit
import Combine
import CodexHarborCore

private struct ServerAddress: Hashable, Sendable {
    let host: String
    let port: Int

    init(_ node: HarborProxyNode) {
        host = HarborIPAddress.normalizedLiteral(node.host) ?? node.host.lowercased()
        port = node.port
    }
}

/// Keep each connection configuration available within its server address.
private struct AddressGroup: Identifiable, Sendable {
    let id: ServerAddress
    var nodes: [HarborProxyNode]

    static func group(_ nodes: [HarborProxyNode]) -> [AddressGroup] {
        var groups: [AddressGroup] = []
        var indices: [ServerAddress: Int] = [:]
        for node in nodes {
            let address = ServerAddress(node)
            if let index = indices[address] {
                groups[index].nodes.append(node)
            } else {
                indices[address] = groups.count
                groups.append(AddressGroup(id: address, nodes: [node]))
            }
        }
        return groups
    }
}

/// Compact, high-fidelity macOS proxy workspace.
/// This view never starts background timers or probes unrelated nodes.
struct HarborProxyWorkspaceView: View {
    @ObservedObject var proxy: HarborProxyManager
    @State private var groupID: String?
    @State private var favoritesOnly = false
    @State private var favorites: Set<String> = []
    @State private var keyword = ""
    @State private var category: NodeCategory = .all
    @State private var region = "全部"
    @State private var protocolFilter = "全部"
    @State private var latencyFilter = "全部"
    @State private var showUnavailable = true
    @State private var batchScope: BatchScope = .filtered
    // The table keeps its last committed ordering while a batch is running.
    @State private var frozenLatencyResults: [String: HarborProxyProbeResult]?
    @State private var page = 1
    @State private var pageSize = 10
    @AppStorage("com.codexharbor.proxy.gridMode")
    private var gridMode = false
    @State private var editor: Editor?
    @State private var subscriptionName = ""
    @State private var subscriptionURL = ""
    @State private var editingSubscriptionID: String?
    @State private var subscriptionError: String?
    @State private var editorSaving = false
    @State private var nodeLinks = ""
    @State private var forcedDomainText = ""
    @State private var forcedDomainError: String?
    @State private var listenPortText = ""
    @State private var listenPortError: String?
    @State private var portUpdating = false
    @State private var copiedProxyURL: String?
    // Hover highlights are owned by individual cells, not the entire workspace.
    @State private var previewNodeID: String?
    @State private var deletionTargetID: DeletionTarget?
    @State private var deletionError: String?
    @State private var deletingSubscription = false
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @AppStorage("com.codexharbor.proxy.nodeNameColumnWidth")
    private var nodeNameColumnWidth = 230.0
    @State private var nodeNameDragStart: Double?
    @FocusState private var nodeSearchFocused: Bool

    // Heavy catalog work is consolidated into a single cached presentation.
    // While a latency or GeoIP batch publishes individual progress updates,
    // the scroll view keeps using the previous stable snapshot.
    @State private var catalog = CatalogPresentation.empty
    @State private var refreshScheduler = CatalogRefreshScheduler()

    @MainActor
    private final class CatalogRefreshScheduler {
        var task: Task<Void, Never>?
        var generation = UUID()
        var needsRefresh = false
    }

    private struct CatalogPresentation: Sendable {
        var filter: CatalogFilter?
        var filteredNodes: [HarborProxyNode] = []
        var sourceNodes: [HarborProxyNode] = []
        var sourceAddressCount = 0
        var categoryAddressCount = 0
        var shownGroups: [AddressGroup] = []
        var categoryByID: [String: NodeCategory] = [:]
        var categoryCounts: [NodeCategory: Int] = [:]
        var regionCounts: [String: Int] = [:]
        var subscriptionCounts: [String: Int] = [:]
        var subscriptionProfileCounts: [String: Int] = [:]
        var subscriptionUsableCounts: [String: Int] = [:]
        var allNodeCount = 0
        var favoriteCount = 0
        var unavailableCount = 0
        var protocols: [String] = ["全部"]
        var regions: [String] = ["全部"]

        static var empty: Self { Self() }
    }

    private struct DeletionTarget: Identifiable { let id: String }
    private struct RenameTarget: Identifiable { let id: String }

    private enum NodeCategory: String, CaseIterable, Sendable {
        case all = "全部"
        case residential = "住宅候选"
        case volunteer = "志愿节点"
        case datacenter = "机房候选"
        case custom = "自定义"
    }

    private enum Editor: String, Identifiable {
        case subscription, editSubscription, links, importChoice, routing, ports
        var id: String { rawValue }
    }

    private enum BatchScope: String, CaseIterable, Identifiable {
        case filtered = "筛选结果"
        case source = "当前列表（全部）"
        case selected = "选中的配置"
        var id: Self { self }
    }

    private let favoritesKey = HarborProxyManager.favoriteNodeIDsKey
    private let nodePortColumnWidth: CGFloat = 42
    private let profileMenuWidth: CGFloat = 56
    private let subscriptionTints: [Color] = [
        HarborColors.blue, HarborColors.green, HarborColors.orange, HarborColors.purple
    ]

    private var sourceGroupNodes: [HarborProxyNode] { catalog.sourceNodes }
    private var unavailableCount: Int { catalog.unavailableCount }
    private var protocols: [String] { catalog.protocols }
    private var regions: [String] { catalog.regions }

    private struct CatalogFilter: Equatable, Sendable {
        let groupID: String?
        let favoritesOnly: Bool
        let keyword: String
        let category: NodeCategory
        let region: String
        let protocolFilter: String
        let latencyFilter: String
        let showUnavailable: Bool
    }

    private struct CatalogInput: Sendable {
        let nodes: [HarborProxyNode]
        let results: [String: HarborProxyProbeResult]
        let subscriptions: [HarborProxySubscription]
        let evidence: [String: HarborProxyNetworkEvidence]
        let serverLocations: [String: HarborProxyIPLocation]
        let exits: [String: HarborProxyExitLocation]
        let unknownExits: Set<String>
        let favorites: Set<String>
        let scope: HarborProxyManager.MeasurementScope
        let filter: CatalogFilter
    }

    private var catalogFilter: CatalogFilter {
        CatalogFilter(groupID: groupID, favoritesOnly: favoritesOnly, keyword: keyword,
                      category: category, region: region, protocolFilter: protocolFilter,
                      latencyFilter: latencyFilter, showUnavailable: showUnavailable)
    }

    private var batchNodes: [HarborProxyNode] {
        guard let existing = catalog.filter, existing.groupID == groupID,
              existing.favoritesOnly == favoritesOnly else { return [] }
        switch batchScope {
        case .filtered: return existing == catalogFilter ? catalog.filteredNodes : []
        case .source: return sourceGroupNodes
        case .selected:
            guard let previewNodeID, let node = sourceGroupNodes.first(where: { $0.id == previewNodeID }) else {
                return []
            }
            return [node]
        }
    }

    private var availableCategories: [NodeCategory] {
        [.all] + NodeCategory.allCases.filter {
            $0 != .all && (catalog.categoryCounts[$0] ?? 0) > 0
        }
    }

    private func categoryOf(_ node: HarborProxyNode) -> NodeCategory {
        catalog.categoryByID[node.id] ?? .custom
    }

    private var displayedProbeResults: [String: HarborProxyProbeResult] {
        proxy.latencyTesting ? (frozenLatencyResults ?? proxy.probeResults) : proxy.probeResults
    }

    private var title: String {
        if let groupID { return proxy.subscriptions.first(where: { $0.id == groupID })?.name ?? "订阅节点" }
        return favoritesOnly ? "我的收藏" : "全部节点"
    }

    /// Deliberately coalesce noisy progress publications (hundreds of results
    /// in a batch) without delaying direct user actions such as filter changes.
    private func scheduleCatalogRefresh(debounce: Bool = true) {
        if debounce, refreshScheduler.task != nil {
            refreshScheduler.needsRefresh = true
            return
        }
        refreshScheduler.task?.cancel()
        let generation = UUID()
        refreshScheduler.generation = generation
        refreshScheduler.needsRefresh = false
        refreshScheduler.task = Task { @MainActor in
            defer {
                if refreshScheduler.generation == generation {
                    refreshScheduler.task = nil
                    if !Task.isCancelled && refreshScheduler.needsRefresh { scheduleCatalogRefresh() }
                }
            }
            if debounce {
                do { try await Task.sleep(for: .milliseconds(140)) } catch { return }
            }
            guard !Task.isCancelled else { return }
            refreshScheduler.needsRefresh = false
            let input = CatalogInput(nodes: proxy.nodes, results: displayedProbeResults,
                                     subscriptions: proxy.subscriptions, evidence: proxy.nodeNetworkEvidence,
                                     serverLocations: proxy.nodeServerLocations, exits: proxy.nodeExitLocations,
                                     unknownExits: proxy.exitGeoUnrecognizedIDs, favorites: favorites,
                                     scope: proxy.measurementScope, filter: catalogFilter)
            let worker = Task.detached(priority: .userInitiated) { Self.makeCatalog(input) }
            let result = await withTaskCancellationHandler { await worker.value } onCancel: { worker.cancel() }
            guard !Task.isCancelled, let result else { return }
            catalog = result
            if region != "全部", !result.regions.contains(region) { region = "全部" }
        }
    }

    private func rebuildCatalog() { scheduleCatalogRefresh(debounce: false) }

    nonisolated private static func makeCatalog(_ input: CatalogInput) -> CatalogPresentation? {
        let (nodes, results, favorites, scope) = (input.nodes, input.results, input.favorites, input.scope)
        let filter = input.filter
        let usable = Set(nodes.compactMap { node in
            results[node.id].map { $0.isUsable() && scope.accepts($0, for: node) } == true ? node.id : nil
        })
        let sources = Dictionary(input.subscriptions.map {
            ($0.id, HarborProxyCommunitySource.matching($0.url))
        }, uniquingKeysWith: { first, _ in first })
        let query = filter.keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        var snapshot = CatalogPresentation.empty
        snapshot.filter = filter

        // Coalesce identical connection configurations before grouping the
        // display by server address. Keep protocol variants available for probing.
        func priority(_ node: HarborProxyNode) -> Int {
            if node.id == scope.activeID { return 8 }
            if favorites.contains(node.id) { return 4 }
            if usable.contains(node.id) { return 2 }
            return node.customName == nil ? 0 : 1
        }
        let sourceNodes = HarborProxyNodeDeduplication.coalesce(
            nodes, withinSubscriptions: true, priority: priority
        ).nodes
        let allNodes = HarborProxyNodeDeduplication.coalesce(sourceNodes, priority: priority).nodes
        let favoriteNodes = HarborProxyNodeDeduplication.coalesce(
            nodes.filter { favorites.contains($0.id) }, priority: priority
        ).nodes
        func addressCount(_ nodes: [HarborProxyNode]) -> Int {
            Set(nodes.map(ServerAddress.init)).count
        }
        snapshot.allNodeCount = addressCount(allNodes)
        snapshot.favoriteCount = addressCount(favoriteNodes)
        for (id, members) in Dictionary(grouping: sourceNodes, by: \.subscriptionID) {
            snapshot.subscriptionCounts[id] = addressCount(members)
            snapshot.subscriptionProfileCounts[id] = members.count
            snapshot.subscriptionUsableCounts[id] = addressCount(
                members.filter { usable.contains($0.id) }
            )
        }
        let visibleSource: [HarborProxyNode]
        if let groupID = filter.groupID {
            visibleSource = sourceNodes.filter { $0.subscriptionID == groupID }
        } else {
            visibleSource = filter.favoritesOnly ? favoriteNodes : allNodes
        }
        snapshot.sourceNodes = visibleSource
        snapshot.sourceAddressCount = addressCount(visibleSource)
        var categoryAddresses: [NodeCategory: Set<ServerAddress>] = [:]
        var unavailable = Set<String>()
        var availableNodes: [HarborProxyNode] = []
        for node in visibleSource {
            let kind: NodeCategory
            switch sources[node.subscriptionID] ?? nil {
            case .vpnGate:
                if node.security == "vpngate-datacenter" {
                    kind = .datacenter
                } else {
                    switch input.evidence[node.host].flatMap({ $0.isFresh() ? $0.kind : nil }) {
                    case .residential: kind = .residential
                    case .hosting: kind = .datacenter
                    default: kind = .volunteer
                    }
                }
            case .none: kind = .custom
            default: kind = .residential
            }
            snapshot.categoryByID[node.id] = kind
            categoryAddresses[kind, default: []].insert(ServerAddress(node))
            if results[node.id].map({ $0.isConfirmedUnavailable && scope.accepts($0, for: node) }) == true {
                unavailable.insert(node.id)
                snapshot.unavailableCount += 1
                if !filter.showUnavailable { continue }
            }
            availableNodes.append(node)
        }
        snapshot.categoryCounts = categoryAddresses.mapValues(\.count)
        snapshot.protocols = ["全部"] +
            Array(Set(availableNodes.map { $0.protocolName.uppercased() })).sorted()
        let categoryIndex = snapshot.categoryByID
        let categoryNodes = availableNodes.filter {
            filter.category == .all || categoryIndex[$0.id] == filter.category
        }
        snapshot.categoryAddressCount = addressCount(categoryNodes)

        // Resolve displayed region once per node. Keep the same verified-exit
        // preference as HarborProxyManager.exitLocation(for:).
        var nodeRegions: [String: String] = [:]
        var regionAddresses: [String: Set<ServerAddress>] = [:]
        for node in categoryNodes {
            guard !Task.isCancelled else { return nil }
            let server = input.serverLocations[node.host.lowercased()]
            let exit = scope.verifiedExit(input.exits[node.id], for: node, resolvedIP: server?.ip)
            let location: String
            if let exit {
                location = exit.displayRegion
            } else if input.unknownExits.contains(node.id) {
                location = HarborVPNGate.publisherLocation(for: node)?.displayRegion ?? "未识别"
            } else if node.protocolName == "openvpn" {
                location = exit?.displayRegion
                    ?? HarborVPNGate.publisherLocation(for: node)?.displayRegion
                    ?? HarborProxyAutomaticName.unresolvedRegion
            } else if snapshot.categoryByID[node.id] == .residential {
                location = exit?.displayRegion ?? HarborProxyAutomaticName.unresolvedRegion
            } else {
                location = (exit ?? server)?.displayRegion ?? HarborProxyAutomaticName.unresolvedRegion
            }
            nodeRegions[node.id] = location
            regionAddresses[location, default: []].insert(ServerAddress(node))
        }
        snapshot.regionCounts = regionAddresses.mapValues(\.count)
        let priority = ["香港", "美国", "日本", "新加坡", "台湾", "德国", "韩国", "英国"]
        let names = Set(snapshot.regionCounts.keys)
        snapshot.regions = ["全部"] + priority.filter(names.contains)
            + names.subtracting(Set(priority)).sorted()

        let candidates = categoryNodes.filter { node in
            if filter.region != "全部" && nodeRegions[node.id] != filter.region { return false }
            if filter.protocolFilter != "全部" && node.protocolName.uppercased() != filter.protocolFilter { return false }
            if filter.latencyFilter != "全部" {
                guard usable.contains(node.id), let delay = results[node.id]?.milliseconds else { return false }
                if filter.latencyFilter == "快速" &&
                    delay >= HarborProxyLatencyPolicy.goodUpperBoundMilliseconds { return false }
                if filter.latencyFilter == "一般" &&
                    (delay < HarborProxyLatencyPolicy.goodUpperBoundMilliseconds ||
                     delay >= HarborProxyLatencyPolicy.warningUpperBoundMilliseconds) { return false }
                if filter.latencyFilter == "较慢" &&
                    delay < HarborProxyLatencyPolicy.warningUpperBoundMilliseconds { return false }
            }
            return query.isEmpty ||
                node.displayName.localizedCaseInsensitiveContains(query) ||
                node.name.localizedCaseInsensitiveContains(query) ||
                node.host.localizedCaseInsensitiveContains(query) ||
                Int(query) == node.port ||
                node.protocolName.localizedCaseInsensitiveContains(query)
        }
        snapshot.filteredNodes = candidates
        snapshot.shownGroups = AddressGroup.group(
            HarborProxySubscriptionRefreshPolicy.initialLatencyOrder(candidates, results: results.filter {
                usable.contains($0.key) || ($0.value.isConfirmedUnavailable && unavailable.contains($0.key))
            })
        )
        return snapshot
    }

    private var missingCommunitySources: [HarborProxyCommunitySource] {
        HarborProxyCommunitySource.offered.filter { source in
            !proxy.subscriptions.contains { HarborProxyCommunitySource.matching($0.url) == source }
        }
    }

    var body: some View {
        let layout = GeometryReader { geometry in
            workspaceLayout(size: geometry.size)
        }
        return presentSheets(observeRuntimeChanges(observeFilterChanges(observeCatalogChanges(layout))))
    }

    private func observeCatalogChanges<Content: View>(_ content: Content) -> some View {
        content
        .task {
            await proxy.bootstrap()
            await proxy.refreshCommunitySourcesIfNeeded()
        }
        .onAppear {
            favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
            rebuildCatalog()
        }
        .onDisappear { refreshScheduler.task?.cancel() }
        .onReceive(proxy.$nodes) { _ in
            favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
            scheduleCatalogRefresh()
        }
        .onReceive(proxy.$activeNodeID) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$healthy) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$probeNetworkChangedAt) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$subscriptions) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$probeResults) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$nodeServerLocations) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$nodeExitLocations) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$exitGeoUnrecognizedIDs) { _ in scheduleCatalogRefresh() }
        .onReceive(proxy.$nodeNetworkEvidence) { _ in scheduleCatalogRefresh() }
    }

    private func observeFilterChanges<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: groupID) { _, _ in rebuildCatalog() }
        .onChange(of: favoritesOnly) { _, _ in rebuildCatalog() }
        .onChange(of: favorites) { _, _ in rebuildCatalog() }
        .onChange(of: showUnavailable) { _, _ in rebuildCatalog() }
        .onChange(of: proxy.subscriptions.map(\.id)) { _, ids in
            if let groupID, !ids.contains(groupID) {
                self.groupID = nil
                favoritesOnly = false
                resetFilters()
            }
        }
        .onChange(of: keyword) { _, _ in
            page = 1
            // User input remains immediate. Only asynchronous probe/GeoIP
            // updates are coalesced in the background.
            rebuildCatalog()
        }
        .onChange(of: category) { _, _ in
            page = 1
            rebuildCatalog()
        }
        .onChange(of: availableCategories) { _, choices in
            if !choices.contains(category) { category = .all }
        }
        .onChange(of: region) { _, _ in
            page = 1
            rebuildCatalog()
        }
        .onChange(of: protocolFilter) { _, _ in
            page = 1
            rebuildCatalog()
        }
        .onChange(of: latencyFilter) { _, _ in
            page = 1
            rebuildCatalog()
        }
    }

    private func observeRuntimeChanges<Content: View>(_ content: Content) -> some View {
        content
        .onChange(of: proxy.latencyTesting) { _, testing in
            if testing {
                frozenLatencyResults = proxy.probeResults
            } else {
                frozenLatencyResults = nil
                page = 1
            }
            rebuildCatalog()
        }
        .onChange(of: pageSize) { _, _ in page = 1 }
        .onChange(of: proxy.localPort) { _, _ in copiedProxyURL = nil }
        .onChange(of: proxy.nodeServerLocations) { _, _ in
            if region != "全部" && !regions.contains(region) { region = "全部" }
        }
        .onChange(of: proxy.nodeExitLocations) { _, _ in
            if region != "全部" && !regions.contains(region) { region = "全部" }
        }
    }

    private func presentSheets<Content: View>(_ content: Content) -> some View {
        content
        .sheet(item: $editor) { mode in editorSheet(mode) }
        .sheet(item: $renameTarget) { target in
            if let node = proxy.nodes.first(where: { $0.id == target.id }) {
                HarborRenameDialog(
                    title: "重命名节点",
                    subtitle: "只修改 Harbor 中的显示名称，更新订阅后仍会保留。",
                    text: $renameText,
                    onCancel: { renameTarget = nil },
                    onSave: {
                        if proxy.renameNode(node.id, to: renameText) {
                            renameTarget = nil
                        }
                    }
                )
                .onChange(of: renameText) { _, value in
                    if value.count > HarborProxyNodeNaming.maximumLength {
                        renameText = String(value.prefix(HarborProxyNodeNaming.maximumLength))
                    }
                }
            }
        }
        .sheet(item: $deletionTargetID) { target in
            let id = target.id
            if let subscription = proxy.subscriptions.first(where: { $0.id == id }) {
                let count = proxy.nodes.filter { $0.subscriptionID == id }.count
                let inUse = proxy.nodes.contains { $0.subscriptionID == id && proxy.isInUse($0.id) }
                HarborDestructiveConfirmDialog(
                    title: "删除订阅「\(subscription.name)」？",
                    message: deletionError ?? (inUse
                        ? "将先恢复原系统代理设置并停止当前连接，再从 Codex Harbor 中移除该订阅及其 \(count) 个节点。v2rayN 中的原始配置不会删除。"
                        : "将从 Codex Harbor 中移除该订阅及其 \(count) 个节点。v2rayN 中的原始配置不会删除。"),
                    confirmTitle: deletingSubscription ? "正在删除…" : (inUse ? "清理代理并删除" : "删除订阅"),
                    isWorking: deletingSubscription,
                    onCancel: { deletionTargetID = nil },
                    onConfirm: {
                        deletingSubscription = true
                        Task {
                            if inUse {
                                await proxy.clearProxy(interactive: true)
                                if proxy.running || proxy.requiresRecovery {
                                    deletionError = proxy.detail
                                    deletingSubscription = false
                                    return
                                }
                            }
                            if proxy.removeSubscription(id) {
                                deletionTargetID = nil
                            } else {
                                deletionError = proxy.detail
                            }
                            deletingSubscription = false
                        }
                    }
                )
            }
        }
    }

    private func workspaceLayout(size: CGSize) -> some View {
        let outerInset: CGFloat = size.width < 850 ? 16 : 22
        let contentWidth = max(0, size.width - outerInset * 2)
        let sidebarWidth = min(300, max(220, contentWidth * 0.22))
        let tableWidth = max(0, contentWidth - sidebarWidth - 11)
        let compact = HarborProxyTableSizing.usesCompactRows(workspaceWidth: Double(tableWidth))
        return VStack(alignment: .leading, spacing: 9) {
            header.frame(width: contentWidth, height: 42)
            currentNode.frame(width: contentWidth, height: 68)
            configurationNotice
            HStack(alignment: .top, spacing: 11) {
                subscriptionSidebar.frame(width: sidebarWidth)
                nodeTable(compact: compact, showRegion: tableWidth >= 600,
                          narrow: tableWidth < 940, compactActions: tableWidth < 600)
                    .frame(width: tableWidth)
                    .frame(maxHeight: .infinity)
            }
            .frame(width: contentWidth, alignment: .leading)
            .frame(minHeight: 0, maxHeight: .infinity)
            .layoutPriority(1)
            .disabled(!proxy.configurationLoaded)
        }
        .frame(width: contentWidth, height: max(0, size.height - 13), alignment: .topLeading)
        .padding(.horizontal, outerInset)
        .padding(.top, 3)
        .padding(.bottom, 10)
    }

    @ViewBuilder private var configurationNotice: some View {
        if let message = proxy.configurationLoadError ?? proxy.configurationSaveError {
            HStack(spacing: 10) {
                Label(message, systemImage: "exclamationmark.circle")
                    .font(.system(size: 11))
                    .foregroundStyle(HarborColors.orange)
                Spacer(minLength: 8)
                Button(proxy.configurationLoaded ? "重试保存" : "重试读取") {
                    if proxy.configurationLoaded { proxy.retryConfigurationSave() }
                    else { Task { await proxy.retryConfigurationLoad() } }
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.orange, prominence: .secondary))
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
        }
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("网络代理")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text("内置 WARP 无订阅连接，也可管理现有节点")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HStack(spacing: 9) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                TextField("搜索节点名称、地区或备注", text: $keyword)
                    .focused($nodeSearchFocused)
                    .textFieldStyle(.plain)
                    .font(.system(size: 11.5))
                    .accessibilityLabel("搜索节点")
                if !keyword.isEmpty {
                    Button {
                        keyword = ""
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .font(.system(size: 12))
            .padding(.horizontal, 12)
            .frame(width: 220, height: 32)
            .background(Color.primary.opacity(0.025),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(HarborColors.cardBorder))
        }
    }

    /// A completed, healthy activation should not keep showing "switching"
    /// while an overlapping duplicate click is still finishing its queue.
    private var visibleSwitchingNodeID: String? {
        guard let id = proxy.switchingNodeID else { return nil }
        return proxy.running && proxy.healthy && proxy.activeNodeID == id ? nil : id
    }

    /// The header represents what is *actually* active, not a saved selection.
    /// A configured-but-idle node must never be labeled as an active proxy.
    private var proxyStateColor: Color {
        if proxy.requiresRecovery { return HarborColors.red }
        if visibleSwitchingNodeID != nil { return HarborColors.orange }
        if proxy.running && !proxy.healthy { return HarborColors.orange }
        if proxy.running && proxy.activeNodeID != nil && proxy.systemManaged { return HarborColors.green }
        if proxy.running { return HarborColors.blue }
        if proxy.busy { return HarborColors.orange }
        return .secondary
    }

    private var headerNode: HarborProxyNode? {
        if proxy.running { return proxy.activeNode }
        if let id = visibleSwitchingNodeID { return proxy.nodes.first { $0.id == id } }
        return proxy.selectedNode
    }

    private var proxyNodeTitle: String {
        headerNode?.displayName ?? (proxy.running ? "实际运行节点未识别" : "未选择代理节点")
    }

    private var proxyConnectionType: HarborProxyConnectionType? {
        guard let node = headerNode else { return nil }
        return HarborProxyConnectionType.classify(
            node: node,
            subscription: proxy.subscriptions.first { $0.id == node.subscriptionID },
            evidence: proxy.networkEvidence(for: node)
        )
    }

    private var proxyConnectionStatus: String {
        if proxy.requiresRecovery { return "请先恢复系统代理设置，避免网络异常" }
        if !proxy.configurationLoaded {
            return proxy.configurationLoadError == nil ? "正在读取代理配置…" : "代理配置暂不可读取"
        }
        if proxy.connectionPhase == .offline { return "网络离线 · 暂停恢复" }
        if proxy.connectionPhase == .recovering { return "正在恢复当前节点" }
        if proxy.connectionPhase == .stopping { return "正在停止并回收代理资源" }
        if proxy.connectionPhase == .failed && proxy.running { return proxy.status }
        if let id = visibleSwitchingNodeID {
            let requested = proxy.nodes.first { $0.id == id }?.displayName ?? "新节点"
            return "正在验证：\(requested)"
        }
        if proxy.running && proxy.checkingConnectivity {
            return "正在连接 · 本地端口已就绪，检测真实网络中"
        }
        if proxy.running && proxy.activeNodeID == HarborIndependentWARP.nodeID,
           !proxy.healthy {
            return "WARP 出口验证未通过 · " + proxy.detail
        }
        if proxy.running && !proxy.healthy { return "连接异常 · 真实网络检测未通过" }
        if proxy.running && proxy.activeNodeID != nil && proxy.systemManaged {
            return "已连接 · macOS 系统代理已接管"
        }
        if proxy.running {
            if proxy.detail.hasPrefix("本地节点已连接，但系统代理未接管") {
                return proxy.detail
            }
            return "已连接 · 尚未接管 macOS 系统代理"
        }
        if proxy.busy { return "正在处理代理配置…" }
        return headerNode == nil ? "未连接 · 请先添加或选择节点" : "未连接 · 点击下方节点开始使用"
    }

    private var proxyLatencyText: String? {
        if visibleSwitchingNodeID != nil { return "切换中" }
        if proxy.running && proxy.checkingConnectivity { return "检测中" }
        guard let node = headerNode,
              let result = proxy.probeResults[node.id],
              let latency = result.milliseconds else {
            return headerNode == nil ? nil : "未测速"
        }
        let prefix = proxy.running && proxy.activeNodeID == node.id ? "" : "上次 "
        return prefix + HarborProxyMeasurementLabel.measured(latency)
            + (!proxy.isUsable(result, for: node) ? " · 待复测" : "")
    }

    private var proxyLatencyColor: Color {
        if visibleSwitchingNodeID != nil || (proxy.running && proxy.checkingConnectivity) {
            return HarborColors.orange
        }
        guard let node = headerNode,
              let latency = proxy.probeResults[node.id]?.milliseconds else { return .secondary }
        return latencyColor(latency)
    }

    private func exitEvidenceLabel(_ evidence: HarborProxyNetworkEvidence) -> String {
        let kind: String
        switch evidence.kind {
        case .residential: kind = "住宅候选"
        case .cellular: kind = "移动网络候选"
        case .hosting: kind = "机房候选"
        case .other, .unknown: kind = "未知"
        }
        let confidence = evidence.confidence == .corroborated ? "多源一致"
            : evidence.confidence == .conflicting ? "证据冲突"
            : evidence.confidence == .singleSource ? "单源" : "待验证"
        return "出口类型 \(kind) · \(confidence)"
    }

    private var currentNode: some View {
        HStack(spacing: 14) {
            Image(systemName: proxy.running ? "network" : "network.slash")
                .font(.system(size: 18, weight: .medium))
                .foregroundStyle(proxyStateColor)
                .frame(width: 37, height: 37)
                .background(proxyStateColor.opacity(0.09),
                            in: RoundedRectangle(cornerRadius: 11, style: .continuous))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(proxyNodeTitle)
                        .font(.system(size: 14.5, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if let latencyText = proxyLatencyText {
                        Text(latencyText)
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(proxyLatencyColor)
                            .padding(.horizontal, 8)
                            .frame(height: 21)
                            .background(proxyLatencyColor.opacity(0.09), in: Capsule())
                    }
                }
                HStack(spacing: 6) {
                    if let connectionType = proxyConnectionType {
                        Text("连接类型：\(connectionType.title)")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(HarborColors.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(HarborColors.blue.opacity(0.08), in: Capsule())
                            .fixedSize(horizontal: true, vertical: false)
                            .help(connectionType.detail)
                            .accessibilityLabel("连接类型：\(connectionType.title)")
                    }
                    Circle().fill(proxyStateColor).frame(width: 6, height: 6)
                    Text(proxyConnectionStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    if proxy.activeNodeID == HarborIndependentWARP.nodeID,
                       let exitIP = proxy.warpExitIP, proxy.healthy {
                        Text("出口 \(exitIP)")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(HarborColors.green)
                    }
                }
                if proxy.running, let node = proxy.activeNode {
                    HStack(spacing: 8) {
                        if let entry = proxy.entranceLocation(for: node)?.ip {
                            Text("入口 \(entry)")
                        }
                        if let exit = proxy.currentVerifiedExitIP {
                            Text("出口 \(exit)")
                        } else if proxy.healthy {
                            Text("出口 IP 待识别")
                        }
                        if let evidence = proxy.exitNetworkEvidence(for: node) {
                            Text(exitEvidenceLabel(evidence))
                                .help("证据来源：\(evidence.sources?.joined(separator: ", ") ?? "历史记录")")
                        } else if proxy.healthy {
                            Text("出口类型待识别")
                        }
                        if let checkedAt = proxy.lastSuccessfulHealthCheckAt {
                            Text("最近成功 \(checkedAt, style: .time)")
                        }
                    }
                    .font(.system(size: 9.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            VStack(alignment: .trailing, spacing: 3) {
                if proxy.running, let port = proxy.localPort {
                    proxyAddressRow(label: "HTTP", port: port,
                                    url: "http://127.0.0.1:\(port)")
                    proxyAddressRow(label: "SOCKS5", port: port + 1,
                                    url: "socks5://127.0.0.1:\(port + 1)")
                } else {
                    Text(verbatim: "预设 HTTP \(String(proxy.configuredHTTPPort)) · SOCKS5 \(String(proxy.configuredHTTPPort + 1))")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Button {
                listenPortText = String(proxy.configuredHTTPPort)
                listenPortError = nil
                editor = .ports
            } label: {
                Image(systemName: "gearshape")
                    .font(.system(size: 12.5))
                    .frame(width: 29, height: 30)
            }
            .disabled(!proxy.configurationLoaded || proxy.busy || portUpdating)
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 7))
            .help("设置固定代理监听端口，默认 HTTP 18080 / SOCKS5 18081")
            if proxy.running && proxy.healthy && !proxy.systemManaged {
                Button {
                    Task { await proxy.enableSystemProxy(interactive: true) }
                } label: {
                    Label("接管系统代理", systemImage: "network.badge.shield.half.filled")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.green, prominence: .secondary))
                .disabled(proxy.busy)
                .help("将已验证的当前节点设置为 macOS HTTP、HTTPS 与 SOCKS5 系统代理")
            }
            if !proxy.running && !proxy.requiresRecovery &&
               visibleSwitchingNodeID == nil && proxy.configurationLoaded {
                Button {
                    Task { await proxy.activate(HarborIndependentWARP.nodeID) }
                } label: {
                    Label("WARP 一键连接", systemImage: "bolt.horizontal.circle")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.green, prominence: .secondary))
                .disabled(proxy.busy || !proxy.mihomoInstalled)
                .help("无需订阅节点；注册并验证 WARP 真实出口及外部 HTTPS 后才接管系统代理")
            }
            if proxy.running || proxy.requiresRecovery || visibleSwitchingNodeID != nil {
                Button {
                    Task { await proxy.clearProxy(interactive: true) }
                } label: {
                    Label(visibleSwitchingNodeID != nil ? "停止切换" : "清理代理", systemImage: "stop.circle")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                .help("取消正在进行的切换，恢复 Harbor 接管前的系统代理设置，并停止 Harbor 的连接")
            } else {
                Button {
                    if proxy.subscriptions.isEmpty && proxy.nodes.isEmpty {
                        editor = .subscription
                    } else {
                        if groupID == nil && favorites.isEmpty {
                            groupID = proxy.subscriptions.first?.id
                            favoritesOnly = groupID == nil
                        }
                        resetFilters()
                        nodeSearchFocused = true
                    }
                } label: {
                    Label("配置代理", systemImage: "arrow.right.circle")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                .disabled(!proxy.configurationLoaded)
                .help("前往下方节点列表，点击节点行建立连接")
            }
        }
        .padding(.horizontal, 18)
        .frame(height: 66)
        .background(HarborColors.cardBackground,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HarborColors.cardBorder))
    }

    private func proxyAddressRow(label: String, port: Int, url: String) -> some View {
        HStack(spacing: 5) {
            Text(verbatim: "\(label) 127.0.0.1:\(String(port))")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button {
                let pasteboard = NSPasteboard.general
                pasteboard.clearContents()
                pasteboard.setString(url, forType: .string)
                copiedProxyURL = url
            } label: {
                Image(systemName: copiedProxyURL == url ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5))
                    .foregroundStyle(copiedProxyURL == url ? HarborColors.green : HarborColors.blue)
                    .frame(width: 23, height: 21)
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 5))
            .help(copiedProxyURL == url ? "已复制 \(url)" : "复制 \(url)")
            .accessibilityLabel("复制 \(label) 代理地址")
        }
    }

    private var subscriptionSidebar: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Text("订阅")
                    .font(.system(size: 13, weight: .semibold))
                Text("\(proxy.subscriptions.count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)

            if !missingCommunitySources.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    Text("公开候选来源 · 非纯净度保证")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                    ForEach(missingCommunitySources, id: \.self) { source in
                        Button {
                            addCommunitySource(source)
                        } label: {
                            Label("添加 VPN Gate 候选", systemImage: "network")
                                .font(.system(size: 11, weight: .medium))
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .frame(height: 29)
                        }
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue,
                                                             prominence: .secondary))
                        .disabled(proxy.busy || proxy.latencyTesting)
                        .help("添加公开候选来源；不会自动连接或更改系统代理")
                    }
                }
                .padding(.horizontal, 15)
            }

            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 7) {
                Button {
                    editor = .importChoice
                } label: {
                    subscriptionActionLabel("新增", icon: "plus", tint: HarborColors.blue)
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
                .help("新增订阅或节点")
                .accessibilityLabel("新增订阅或节点链接")
                Button {
                    if let groupID,
                       let item = proxy.subscriptions.first(where: { $0.id == groupID }) {
                        beginEditingSubscription(item)
                    }
                } label: {
                    subscriptionActionLabel("编辑", icon: "pencil", tint: HarborColors.blue)
                }
                .disabled(groupID == nil || proxy.busy || proxy.latencyTesting)
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
                .help(groupID == nil ? "先在左侧选择要编辑的订阅"
                      : (proxy.busy || proxy.latencyTesting
                         ? "请等待当前代理操作完成" : "编辑选中订阅的名称与链接"))
                .accessibilityLabel("编辑当前订阅")
                Button {
                    if let groupID {
                        Task { await proxy.refreshCommunitySubscription(groupID) }
                    }
                } label: {
                    subscriptionActionLabel("更新", icon: "arrow.clockwise", tint: HarborColors.blue)
                }
                .disabled(groupID == nil || proxy.busy || proxy.latencyTesting)
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
                .help(groupID == nil ? "请先选择需要更新的订阅"
                      : (proxy.busy || proxy.latencyTesting
                         ? "请等待当前代理操作完成" : "更新选中订阅的节点"))
                .accessibilityLabel("刷新当前订阅")
                Button {
                    if let groupID { requestSubscriptionDeletion(groupID) }
                } label: {
                    subscriptionActionLabel("删除", icon: "trash", tint: HarborColors.red)
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.red, cornerRadius: 8))
                .disabled(groupID == nil || proxy.busy || proxy.latencyTesting)
                .help(groupID == nil ? "先选择需要删除的订阅" : "删除当前选中的订阅")
                .accessibilityLabel("删除当前订阅")
            }
            .padding(.horizontal, 15)
            .padding(.bottom, 5)

            groupButton("全部节点", icon: "square.stack.3d.up", count: catalog.allNodeCount,
                        selected: groupID == nil && !favoritesOnly) {
                groupID = nil
                favoritesOnly = false
                resetFilters()
            }
            groupButton("我的收藏", icon: "star", count: catalog.favoriteCount,
                        selected: groupID == nil && favoritesOnly) {
                groupID = nil
                favoritesOnly = true
                resetFilters()
            }
            Rectangle()
                .fill(HarborColors.cardBorder)
                .frame(height: 1)
                .padding(.horizontal, 15)
                .padding(.vertical, 3)

            ScrollView(.vertical) {
                LazyVStack(spacing: 5) {
                    ForEach(Array(proxy.subscriptions.enumerated()), id: \.element.id) { index, item in
                        subscriptionRow(item, index: index)
                    }
                }
                .padding(.horizontal, 9)
            }
            .scrollIndicators(.never)
            .frame(minHeight: 0, maxHeight: .infinity)

            if proxy.configurationLoaded && (!proxy.coreInstalled || !proxy.mihomoInstalled) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(proxy.installingCore ? "正在恢复内核…" : "代理内核尚未全部就绪")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await proxy.installBundledXray() }
                    } label: {
                        Label(proxy.installingCore ? "恢复中…" : "从安装包修复内核",
                              systemImage: "shippingbox")
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(proxy.busy || proxy.installingCore || proxy.requiresRecovery || proxy.running)
                    Text(proxy.detail.isEmpty ? "无需网络，也不需要预先安装 v2rayN" : proxy.detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 13)
                .padding(.vertical, 9)
                .overlay(alignment: .top) {
                    Rectangle().fill(HarborColors.cardBorder).frame(height: 1)
                }
            }
            HStack(spacing: 4) {
                Text("代理路由")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Picker("代理路由", selection: Binding(get: { proxy.routingRules }, set: { value in
                    guard proxy.routingRules != value else { return }
                    proxy.routingRules = value
                    Task { await proxy.reapplyRouting() }
                })) {
                    Text("规则").tag(true)
                    Text("全局").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 83)
                .disabled(proxy.busy || proxy.requiresRecovery)
                .help("规则模式默认直连国内和局域网；全局模式默认代理外部网络。切换时会验证新规则。")
                Button {
                    forcedDomainText = proxy.forcedProxyDomains.joined(separator: "\n")
                    forcedDomainError = nil
                    editor = .routing
                } label: {
                    Image(systemName: "slider.horizontal.3")
                        .font(.system(size: 12))
                        .frame(width: 27, height: 28)
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 7))
                .help("配置强制代理站点（默认 Gitee），可添加不允许直连的域名")
                .accessibilityLabel("编辑强制代理站点")
            }
            .padding(.horizontal, 13)
            .padding(.vertical, 10)
            .overlay(alignment: .top) {
                Rectangle().fill(HarborColors.cardBorder).frame(height: 1)
            }
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background(HarborColors.cardBackground,
                    in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14).stroke(HarborColors.cardBorder))
    }

    private func subscriptionActionLabel(_ title: String, icon: String, tint: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .frame(height: 32)
            .background(tint.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).stroke(tint.opacity(0.17)))
    }

    private func groupButton(_ name: String, icon: String, count: Int,
                             selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 12))
                    .frame(width: 22)
                Text(name)
                    .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(selected ? HarborColors.blue : Color.secondary)
                    .padding(.horizontal, 6)
                    .frame(minHeight: 19)
                    .background(selected ? HarborColors.blue.opacity(0.09) : Color.primary.opacity(0.035),
                                in: Capsule())
            }
            .foregroundStyle(selected ? HarborColors.blue : Color.primary.opacity(0.83))
            .padding(.horizontal, 11)
            .frame(height: 44)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(selected ? HarborColors.blue.opacity(0.095) : .clear,
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(HarborColors.blue)
                        .frame(width: 2, height: 27)
                }
            }
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 9))
        .padding(.horizontal, 9)
    }

    private func subscriptionRow(_ item: HarborProxySubscription, index: Int) -> some View {
        let selected = groupID == item.id
        let tint = subscriptionTints[index % subscriptionTints.count]
        let count = catalog.subscriptionCounts[item.id, default: 0]
        let profiles = catalog.subscriptionProfileCounts[item.id, default: 0]
        let usable = catalog.subscriptionUsableCounts[item.id, default: 0]

        // One full-width clickable surface. The count belongs inside the
        // Button's hit area, so hover, selection and press never stop halfway.
        return Button {
            groupID = item.id
            favoritesOnly = false
            resetFilters()
        } label: {
            HStack(spacing: 10) {
                Image(systemName: ["doc.text", "airplane", "shippingbox", "square.stack.3d.up"][index % 4])
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(selected ? .white : tint)
                    .frame(width: 34, height: 34)
                    .background(selected ? tint : tint.opacity(0.10),
                                in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.name)
                        .font(.system(size: 11.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if HarborProxyCommunitySource.matching(item.url) != nil {
                        Text("\(count) 候选地址 · \(usable) 可用")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(count) 地址 · \(profiles) 配置")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text("\(count)")
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .foregroundStyle(selected ? HarborColors.blue : Color.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 22, alignment: .trailing)
            }
            .help("\(count) 个地址，\(profiles) 个配置，\(usable) 个地址近期测速通过" +
                  (proxy.subscriptionUpdatedAt[item.id].map {
                      "；上次更新：" + $0.formatted(date: .abbreviated, time: .shortened)
                  } ?? ""))
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 61)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .modifier(HarborStableHoverBackground(
                baseColor: selected ? HarborColors.blue.opacity(0.085) : .clear,
                highlightedColor: selected ? HarborColors.blue.opacity(0.085)
                    : HarborColors.blue.opacity(0.055),
                cornerRadius: 9
            ))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(HarborColors.blue)
                        .frame(width: 2, height: 41)
                }
            }
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("编辑订阅") { beginEditingSubscription(item) }
                .disabled(proxy.busy || proxy.latencyTesting)
            Button("更新订阅") { Task { await proxy.refreshCommunitySubscription(item.id) } }
                .disabled(proxy.busy || proxy.latencyTesting)
            Button("删除订阅", role: .destructive) {
                requestSubscriptionDeletion(item.id)
            }
        }
    }

    private var categoryBar: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 5) {
                ForEach(availableCategories, id: \.self) { choice in
                    let count = choice == .all ? catalog.sourceAddressCount
                        : catalog.categoryCounts[choice, default: 0]
                    Button {
                        category = choice
                    } label: {
                        Text("\(choice.rawValue) \(count)")
                            .font(.system(size: 10.5, weight: category == choice ? .semibold : .medium))
                            .foregroundStyle(category == choice ? HarborColors.blue : Color.secondary)
                            .padding(.horizontal, 9)
                            .frame(height: 26)
                            .background(category == choice ? HarborColors.blue.opacity(0.10) : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue,
                                                                    cornerRadius: 7))
                    .accessibilityAddTraits(category == choice ? .isSelected : [])
                    .help(choice == .residential
                          ? "上游住宅标签或公开网络数据标记的家宽入口候选；并非纯净出口保证，真实测速通过后才算可用"
                          : (choice == .volunteer
                             ? "VPN Gate 志愿节点，未确认家宽入口，不冒充纯净住宅 IP"
                             : "按来源与已知特征分类，不代表对出口网络的担保"))
                }
            }
            .padding(.horizontal, 10)
        }
        .scrollIndicators(.never)
        .frame(height: 34)
    }

    @ViewBuilder
    private func regionBar(narrow: Bool, compactActions: Bool) -> some View {
        if narrow {
            VStack(spacing: 0) {
                regionFilters.frame(height: 38)
                regionActions(narrow: true, compact: compactActions)
                    .frame(height: 40)
            }
        } else {
            HStack(spacing: 7) {
                regionFilters
                regionActions(narrow: false, compact: false)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .frame(height: 40)
        }
    }

    private var regionFilters: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 2) {
                ForEach(regions, id: \.self) { name in
                    let selected = region == name
                    let count = name == "全部"
                        ? catalog.categoryAddressCount
                        : catalog.regionCounts[name, default: 0]
                    Button { region = name } label: {
                        HStack(spacing: 5) {
                            if name != "全部" {
                                Text(regionEmoji(name)).font(.system(size: 12))
                            }
                            Text(name)
                            Text("\(count)")
                                .font(.system(size: 9, weight: .medium, design: .rounded))
                                .padding(.horizontal, 5)
                                .frame(height: 17)
                                .background(selected ? HarborColors.blue.opacity(0.10)
                                                   : Color.primary.opacity(0.035), in: Capsule())
                        }
                        .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
                        .foregroundStyle(selected ? HarborColors.blue : Color.secondary)
                        .padding(.horizontal, 7)
                        .frame(height: 38)
                        .overlay(alignment: .bottom) {
                            if selected {
                                Capsule().fill(HarborColors.blue).frame(height: 2)
                            }
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(
                        tint: HarborColors.blue, cornerRadius: 6))
                }
            }
            .padding(.horizontal, 10)
            .background(HarborHorizontalWheelBridge())
        }
        .scrollIndicators(.never)
        .help("在地区栏内使用滚轮横向浏览，或用触控板左右滑动")
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func regionActions(narrow: Bool, compact: Bool) -> some View {
        let targets = batchNodes
        let hasXray = proxy.coreInstalled
        let hasMihomo = proxy.mihomoInstalled
        let testableCount = targets.count { $0.protocolName == "openvpn" ? hasMihomo : hasXray }
        return HStack(spacing: 5) {
            if category == .residential || category == .volunteer || groupID.flatMap({ id in
                proxy.subscriptions.first(where: { $0.id == id })
            }).flatMap({ HarborProxyCommunitySource.matching($0.url) }) == .vpnGate {
                Button {
                    Task { await proxy.rescanResidentialPool() }
                } label: {
                    Label(compact ? "筛选" : "重新筛选", systemImage: "arrow.clockwise.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                .disabled(proxy.busy || proxy.latencyTesting)
                .help("获取 VPN Gate 志愿候选，识别家宽入口并真实测速。可使用当前代理，未连接时自动尝试独立通道。")
            }
            Menu {
                Picker("批量操作范围", selection: $batchScope) {
                    ForEach(BatchScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
                }
            } label: {
                if compact {
                    Image(systemName: "scope")
                        .accessibilityLabel("批量操作范围：\(batchScope.rawValue)")
                } else {
                    Label("范围 \(targets.count)", systemImage: "scope")
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                }
            }
            .fixedSize()
            .help("\(batchScope.rawValue)：\(targets.count) 个配置，\(testableCount) 个可测；范围包含所有匹配的分页")

            if proxy.latencyTesting {
                Button { proxy.cancelLatencyTests() } label: {
                    Label(proxy.latencyStopping ? "正在停止…" : "停止 \(proxy.latencyCompleted)/\(proxy.latencyTotal)",
                          systemImage: "stop.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.orange, prominence: .secondary))
                .disabled(proxy.latencyStopping)
            } else {
                Button {
                    Task { await proxy.testRealLatency(targets.map(\.id)) }
                } label: {
                    Label("测速", systemImage: "speedometer")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.green, prominence: .secondary))
                .disabled(testableCount == 0 || proxy.busy)
                .help("对所选范围发起真实代理请求；缺少对应内核的配置会跳过，当前连接保持不变")
            }

            Button {
                Task { await proxy.checkActiveWebsites() }
            } label: {
                Label(proxy.websiteChecking ? "检测中" : "网站检测",
                      systemImage: "network")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(!proxy.running || proxy.busy
                      || proxy.websiteChecking || proxy.checkingConnectivity)
            .help("通过当前实际代理出口检查 YouTube 和 ChatGPT 的 HTTPS 返回结果")

            Button {
                if proxy.exitGeoUpdating {
                    proxy.cancelExitGeoRefresh()
                } else {
                    proxy.refreshExitLocations(for: targets.map(\.id))
                }
            } label: {
                Label(proxy.exitGeoCleaningUp ? "正在停止…" : (proxy.exitGeoUpdating
                      ? "停止识别 \(proxy.exitGeoCompleted)/\(proxy.exitGeoTotal)"
                      : (compact ? "出口地区" : "更新出口地区")),
                      systemImage: proxy.exitGeoUpdating ? "stop.circle" : "globe.americas")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(proxy.exitGeoCleaningUp || (!proxy.exitGeoUpdating && (testableCount == 0 || proxy.busy)))
            .help(proxy.exitGeoUpdating
                  ? "停止本次识别，未完成的配置保留上次结果"
                  : "分批独立检测真实出口 IP；耗时取决于节点数量，可随时停止。悬停地区可查看失败原因")

            if narrow { Spacer(minLength: 6) }

            if unavailableCount > 0 {
                Button {
                    showUnavailable.toggle()
                    page = 1
                } label: {
                    Label("不可用 \(unavailableCount)",
                          systemImage: showUnavailable ? "eye.slash" : "eye")
                        .font(.system(size: 10.5, weight: .medium))
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(
                    tint: HarborColors.orange, prominence: .secondary))
                .help(showUnavailable ? "隐藏连续测速失败的节点" : "显示连续测速失败的节点")
            }

            HStack(spacing: 2) {
                modeButton("list.bullet", selected: !gridMode) { gridMode = false }
                modeButton("square.grid.2x2", selected: gridMode) { gridMode = true }
            }
            .padding(2)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.leading, 5)
        }
        .padding(.horizontal, 10)
    }

    private var emptyCatalogMessage: String {
        if unavailableCount > 0 && !showUnavailable { return "连续测速失败的配置已隐藏" }
        if let groupID, sourceGroupNodes.isEmpty {
            let isVPNGate = proxy.subscriptions.first { $0.id == groupID }
                .flatMap { HarborProxyCommunitySource.matching($0.url) } == .vpnGate
            return isVPNGate ? "还没有获取到 VPN Gate 候选地址" : "此订阅还没有加载到节点"
        }
        if favoritesOnly && favorites.isEmpty { return "还没有收藏的节点" }
        return proxy.nodes.isEmpty ? "暂无节点，可添加订阅" : "没有符合筛选条件的节点"
    }

    private var operationSummaries: [String] {
        [proxy.detail.contains("HTTP 127.0.0.1:") ? "" : proxy.detail,
         proxy.latencySummary, proxy.exitGeoSummary, proxy.websiteSummary].filter { !$0.isEmpty }
    }

    private func modeButton(_ symbol: String, selected: Bool,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(selected ? Color.white : Color.secondary)
                .frame(width: 27, height: 27)
                .background(selected ? HarborColors.blue : .clear,
                            in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 6))
        .help(selected ? "当前显示" + (symbol == "list.bullet" ? "列表" : "卡片") : "切换为" + (symbol == "list.bullet" ? "列表" : "卡片") + "视图")
        .accessibilityLabel((symbol == "list.bullet" ? "列表" : "卡片") + "视图")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    @ViewBuilder
    private func useButton(_ node: HarborProxyNode) -> some View {
        if proxy.activeNodeID == node.id && proxy.running {
            Text(proxy.healthy ? "使用中" : (proxy.checkingConnectivity ? "检测中" : "未通过"))
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(proxy.healthy ? HarborColors.green : HarborColors.orange)
                .frame(width: 44, height: 29)
                .accessibilityLabel("当前节点：\(node.displayName)")
        } else {
            Button {
                Task { await proxy.activate(node.id) }
            } label: {
                Text("使用")
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(HarborColors.blue)
                    .frame(width: 44, height: 29)
                    .background(HarborColors.blue.opacity(0.09),
                                in: RoundedRectangle(cornerRadius: 7))
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue,
                                                            cornerRadius: 7))
            .disabled(proxy.switchingNodeID == node.id || proxy.requiresRecovery)
            .accessibilityLabel("使用节点：\(node.displayName)")
        }
    }

    /// Only node content scrolls. Controls and pagination stay in view at any
    /// supported window height; there is no outer page scrolling.
    private func nodeTable(compact: Bool, showRegion: Bool, narrow: Bool,
                           compactActions: Bool) -> some View {
        // Snapshot filtering and latency sorting once per render, not again
        // for each pagination label, row and empty-state check.
        let groups = catalog.shownGroups
        let lastPage = max(1, (groups.count + pageSize - 1) / pageSize)
        let selectedPage = min(max(1, page), lastPage)
        let pageGroups = Array(groups.dropFirst((selectedPage - 1) * pageSize).prefix(pageSize))
        let showsProfileMenu = groups.contains { $0.nodes.count > 1 }
        return VStack(spacing: 0) {
            if availableCategories.count > 2 { categoryBar }
            regionBar(narrow: narrow, compactActions: compactActions)
            Rectangle().fill(HarborColors.cardBorder).frame(height: 1)

            if !gridMode {
                HStack(spacing: 10) {
                    Image(systemName: "circle").frame(width: 18).opacity(0)
                    if compact {
                        Text("节点名称")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 0) {
                            Text("节点名称")
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            Rectangle()
                                .fill(Color.primary.opacity(0.12))
                                .frame(width: 1, height: 20)
                                .padding(.horizontal, 5)
                                .contentShape(Rectangle().inset(by: -5))
                                .gesture(
                                    DragGesture(minimumDistance: 1)
                                        .onChanged { value in
                                            if nodeNameDragStart == nil {
                                                nodeNameDragStart = nodeNameColumnWidth
                                            }
                                            nodeNameColumnWidth = min(400, max(150,
                                                (nodeNameDragStart ?? nodeNameColumnWidth)
                                                    + Double(value.translation.width)))
                                        }
                                        .onEnded { _ in nodeNameDragStart = nil }
                                )
                                .help("拖动调整节点名称列宽")
                        }
                        .frame(width: nodeNameColumnWidth, alignment: .leading)
                        Text("类别 / 地址")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text("端口").frame(width: nodePortColumnWidth, alignment: .leading)
                    if !compact || showRegion {
                        Text("地区").frame(width: 76, alignment: .leading)
                    }
                    if compact {
                        Text("真实延迟")
                            .lineLimit(1)
                            .frame(width: 88, alignment: .leading)
                    } else {
                        Text("真实延迟").frame(width: 102, alignment: .leading)
                    }
                    if showsProfileMenu {
                        Text("配置").frame(width: profileMenuWidth)
                    }
                    Image(systemName: "speedometer").frame(width: 26)
                        .help("单节点真实测速")
                        .accessibilityLabel("真实测速")
                    Image(systemName: "star").frame(width: 29)
                        .help("收藏节点")
                        .accessibilityLabel("收藏")
                    Text("使用").frame(width: 44)
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 17)
                .frame(height: 36)
                .background(Color.primary.opacity(0.016))
            }

            GeometryReader { available in
                ScrollView(.vertical) {
                if pageGroups.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 24, weight: .ultraLight))
                        Text(emptyCatalogMessage)
                            .font(.system(size: 11))
                        if unavailableCount > 0 && !showUnavailable {
                            Button("查看失败节点并重试") {
                                showUnavailable = true
                                page = 1
                            }
                            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue,
                                                                 prominence: .secondary))
                        }
                    }
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 70)
                } else if gridMode {
                    let columnCount = max(2, min(6, Int((available.size.width + 9) / 270)))
                    // Use the configured page capacity, not the filtered result count.
                    // Region changes must not stretch one or two remaining cards.
                    let rowCount = max(1, (pageSize + columnCount - 1) / columnCount)
                    let cellHeight = max(88, min(128,
                        (available.size.height - 18 - CGFloat(max(0, rowCount - 1)) * 8) / CGFloat(rowCount)))
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 9), count: columnCount), spacing: 8) {
                        ForEach(pageGroups) { group in gridCard(group).frame(height: cellHeight) }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: available.size.height, alignment: .top)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(pageGroups) { group in
                            row(group, compact: compact, showRegion: showRegion,
                                showsProfileMenu: showsProfileMenu)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                }
                }
                .scrollIndicators(.never)
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            let summaries = operationSummaries
            if !summaries.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(summaries.enumerated()), id: \.offset) { _, summary in
                        Text(summary)
                            .lineLimit(1)
                            .help(summary)
                    }
                }
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            pagination(totalCount: groups.count, currentPage: selectedPage, maxPage: lastPage)
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HarborColors.cardBorder))
    }

    private func displayedNode(in group: AddressGroup) -> HarborProxyNode {
        if let selected = group.nodes.first(where: { $0.id == previewNodeID }) {
            return selected
        }
        if let connecting = group.nodes.first(where: { $0.id == visibleSwitchingNodeID }) {
            return connecting
        }
        return group.nodes.first(where: { $0.id == proxy.activeNodeID }) ?? group.nodes[0]
    }

    @ViewBuilder
    private func profileMenu(_ group: AddressGroup, selected node: HarborProxyNode) -> some View {
        if group.nodes.count > 1 {
            Menu {
                ForEach(group.nodes) { profile in
                    Button {
                        previewNodeID = profile.id
                    } label: {
                        let title = "\(profile.protocolName.uppercased()) · \(profile.displayName)"
                        if profile.id == node.id {
                            Label(title, systemImage: "checkmark")
                        } else {
                            Text(title)
                        }
                    }
                }
            } label: {
                Text("\(group.nodes.count) 种")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(HarborColors.blue)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .accessibilityLabel("选择连接配置，\(group.nodes.count) 种")
            .help("选择同一地址和端口的连接配置")
        }
    }

    private func row(_ group: AddressGroup, compact: Bool, showRegion: Bool,
                     showsProfileMenu: Bool) -> some View {
        let node = displayedNode(in: group)
        let active = proxy.activeNodeID == node.id && proxy.running
        let connected = active && proxy.healthy
        let probe = proxy.probeResults[node.id]
        let delay = probe?.milliseconds
        let connecting = visibleSwitchingNodeID == node.id
        let previewed = previewNodeID == node.id
        let rowBackground: Color = connected ? HarborColors.green.opacity(0.105)
            : ((active || connecting) ? HarborColors.orange.opacity(0.07)
               : (previewed ? HarborColors.blue.opacity(0.055) : .clear))
        let rowStroke: Color = connected ? HarborColors.green.opacity(0.34)
            : ((active || connecting) ? HarborColors.orange.opacity(0.24)
               : (previewed ? HarborColors.blue.opacity(0.28) : .clear))
        return HStack(spacing: 10) {
            Button {
                previewNodeID = node.id
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: connected ? "checkmark.circle.fill"
                          : (active || connecting ? "arrow.triangle.2.circlepath.circle.fill" : "circle"))
                        .font(.system(size: 13.5))
                        .foregroundStyle(connected ? HarborColors.green
                                         : ((active || connecting) ? HarborColors.orange
                                            : Color.primary.opacity(0.24)))
                        .frame(width: 18)
                    if compact {
                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 4) {
                                Text(node.displayName)
                                    .font(.system(size: 11.5, weight: connected ? .semibold : .medium))
                                    .foregroundStyle(connected ? HarborColors.green : .primary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                if node.customName != nil {
                                    Image(systemName: "pencil")
                                        .font(.system(size: 9))
                                        .foregroundStyle(.secondary)
                                }
                            }
                            HStack(spacing: 5) {
                                Text("\(categoryOf(node).rawValue) · \(node.host)")
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                if !showRegion { Text(regionFlag(node)) }
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } else {
                        HStack(spacing: 4) {
                            Text(node.displayName)
                                .font(.system(size: 11, weight: connected ? .semibold : .medium))
                                .foregroundStyle(connected ? HarborColors.green : .primary)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            if node.customName != nil {
                                Image(systemName: "pencil")
                                    .font(.system(size: 8.5, weight: .medium))
                                    .foregroundStyle(.secondary)
                                    .help("这是自定义节点名称；右键可修改或恢复订阅名称")
                            }
                        }
                        .frame(width: nodeNameColumnWidth, alignment: .leading)
                        Text("\(categoryOf(node).rawValue) · \(node.host)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Text(String(node.port))
                        .font(.system(size: 10.5))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .frame(width: nodePortColumnWidth, alignment: .leading)
                        .accessibilityLabel("端口 \(node.port)")
                    if !compact || showRegion {
                        HStack(spacing: 5) {
                            Text(regionFlag(node)).font(.system(size: 13))
                            Text(locationLabel(of: node)).lineLimit(1)
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .frame(width: 76, alignment: .leading)
                        .help(regionHint(node))
                    }
                    if compact {
                        Text(realLatencyText(
                            delay: delay, probe: probe, connecting: connecting, node: node))
                        .font(.system(size: 9.2, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(realLatencyTextColor(
                            delay: delay, probe: probe, connecting: connecting, node: node))
                        .lineLimit(1)
                        .help(latencyHint(probe, for: node))
                        .frame(width: 88, alignment: .leading)
                    } else {
                        Text(realLatencyText(
                            delay: delay, probe: probe, connecting: connecting, node: node))
                            .font(.system(size: 10.3, weight: connected || delay != nil ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(realLatencyTextColor(
                                delay: delay, probe: probe, connecting: connecting, node: node))
                            .lineLimit(1)
                            .help(latencyHint(probe, for: node))
                            .frame(width: 102, alignment: .leading)
                    }
                }
                .frame(height: compact ? 54 : 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                Task { await proxy.activate(node.id) }
            })
            .help("单击选择，点击右侧“使用”连接：\(node.displayName)。右键可以重命名")
            .accessibilityLabel("选择节点：" + node.displayName)
            .accessibilityAction(named: "连接节点") {
                Task { await proxy.activate(node.id) }
            }

            if showsProfileMenu {
                profileMenu(group, selected: node)
                    .frame(width: profileMenuWidth)
            }
            Button {
                Task { await proxy.testRealLatency([node.id]) }
            } label: {
                Image(systemName: proxy.latencyTestingIDs.contains(node.id)
                      ? "hourglass" : "speedometer")
                    .font(.system(size: 11.5))
                    .foregroundStyle(proxy.latencyTestingIDs.contains(node.id)
                                     ? HarborColors.orange : HarborColors.green)
                    .frame(width: 26, height: 30)
            }
            .disabled(proxy.latencyTesting || proxy.busy || !proxy.supportsCore(for: node))
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.green, cornerRadius: 7))
            .help("真实测速：通过独立代理内核的 SOCKS5 请求测速地址")
            Button {
                toggleFavorite(node.id)
            } label: {
                Image(systemName: favorites.contains(node.id) ? "star.fill" : "star")
                    .font(.system(size: 12))
                    .foregroundStyle(favorites.contains(node.id) ? HarborColors.orange : Color.secondary)
                    .frame(width: 29, height: 30)
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.orange, cornerRadius: 7))
            .help(favorites.contains(node.id) ? "取消收藏" : "收藏节点")
            useButton(node)
        }
        .padding(.horizontal, 8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .modifier(HarborStableHoverBackground(
            baseColor: rowBackground,
            highlightedColor: connected || active || connecting || previewed
                ? rowBackground : HarborColors.blue.opacity(0.055),
            cornerRadius: 8
        ))
        .overlay(alignment: .bottom) {
            Rectangle().fill(HarborColors.cardBorder.opacity(0.6))
                .frame(height: 0.5)
                .padding(.horizontal, 13)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 8)
                .stroke(rowStroke, lineWidth: 1)
        }
        .overlay(alignment: .leading) {
            if connected {
                Capsule().fill(HarborColors.green).frame(width: 3, height: 26)
            }
        }
        .contextMenu { nodeNameActions(node) }
        .accessibilityAddTraits(connected ? .isSelected : [])
    }

    private func gridCard(_ group: AddressGroup) -> some View {
        let node = displayedNode(in: group)
        let active = proxy.activeNodeID == node.id && proxy.running
        let connected = active && proxy.healthy
        let connecting = visibleSwitchingNodeID == node.id
        let probe = proxy.probeResults[node.id]
        let delay = probe?.milliseconds
        let previewed = previewNodeID == node.id
        let cardBackground: Color = connected ? HarborColors.green.opacity(0.105)
            : ((active || connecting) ? HarborColors.orange.opacity(0.07)
               : (previewed ? HarborColors.blue.opacity(0.055) : Color.primary.opacity(0.018)))
        let cardStroke: Color = connected ? HarborColors.green.opacity(0.36)
            : ((active || connecting) ? HarborColors.orange.opacity(0.25)
               : (previewed ? HarborColors.blue.opacity(0.28) : HarborColors.cardBorder))
        return HStack(alignment: .center, spacing: 6) {
            Button {
                previewNodeID = node.id
            } label: {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: connected ? "checkmark.circle.fill"
                              : (active || connecting ? "arrow.triangle.2.circlepath.circle.fill" : "circle"))
                            .font(.system(size: 11))
                            .foregroundStyle(connected ? HarborColors.green
                                             : ((active || connecting) ? HarborColors.orange
                                                : Color.secondary.opacity(0.45)))
                        Text(node.displayName)
                            .font(.system(size: 11.5, weight: .semibold))
                            .foregroundStyle(connected ? HarborColors.green : .primary)
                            .lineLimit(1)
                        if node.customName != nil {
                            Image(systemName: "pencil")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 3)
                        if connected {
                            Text("已连接")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(HarborColors.green)
                                .padding(.horizontal, 6)
                                .frame(height: 19)
                                .background(HarborColors.green.opacity(0.11), in: Capsule())
                        } else if connecting {
                            Text("切换中")
                                .font(.system(size: 9.5, weight: .semibold))
                                .foregroundStyle(HarborColors.orange)
                        }
                    }
                    HStack(spacing: 0) {
                        Text("\(categoryOf(node).rawValue) · \(node.host)")
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(":\(node.port)")
                            .monospacedDigit()
                            .fixedSize()
                            .accessibilityLabel("端口 \(node.port)")
                    }
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    HStack(spacing: 8) {
                        Text("\(regionFlag(node)) \(locationLabel(of: node))")
                            .help(regionHint(node))
                        Spacer(minLength: 2)
                        Text(realLatencyText(
                            delay: delay, probe: probe, connecting: connecting, node: node))
                            .lineLimit(1)
                            .font(.system(size: 10.5, weight: delay == nil ? .regular : .semibold))
                            .monospacedDigit()
                            .foregroundStyle(realLatencyTextColor(
                                delay: delay, probe: probe, connecting: connecting, node: node))
                            .help(latencyHint(probe, for: node))
                    }
                    .font(.system(size: 9.5))
                }
                .padding(.leading, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .simultaneousGesture(TapGesture(count: 2).onEnded {
                Task { await proxy.activate(node.id) }
            })
            .accessibilityAction(named: "连接节点") {
                Task { await proxy.activate(node.id) }
            }
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 2) {
                    profileMenu(group, selected: node)
                    Button {
                        toggleFavorite(node.id)
                    } label: {
                        Image(systemName: favorites.contains(node.id) ? "star.fill" : "star")
                            .foregroundStyle(favorites.contains(node.id) ? HarborColors.orange : Color.secondary)
                            .frame(width: 30, height: 30)
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.orange))
                }
                Button {
                    Task { await proxy.testRealLatency([node.id]) }
                } label: {
                    Image(systemName: proxy.latencyTestingIDs.contains(node.id)
                          ? "hourglass" : "speedometer")
                        .foregroundStyle(HarborColors.green)
                        .frame(width: 27, height: 27)
                }
                .disabled(proxy.latencyTesting || proxy.busy || !proxy.supportsCore(for: node))
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.green, cornerRadius: 7))
                .help("真实测速：通过独立代理内核的 SOCKS5 请求测速地址")
                useButton(node)
            }
        }
        .padding(.trailing, 8)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .modifier(HarborStableHoverBackground(
            baseColor: cardBackground,
            highlightedColor: connected || active || connecting || previewed
                ? cardBackground : HarborColors.blue.opacity(0.055),
            cornerRadius: 10
        ))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(cardStroke))
        .overlay(alignment: .leading) {
            if connected {
                Capsule().fill(HarborColors.green).frame(width: 3, height: 30)
            }
        }
        .contextMenu { nodeNameActions(node) }
        .help("单击选择，点击“使用”连接：\(node.displayName)；右键可重命名")
        .accessibilityAddTraits(connected ? .isSelected : [])
    }

    @ViewBuilder
    private func nodeNameActions(_ node: HarborProxyNode) -> some View {
        Button {
            proxy.toggleFallbackAuthorization(node)
        } label: {
            Label(proxy.isAuthorizedFallback(node) ? "取消备用节点授权" : "允许作为自动恢复备用节点",
                  systemImage: proxy.isAuthorizedFallback(node) ? "shield.slash" : "checkmark.shield")
        }
        Button {
            renameText = node.displayName
            renameTarget = RenameTarget(id: node.id)
        } label: {
            Label("重命名节点", systemImage: "pencil")
        }
        if node.customName != nil {
            Button {
                proxy.restoreNodeName(node.id)
            } label: {
                Label(node.automaticName == nil ? "恢复订阅名称" : "恢复自动名称",
                      systemImage: "arrow.uturn.backward")
            }
        }
    }

    private func pagination(totalCount: Int, currentPage: Int, maxPage: Int) -> some View {
        HStack(spacing: 4) {
            Text("共 \(totalCount) 条")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            pageButton("chevron.left", to: currentPage - 1).disabled(currentPage == 1)
            ForEach(HarborProxyCatalog.pageChoices(current: currentPage, total: maxPage), id: \.self) { value in
                if value == 0 {
                    Text("…").font(.system(size: 10)).frame(width: 18)
                } else {
                    Button {
                        page = value
                    } label: {
                        Text("\(value)")
                            .font(.system(size: 10, weight: value == currentPage ? .semibold : .medium))
                            .foregroundStyle(value == currentPage ? Color.white : Color.primary)
                            .frame(width: 34, height: 32)
                            .background(value == currentPage ? HarborColors.blue : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
                            // Hit testing covers the whole cell, including the
                            // empty space around the single-digit label.
                            .contentShape(RoundedRectangle(cornerRadius: 7))
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue))
                }
            }
            pageButton("chevron.right", to: currentPage + 1).disabled(currentPage == maxPage)
            Spacer(minLength: 0)
            Menu {
                ForEach([10, 20, 30], id: \.self) { size in
                    Button("每页 \(size) 条") { pageSize = size }
                }
            } label: {
                Text("每页 \(pageSize) 条")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton)
            .frame(width: 86)
        }
        .frame(height: 52)
        .padding(.horizontal, 15)
        .overlay(alignment: .top) {
            Rectangle().fill(HarborColors.cardBorder).frame(height: 1)
        }
    }

    private func pageButton(_ icon: String, to index: Int) -> some View {
        Button { page = index } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .frame(width: 34, height: 32)
                .contentShape(RoundedRectangle(cornerRadius: 7))
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue))
    }

    private func beginEditingSubscription(_ item: HarborProxySubscription) {
        editingSubscriptionID = item.id
        subscriptionName = item.name
        subscriptionURL = item.url
        subscriptionError = nil
        editor = .editSubscription
    }

    private func addCommunitySource(_ source: HarborProxyCommunitySource) {
        guard !proxy.busy, !proxy.latencyTesting else { return }
        let id: String
        if let existing = proxy.subscriptions.first(where: {
            HarborProxyCommunitySource.matching($0.url) == source
        }) {
            id = existing.id
        } else {
            guard proxy.addSubscription(name: source.name, url: source.url),
                  let added = proxy.subscriptions.last else { return }
            id = added.id
        }
        editor = nil
        groupID = id
        favoritesOnly = false
        resetFilters()
        category = .volunteer
        Task { await proxy.refreshCommunitySubscription(id) }
    }

    private func requestSubscriptionDeletion(_ id: String) {
        deletionError = nil
        deletingSubscription = false
        deletionTargetID = DeletionTarget(id: id)
    }

    private func toggleFavorite(_ id: String) {
        if !favorites.insert(id).inserted { favorites.remove(id) }
        UserDefaults.standard.set(Array(favorites), forKey: favoritesKey)
    }

    private func protocolColor(_ name: String) -> Color {
        switch name.lowercased() {
        case "trojan": HarborColors.green
        case "shadowsocks": HarborColors.red
        default: HarborColors.blue
        }
    }

    private func latencyColor(_ milliseconds: Int) -> Color {
        if milliseconds < HarborProxyLatencyPolicy.goodUpperBoundMilliseconds {
            return HarborColors.green
        }
        if milliseconds < HarborProxyLatencyPolicy.warningUpperBoundMilliseconds {
            return HarborColors.orange
        }
        return HarborColors.red
    }

    private func realLatencyText(delay: Int?, probe: HarborProxyProbeResult?,
                                 connecting: Bool, node: HarborProxyNode) -> String {
        if connecting { return "切换中" }
        if proxy.latencyTestingIDs.contains(node.id) {
            return "测速中"
        }
        if let delay {
            return "\(delay) ms" + (probe.map { !proxy.isUsable($0, for: node) } == true ? " · 旧" : "")
        }
        guard probe?.realTested == true else { return "未测速" }
        if node.protocolName == "openvpn", let reason = probe?.realFailureReason {
            if reason.contains("握手") { return "握手超时" }
            if reason.contains("HTTPS") { return "出口验证失败" }
            if reason.contains("Mihomo") { return "内核启动失败" }
        }
        return probe.map { proxy.isUnavailable($0, for: node) } == true ? "不可用" : "待复测"
    }

    private func realLatencyTextColor(delay: Int?, probe: HarborProxyProbeResult?,
                                      connecting: Bool, node: HarborProxyNode) -> Color {
        if connecting { return HarborColors.orange }
        if proxy.latencyTestingIDs.contains(node.id) {
            return HarborColors.orange
        }
        if let delay {
            return probe.map { proxy.isUsable($0, for: node) } == true ? latencyColor(delay) : .secondary
        }
        guard probe?.realTested == true else { return Color.secondary }
        return probe.map { proxy.isUnavailable($0, for: node) } == true ? HarborColors.red : HarborColors.orange
    }

    private func regionEmoji(_ name: String) -> String {
        switch name {
        case "香港": "🇭🇰"
        case "美国": "🇺🇸"
        case "日本": "🇯🇵"
        case "新加坡": "🇸🇬"
        case "台湾": "🇹🇼"
        case "德国": "🇩🇪"
        case "韩国": "🇰🇷"
        case "英国": "🇬🇧"
        default: "🌐"
        }
    }

    private func regionFlag(_ node: HarborProxyNode) -> String {
        if node.protocolName == "openvpn" {
            return proxy.exitLocation(for: node)?.flag
                ?? HarborVPNGate.publisherLocation(for: node)?.flag ?? "🌐"
        }
        if categoryOf(node) == .residential {
            return proxy.exitLocation(for: node)?.flag ?? "🌐"
        }
        return proxy.serverLocation(for: node)?.flag ?? "🌐"
    }

    private func resetFilters() {
        page = 1
        category = .all
        region = "全部"
        protocolFilter = "全部"
        latencyFilter = "全部"
        showUnavailable = true
    }

    private func locationLabel(of node: HarborProxyNode) -> String {
        if let exit = proxy.exitLocation(for: node) { return exit.displayRegion }
        if let source = HarborVPNGate.publisherLocation(for: node) { return source.displayRegion + "·来源" }
        if proxy.exitGeoUnrecognizedIDs.contains(node.id) { return "未识别" }
        if categoryOf(node) != .residential, let entrance = proxy.entranceLocation(for: node),
           entrance.verifiedCountryCode != nil {
            return entrance.displayRegion + "·入口"
        }
        return HarborProxyAutomaticName.unresolvedRegion
    }

    private func regionHint(_ node: HarborProxyNode) -> String {
        let reason = proxy.exitGeoFailureReasons[node.id].map { "；最近一次未更新：" + $0 } ?? ""
        if let exit = proxy.exitLocation(for: node) {
            let checked = proxy.nodeExitLocations[node.id]?.observedAt.formatted(date: .abbreviated, time: .shortened)
            return "已验证出口 IP：\(exit.ip)" + (checked.map { "；验证于 " + $0 } ?? "") + reason
        }
        if let prior = proxy.observedExit(for: node) {
            return (prior.verifiedCountryCode == nil
                ? "已检测到出口 IP：\(prior.ip)，地区尚未确认"
                : "上次观察到出口 IP：\(prior.ip)（\(prior.displayRegion)），待复测") + reason
        }
        if let source = HarborVPNGate.publisherLocation(for: node) {
            return "VPN Gate 发布的来源：\(source.displayRegion)；出口尚未确认" + reason
        }
        if let location = proxy.entranceLocation(for: node) {
            return "节点入口 IP：\(location.ip)；出口尚未确认" + reason
        }
        return "出口 IP 尚未确认" + reason
    }

    private func latencyHint(_ probe: HarborProxyProbeResult?, for node: HarborProxyNode) -> String {
        guard let probe, probe.realTested else { return "还没有真实代理测速结果" }
        let route: String
        switch probe.probeRouteID {
        case "direct": route = " · 直接连接到志愿节点"
        case let value? where value.hasPrefix("underlay:"): route = " · 通过其他代理连接志愿节点"
        case let value? where value.hasPrefix("warp:"): route = " · 通过独立通道连接志愿节点"
        default: route = ""
        }
        let date = (probe.realCheckedAt ?? probe.checkedAt).formatted(date: .abbreviated, time: .shortened)
        let result = probe.realFailureReason ?? "已测请求延迟"
        let freshness = probe.succeeded && !proxy.isUsable(probe, for: node) ? " · 待复测" : ""
        return result + route + " · " + date + freshness
    }

    // A centered, padded form with the same visual language as hosted-key setup.
    private func editorSheet(_ mode: Editor) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 14) {
                Text(mode == .importChoice ? "新增代理配置"
                     : (mode == .subscription ? "添加订阅"
                        : (mode == .editSubscription ? "编辑订阅"
                           : (mode == .routing ? "强制代理站点"
                              : (mode == .ports ? "代理监听端口" : "导入节点链接")))))
                    .font(.system(size: 19, weight: .bold, design: .rounded))
                Spacer(minLength: 0)
                Button { editor = nil } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(
                    tint: Color.primary, cornerRadius: 9))
                .help("关闭弹窗")
                .accessibilityLabel("关闭弹窗")
                .disabled(editorSaving || portUpdating)
            }
            .frame(height: 34)
            .padding(.bottom, mode == .ports ? 9 : 22)

            if mode == .importChoice {
                Text("选择添加方式")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 13)
                VStack(spacing: 12) {
                    ForEach(missingCommunitySources, id: \.self) { source in
                        importOption("VPN Gate 志愿节点",
                                     subtitle: "一键导入公开候选；会自动检测真实可用性",
                                     symbol: "network",
                                     tint: HarborColors.blue) {
                            addCommunitySource(source)
                        }
                    }
                    importOption("订阅地址", subtitle: "通过 HTTPS 订阅获取并更新节点",
                                 symbol: "link", tint: HarborColors.blue) {
                        editingSubscriptionID = nil
                        subscriptionName = ""
                        subscriptionURL = ""
                        subscriptionError = nil
                        editor = .subscription
                    }
                    importOption("节点分享链接", subtitle: "粘贴 VLESS、VMess、Trojan 或 SS 链接",
                                 symbol: "square.and.arrow.down", tint: HarborColors.purple) {
                        editor = .links
                    }
                }
            } else if mode == .subscription || mode == .editSubscription {
                VStack(alignment: .leading, spacing: 7) {
                    Text("订阅名称").font(.callout.weight(.semibold))
                    TextField("例如：我的订阅", text: $subscriptionName)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("订阅名称")
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.12)))
                }
                .padding(.bottom, 17)
                VStack(alignment: .leading, spacing: 7) {
                    Text("HTTPS 订阅地址").font(.callout.weight(.semibold))
                    TextField("粘贴 https:// 开头的订阅链接", text: $subscriptionURL)
                        .textFieldStyle(.plain)
                        .accessibilityLabel("HTTPS 订阅地址")
                        .padding(.horizontal, 12)
                        .frame(height: 44)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.12)))
                    Text(mode == .editSubscription
                         ? "只修改名称立即保存；修改 HTTPS 链接时先下载并校验最新节点，成功后一起保存，失败则保留原链接和节点。当前代理不会自动切换。"
                         : "订阅链接加密保存在本机，添加后自动加载节点；之后可随时编辑。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if let subscriptionError {
                        Text(subscriptionError)
                            .font(.system(size: 11))
                            .foregroundStyle(HarborColors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if mode == .ports {
                VStack(alignment: .leading, spacing: 10) {
                    TextField("HTTP 端口（例如 18080）", text: $listenPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 38)
                        .accessibilityLabel("HTTP 代理监听端口")
                    Toggle("打开 Harbor 时恢复上次连接", isOn: Binding(
                        get: { proxy.resumeConnectionOnLaunch },
                        set: { proxy.setResumeConnectionOnLaunch($0) }
                    ))
                    .font(.system(size: 11))
                    Toggle("允许自动切换已授权备用节点", isOn: Binding(
                        get: { proxy.fallbackPolicy.enabled },
                        set: { proxy.setAutomaticFallback($0) }
                    ))
                    .font(.system(size: 11))
                    Text("默认关闭。右键节点单独授权；仅在同节点恢复失败后，验证相同协议、出口国家及网络类型。证据不足时不切换。")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("从安装包修复代理内核") {
                        editor = nil
                        Task { await proxy.installBundledXray() }
                    }
                    .font(.system(size: 11))
                    .disabled(proxy.running || proxy.requiresRecovery || proxy.busy || proxy.latencyTesting
                              || proxy.exitGeoUpdating || proxy.exitGeoCleaningUp)
                    .help("先停止当前连接和检测，再校验并修复内置 Xray、Mihomo 和地区资源")
                    if let listenPortError {
                        Text(listenPortError)
                            .font(.system(size: 11))
                            .foregroundStyle(HarborColors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            } else if mode == .routing {
                VStack(alignment: .leading, spacing: 10) {
                    Text("始终通过代理访问的域名")
                        .font(.system(size: 12, weight: .semibold))
                    TextEditor(text: $forcedDomainText)
                        .font(.system(size: 12, design: .monospaced))
                        .frame(height: 148)
                        .padding(6)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.12)))
                    Text("每行一个域名，如 gitee.com；自动包含所有子域名。优先于国内直连规则，在规则和全局模式下均生效。")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    if proxy.running {
                        Text("保存后将自动重新连接当前节点以应用规则，连接可能短暂中断。")
                            .font(.system(size: 11))
                            .foregroundStyle(HarborColors.orange)
                    }
                    if let forcedDomainError {
                        Text(forcedDomainError)
                            .font(.system(size: 11))
                            .foregroundStyle(HarborColors.red)
                    }
                }
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("节点分享链接").font(.callout.weight(.semibold))
                    TextEditor(text: $nodeLinks)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(height: 140)
                        .padding(5)
                        .background(Color(nsColor: .controlBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 10))
                        .overlay(RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.primary.opacity(0.12)))
                    Text("每行一条链接，不影响已连接的代理")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if let subscriptionError {
                        Text(subscriptionError)
                            .font(.system(size: 11))
                            .foregroundStyle(HarborColors.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            Spacer(minLength: mode == .ports ? 8 : 18)
            Rectangle()
                .fill(HarborColors.cardBorder)
                .frame(height: 1)
                .padding(.bottom, mode == .ports ? 8 : 15)
            HStack(spacing: 10) {
                Spacer()
                Button("取消") { editor = nil }
                    .keyboardShortcut(.cancelAction)
                    .disabled(editorSaving || portUpdating)
                    .buttonStyle(HarborActionButtonStyle(
                        tint: .secondary, prominence: .secondary))
                if mode == .ports {
                    Button {
                        guard let chosenPort = Int(listenPortText.trimmingCharacters(in: .whitespacesAndNewlines)) else {
                            listenPortError = "请输入数字端口，范围 1024～65534"
                            return
                        }
                        portUpdating = true
                        Task {
                            defer { portUpdating = false }
                            do {
                                try await proxy.updateHTTPPort(chosenPort)
                                editor = nil
                            } catch {
                                listenPortError = error.localizedDescription
                            }
                        }
                    } label: {
                        Text(portUpdating ? "正在切换…" : "保存端口")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(portUpdating || proxy.busy || proxy.latencyTesting)
                } else if mode == .routing {
                    Button {
                        let domains = forcedDomainText
                            .components(separatedBy: .newlines)
                            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                            .filter { !$0.isEmpty }
                        do {
                            let changed = domains != proxy.forcedProxyDomains
                            try proxy.updateForcedProxyDomains(domains)
                            editor = nil
                            if changed { Task { await proxy.reapplyRouting() } }
                        } catch {
                            forcedDomainError = error.localizedDescription
                        }
                    } label: {
                        Text("保存规则")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(proxy.busy)
                } else if mode != .importChoice {
                    Button {
                        if mode == .subscription {
                            guard proxy.addSubscription(name: subscriptionName, url: subscriptionURL) else {
                                subscriptionError = proxy.detail
                                return
                            }
                            subscriptionName = ""
                            subscriptionURL = ""
                            subscriptionError = nil
                            if let newID = proxy.subscriptions.last?.id {
                                groupID = newID
                                favoritesOnly = false
                                resetFilters()
                                Task { await proxy.refreshSubscription(newID) }
                            }
                        } else if mode == .editSubscription {
                            guard let id = editingSubscriptionID else { return }
                            let name = subscriptionName
                            let url = subscriptionURL
                            editorSaving = true
                            subscriptionError = nil
                            Task {
                                let saved = await proxy.updateSubscription(id, name: name, url: url)
                                editorSaving = false
                                if saved {
                                    editingSubscriptionID = nil
                                    subscriptionName = ""
                                    subscriptionURL = ""
                                    editor = nil
                                } else {
                                    subscriptionError = proxy.detail
                                }
                            }
                            return
                        } else {
                            let links = nodeLinks
                            editorSaving = true
                            subscriptionError = nil
                            Task {
                                let saved = await proxy.addLinks(links)
                                editorSaving = false
                                if saved {
                                    nodeLinks = ""
                                    editor = nil
                                } else {
                                    subscriptionError = proxy.detail
                                }
                            }
                            return
                        }
                        editor = nil
                    } label: {
                        HStack(spacing: 7) {
                            if editorSaving {
                                ProgressView().controlSize(.small)
                            }
                            Text(mode == .editSubscription
                                 ? (editorSaving ? "正在更新节点…" : "保存订阅")
                                 : (mode == .subscription ? "添加订阅" : (editorSaving ? "正在导入…" : "导入节点")))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(
                        tint: .blue, prominence: .prominent))
                    .disabled((mode == .subscription || mode == .editSubscription)
                              ? (subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 || editorSaving || proxy.busy || proxy.latencyTesting)
                              : (editorSaving || proxy.busy || nodeLinks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
            }
            .frame(height: 35)
        }
        .padding(.horizontal, mode == .ports ? 19 : 27)
        .padding(.top, mode == .ports ? 15 : 30)
        .padding(.bottom, mode == .ports ? 15 : 26)
        .frame(width: mode == .ports ? 355 : 500)
        .frame(minHeight: mode == .ports ? 0
               : (mode == .importChoice ? 356
                  : (mode == .routing ? 440 : (mode == .links ? 375 : 370))))
        .onExitCommand {
            if !editorSaving && !portUpdating { editor = nil }
        }
    }

    private func importOption(_ title: String, subtitle: String, symbol: String,
                              tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 13) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(tint)
                    .frame(width: 38, height: 38)
                    .background(tint.opacity(0.085), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(.primary)
                    Text(subtitle)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .frame(height: 64)
            .background(Color(nsColor: .controlBackgroundColor),
                        in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.10)))
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: tint, cornerRadius: 10))
    }

}

/// Limit pointer highlight invalidations to the individual row or card.
/// A workspace-level @State hover ID causes all node filters and sorters to
/// recompute on every enter/leave while the user scrolls.
private struct HarborStableHoverBackground: ViewModifier {
    let baseColor: Color
    let highlightedColor: Color
    let cornerRadius: CGFloat

    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .background(
                hovering ? highlightedColor : baseColor,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .onHover { isInside in
                if hovering != isInside { hovering = isInside }
            }
    }
}

/// No scrolling timer, SwiftUI animation or window-wide wheel interception.
/// The single local wheel listener only exists while the pointer is within
/// the region strip. Native horizontal gestures continue through unchanged.
private struct HarborHorizontalWheelBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelView { WheelView() }

    func updateNSView(_ nsView: WheelView, context: Context) {
        nsView.hideScroller()
    }

    final class WheelView: NSView {
        nonisolated(unsafe) private var monitor: Any?
        private var wheelTrackingArea: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if window == nil { stopMonitoring() }
            hideScroller()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let wheelTrackingArea { removeTrackingArea(wheelTrackingArea) }
            let area = NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            wheelTrackingArea = area
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scroll = self.enclosingScrollView,
                      event.window === self.window,
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      let document = scroll.documentView else { return event }

                let clip = scroll.contentView
                let point = clip.convert(event.locationInWindow, from: nil)
                guard clip.bounds.contains(point) else { return event }

                let maxX = max(0, document.frame.width - clip.bounds.width)
                guard maxX > 0 else { return event }
                let delta = event.hasPreciseScrollingDeltas
                    ? event.scrollingDeltaY : event.scrollingDeltaY * 20
                let nextX = min(maxX, max(0, clip.bounds.origin.x - delta))
                guard nextX != clip.bounds.origin.x else { return event }

                clip.scroll(to: NSPoint(x: nextX, y: clip.bounds.origin.y))
                scroll.reflectScrolledClipView(clip)
                return nil
            }
        }

        override func mouseExited(with event: NSEvent) {
            super.mouseExited(with: event)
            stopMonitoring()
        }

        func hideScroller() {
            guard let scroll = enclosingScrollView, scroll.hasHorizontalScroller else { return }
            scroll.hasHorizontalScroller = false
        }

        private func stopMonitoring() {
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
