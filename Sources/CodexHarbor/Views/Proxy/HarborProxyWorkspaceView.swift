import SwiftUI
import AppKit
import CodexHarborCore

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
    @State private var subscriptionSaving = false
    @State private var nodeLinks = ""
    @State private var forcedDomainText = ""
    @State private var forcedDomainError: String?
    @State private var listenPortText = ""
    @State private var listenPortError: String?
    @State private var portUpdating = false
    @State private var copiedProxyURL: String?
    @State private var hoveredSubscriptionID: String?
    @State private var hoveredNodeID: String?
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

    private struct DeletionTarget: Identifiable { let id: String }
    private struct RenameTarget: Identifiable { let id: String }

    private enum NodeCategory: String, CaseIterable {
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

    private let favoritesKey = "com.codexharbor.proxy.favoriteNodeIDs"
    private let subscriptionTints: [Color] = [
        HarborColors.blue, HarborColors.green, HarborColors.orange, HarborColors.purple
    ]

    private var sourceGroupNodes: [HarborProxyNode] {
        proxy.nodes.filter { node in
            if let groupID { return node.subscriptionID == groupID }
            return !favoritesOnly || favorites.contains(node.id)
        }
    }

    private var currentGroupIsTesting: Bool {
        proxy.latencyTesting && sourceGroupNodes.contains {
            proxy.latencyBatchIDs.contains($0.id)
        }
    }

    private var availableCategories: [NodeCategory] {
        [.all] + NodeCategory.allCases.filter { choice in
            choice != .all && sourceGroupNodes.contains { categoryOf($0) == choice }
        }
    }

    private func categoryOf(_ node: HarborProxyNode) -> NodeCategory {
        guard let subscription = proxy.subscriptions.first(where: { $0.id == node.subscriptionID }),
              let source = HarborProxyCommunitySource.matching(subscription.url) else {
            return .custom
        }
        if source == .vpnGate {
            if node.security == "vpngate-datacenter" { return .datacenter }
            switch proxy.networkEvidence(for: node)?.kind {
            case .residential: return .residential
            case .hosting: return .datacenter
            default: return .volunteer
            }
        }
        return .residential
    }

    /// Freeze filtering and ordering during probing; only the cell's live status
    /// changes until the whole batch completes.
    private var displayedProbeResults: [String: HarborProxyProbeResult] {
        proxy.latencyTesting ? (frozenLatencyResults ?? proxy.probeResults) : proxy.probeResults
    }

    private var groupNodes: [HarborProxyNode] {
        sourceGroupNodes.filter { node in
            guard let result = displayedProbeResults[node.id], result.realTested else { return true }
            return !result.isConfirmedUnavailable || showUnavailable
        }
    }

    private var unavailableCount: Int {
        sourceGroupNodes.filter {
            guard let result = displayedProbeResults[$0.id] else { return false }
            return result.isConfirmedUnavailable
        }.count
    }

    private var categoryNodes: [HarborProxyNode] {
        groupNodes.filter { category == .all || categoryOf($0) == category }
    }

    private var shownNodes: [HarborProxyNode] {
        let result = categoryNodes.filter { node in
            if region != "全部" && location(of: node) != region { return false }
            if protocolFilter != "全部" && node.protocolName.uppercased() != protocolFilter { return false }
            if latencyFilter != "全部" {
                guard let delay = displayedProbeResults[node.id]?.milliseconds else { return false }
                if latencyFilter == "快速"
                    && delay >= HarborProxyLatencyPolicy.goodUpperBoundMilliseconds { return false }
                if latencyFilter == "一般"
                    && (delay < HarborProxyLatencyPolicy.goodUpperBoundMilliseconds
                        || delay >= HarborProxyLatencyPolicy.warningUpperBoundMilliseconds) { return false }
                if latencyFilter == "较慢"
                    && delay < HarborProxyLatencyPolicy.warningUpperBoundMilliseconds { return false }
            }
            let text = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            return text.isEmpty || node.displayName.localizedCaseInsensitiveContains(text)
                || node.name.localizedCaseInsensitiveContains(text)
                || node.host.localizedCaseInsensitiveContains(text)
                || node.protocolName.localizedCaseInsensitiveContains(text)
        }
        return HarborProxySubscriptionRefreshPolicy.initialLatencyOrder(
            result, results: displayedProbeResults
        )
    }
    private var maxPage: Int { max(1, (shownNodes.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(max(1, page), maxPage) }
    private var visibleNodes: [HarborProxyNode] {
        Array(shownNodes.dropFirst((currentPage - 1) * pageSize).prefix(pageSize))
    }
    private var title: String {
        if let groupID { return proxy.subscriptions.first(where: { $0.id == groupID })?.name ?? "订阅节点" }
        return favoritesOnly ? "我的收藏" : "全部节点"
    }
    private var protocols: [String] {
        ["全部"] + Array(Set(groupNodes.map { $0.protocolName.uppercased() })).sorted()
    }
    private var regions: [String] {
        let actual = Set(categoryNodes.map(location))
        let priority = ["香港", "美国", "日本", "新加坡", "台湾", "德国", "韩国", "英国"]
        return ["全部"] + priority.filter(actual.contains)
            + actual.subtracting(Set(priority)).sorted()
    }

    private var missingCommunitySources: [HarborProxyCommunitySource] {
        HarborProxyCommunitySource.offered.filter { source in
            !proxy.subscriptions.contains { HarborProxyCommunitySource.matching($0.url) == source }
        }
    }

    var body: some View {
        GeometryReader { geometry in
            workspaceLayout(size: geometry.size)
        }
        .task {
            await proxy.bootstrap()
            await proxy.refreshCommunitySourcesIfNeeded()
        }
        .onAppear {
            favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
        }
        .onChange(of: proxy.subscriptions.map(\.id)) { _, ids in
            if let groupID, !ids.contains(groupID) {
                self.groupID = nil
                favoritesOnly = false
                resetFilters()
            }
        }
        .onChange(of: keyword) { _, _ in page = 1 }
        .onChange(of: category) { _, _ in
            page = 1
            if region != "全部" && !regions.contains(region) { region = "全部" }
        }
        .onChange(of: availableCategories) { _, choices in
            if !choices.contains(category) { category = .all }
        }
        .onChange(of: region) { _, _ in page = 1 }
        .onChange(of: protocolFilter) { _, _ in page = 1 }
        .onChange(of: latencyFilter) { _, _ in page = 1 }
        .onChange(of: proxy.latencyTesting) { _, testing in
            if testing {
                frozenLatencyResults = proxy.probeResults
            } else {
                frozenLatencyResults = nil
                page = 1
            }
        }
        .onChange(of: pageSize) { _, _ in page = 1 }
        .onChange(of: proxy.localPort) { _, _ in copiedProxyURL = nil }
        .onChange(of: proxy.nodeServerLocations) { _, _ in
            if region != "全部" && !regions.contains(region) { region = "全部" }
        }
        .onChange(of: proxy.nodeExitLocations) { _, _ in
            if region != "全部" && !regions.contains(region) { region = "全部" }
        }
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
                let inUse = proxy.running && proxy.activeNode?.subscriptionID == id
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
        }
        .frame(width: contentWidth, height: max(0, size.height - 13), alignment: .topLeading)
        .padding(.horizontal, outerInset)
        .padding(.top, 3)
        .padding(.bottom, 10)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("网络代理")
                    .font(.system(size: 20, weight: .bold, design: .rounded))
                    .tracking(-0.5)
                Text("管理订阅与节点，一键切换，轻松上网")
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
        if let id = visibleSwitchingNodeID {
            return proxy.nodes.first { $0.id == id }
        }
        if proxy.running, let node = proxy.activeNode { return node }
        return proxy.selectedNode
    }

    private var proxyNodeTitle: String {
        headerNode?.displayName ?? "未选择代理节点"
    }

    private var proxyConnectionStatus: String {
        if proxy.requiresRecovery { return "请先恢复系统代理设置，避免网络异常" }
        if visibleSwitchingNodeID != nil { return "正在切换 · 启动并验证新节点" }
        if proxy.running && proxy.checkingConnectivity {
            return "正在连接 · 本地端口已就绪，检测真实网络中"
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
            + (result.isStale() ? " · 旧" : "")
    }

    private var proxyLatencyColor: Color {
        if visibleSwitchingNodeID != nil || (proxy.running && proxy.checkingConnectivity) {
            return HarborColors.orange
        }
        guard let node = headerNode,
              let latency = proxy.probeResults[node.id]?.milliseconds else { return .secondary }
        return latencyColor(latency)
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
                    Circle().fill(proxyStateColor).frame(width: 6, height: 6)
                    Text(proxyConnectionStatus)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
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
            .disabled(proxy.busy || portUpdating)
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 7))
            .help("设置固定代理监听端口，默认 HTTP 18080 / SOCKS5 18081")
            if proxy.running && proxy.healthy && !proxy.systemManaged {
                Button {
                    proxy.enableSystemProxy(interactive: true)
                } label: {
                    Label("接管系统代理", systemImage: "network.badge.shield.half.filled")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.green, prominence: .secondary))
                .disabled(proxy.busy)
                .help("将已验证的当前节点设置为 macOS HTTP、HTTPS 与 SOCKS5 系统代理")
            }
            if proxy.running || proxy.requiresRecovery {
                Button {
                    Task { await proxy.clearProxy(interactive: true) }
                } label: {
                    Label("清理代理", systemImage: "trash")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                .disabled(proxy.busy)
                .help("恢复 Harbor 接管前的系统代理设置，并停止 Harbor 的 Xray")
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

            groupButton("全部节点", icon: "square.stack.3d.up", count: proxy.nodes.count,
                        selected: groupID == nil && !favoritesOnly) {
                groupID = nil
                favoritesOnly = false
                resetFilters()
            }
            groupButton("我的收藏", icon: "star", count: proxy.nodes.filter { favorites.contains($0.id) }.count,
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
            .scrollIndicators(.hidden)
            .frame(minHeight: 0, maxHeight: .infinity)

            if !proxy.coreInstalled {
                VStack(alignment: .leading, spacing: 7) {
                    Text(proxy.installingCore ? "正在恢复 Xray…" : "内置 Xray 尚未就绪")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                    Button {
                        Task { await proxy.installBundledXray() }
                    } label: {
                        Label(proxy.installingCore ? "恢复中…" : "从安装包恢复 Xray",
                              systemImage: "shippingbox")
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(proxy.busy || proxy.installingCore || proxy.requiresRecovery)
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
                Picker("代理路由", selection: $proxy.routingRules) {
                    Text("规则").tag(true)
                    Text("全局").tag(false)
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .frame(width: 83)
                .disabled(proxy.running)
                .help("规则：国内域名和 IP 直连，其余默认代理；全局：除局域网和私有 IP 外默认走代理。强制代理站点在两种模式中均优先，切换后下次连接生效。")
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
        let hovered = hoveredSubscriptionID == item.id
        let tint = subscriptionTints[index % subscriptionTints.count]
        let members = proxy.nodes.filter { $0.subscriptionID == item.id }
        let count = members.count
        let usable = members.filter { proxy.probeResults[$0.id]?.succeeded == true }.count

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
                        Text("\(count) 候选 · \(usable) 可用")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if let updated = proxy.subscriptionUpdatedAt[item.id] {
                        Text(updated.formatted(date: .omitted, time: .shortened) + " 更新")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else {
                        Text("\(count) 个节点")
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
            .padding(.horizontal, 10)
            .frame(maxWidth: .infinity, minHeight: 61)
            .contentShape(RoundedRectangle(cornerRadius: 9))
            .background(selected ? HarborColors.blue.opacity(0.085)
                : (hovered ? HarborColors.blue.opacity(0.055) : .clear),
                in: RoundedRectangle(cornerRadius: 9))
            .overlay(alignment: .leading) {
                if selected {
                    Capsule().fill(HarborColors.blue)
                        .frame(width: 2, height: 41)
                }
            }
        }
        .buttonStyle(.plain)
        .onHover { hovering in
            if hovering { hoveredSubscriptionID = item.id }
            else if hoveredSubscriptionID == item.id { hoveredSubscriptionID = nil }
        }
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
                    let count = choice == .all ? sourceGroupNodes.count
                        : sourceGroupNodes.filter { categoryOf($0) == choice }.count
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
        .scrollIndicators(.hidden)
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
                        ? categoryNodes.count
                        : categoryNodes.filter { location(of: $0) == name }.count
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
        .scrollIndicators(.hidden)
        .help("在地区栏上滚动鼠标滚轮，可查看更多地区")
        .frame(minWidth: 0, maxWidth: .infinity)
    }

    private func regionActions(narrow: Bool, compact: Bool) -> some View {
        HStack(spacing: 5) {
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
                .help("重新获取 VPN Gate 志愿候选，识别家宽入口并真实测速；不会自动切换节点")
            }
            if currentGroupIsTesting {
                Button { proxy.cancelLatencyTests() } label: {
                    Label("停止 \(proxy.latencyCompleted)/\(proxy.latencyTotal)",
                          systemImage: "stop.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.orange, prominence: .secondary))
            } else {
                Button {
                    Task { await proxy.testRealLatency(sourceGroupNodes.map(\.id)) }
                } label: {
                    Label("测速", systemImage: "speedometer")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.green, prominence: .secondary))
                .disabled(sourceGroupNodes.isEmpty || proxy.busy || proxy.latencyTesting
                          || !sourceGroupNodes.allSatisfy({ proxy.supportsCore(for: $0) }))
                .help(proxy.latencyTesting
                      ? "其他订阅正在测速；切回该订阅可查看进度或停止"
                      : "通过独立代理内核的 SOCKS5 发起真实请求；不改变当前节点或系统代理")
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
            .disabled(!proxy.running || !proxy.healthy || proxy.busy
                      || proxy.websiteChecking || proxy.checkingConnectivity)
            .help("通过当前实际 SOCKS5 出口检查 YouTube 和 ChatGPT 的 HTTPS 返回码；不切换节点")

            Button {
                proxy.refreshExitLocations(for: sourceGroupNodes.map(\.id))
            } label: {
                Label(proxy.exitGeoUpdating
                      ? "识别 \(proxy.exitGeoCompleted)/\(proxy.exitGeoTotal)"
                      : (compact ? "出口地区" : "更新出口地区"), systemImage: "globe.americas")
                    .font(.system(size: 10.5, weight: .medium))
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(sourceGroupNodes.isEmpty || proxy.busy || proxy.latencyTesting
                      || proxy.exitGeoUpdating
                      || !sourceGroupNodes.allSatisfy({ proxy.supportsCore(for: $0) }))
            .help("独立检测普通网站看到的出口 IP，并更新节点地区与自动名称；不重新测速")

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
        VStack(spacing: 0) {
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
                        if showRegion {
                            Text("地区").frame(width: 76, alignment: .leading)
                        }
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
                        Text("地区").frame(width: 76, alignment: .leading)
                    }
                    if compact {
                        Text("真实延迟")
                            .lineLimit(1)
                            .frame(width: 88, alignment: .leading)
                    } else {
                        Text("真实延迟").frame(width: 102, alignment: .leading)
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
                if visibleNodes.isEmpty {
                    VStack(spacing: 9) {
                        Image(systemName: "line.3.horizontal.decrease.circle")
                            .font(.system(size: 24, weight: .ultraLight))
                        Text(unavailableCount > 0 && !showUnavailable
                             ? "候选节点未通过真实测速，已暂时隐藏"
                             : (proxy.nodes.isEmpty ? "暂无节点，可添加公开候选来源"
                                : (groupID == nil && favoritesOnly && favorites.isEmpty
                                   ? "还没有收藏的节点" : "没有符合条件的节点")))
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
                        ForEach(visibleNodes) { node in gridCard(node).frame(height: cellHeight) }
                    }
                    .padding(9)
                    .frame(maxWidth: .infinity, minHeight: available.size.height, alignment: .top)
                } else {
                    LazyVStack(spacing: 2) {
                        ForEach(visibleNodes) { node in
                            row(node, compact: compact, showRegion: showRegion)
                        }
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                }
                }
                .scrollIndicators(.automatic)
            }
            .frame(minHeight: 0, maxHeight: .infinity)

            if !proxy.detail.isEmpty && !proxy.detail.contains("HTTP 127.0.0.1:") {
                Text(proxy.detail)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(proxy.detail)
                    .padding(.horizontal, 14)
                    .frame(height: 20, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            pagination
                .fixedSize(horizontal: false, vertical: true)
                .layoutPriority(2)
        }
        .frame(minHeight: 0, maxHeight: .infinity)
        .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HarborColors.cardBorder))
    }

    private func row(_ node: HarborProxyNode, compact: Bool, showRegion: Bool) -> some View {
        let active = proxy.activeNodeID == node.id && proxy.running
        let connected = active && proxy.healthy
        let probe = proxy.probeResults[node.id]
        let delay = probe?.milliseconds
        let connecting = visibleSwitchingNodeID == node.id
        let previewed = previewNodeID == node.id
        let rowBackground: Color = connected ? HarborColors.green.opacity(0.105)
            : ((active || connecting) ? HarborColors.orange.opacity(0.07)
               : ((previewed || hoveredNodeID == node.id) ? HarborColors.blue.opacity(0.055) : .clear))
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
                        if showRegion {
                            HStack(spacing: 5) {
                                Text(regionFlag(node)).font(.system(size: 13))
                                Text(locationLabel(of: node)).lineLimit(1)
                            }
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                            .help(regionHint(node))
                        }
                    } else {
                        Text(node.displayName)
                            .font(.system(size: 11, weight: connected ? .semibold : .medium))
                            .foregroundStyle(connected ? HarborColors.green : .primary)
                            .lineLimit(1)
                            .truncationMode(.tail)
                            .frame(width: nodeNameColumnWidth, alignment: .leading)
                        if node.customName != nil {
                            Image(systemName: "pencil")
                                .font(.system(size: 8.5, weight: .medium))
                                .foregroundStyle(.secondary)
                                .help("这是自定义节点名称；右键可修改或恢复订阅名称")
                        }
                        Text("\(categoryOf(node).rawValue) · \(node.host)")
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            Text(regionFlag(node)).font(.system(size: 13))
                            Text(locationLabel(of: node)).lineLimit(1)
                                .help(regionHint(node))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                    }
                    if compact {
                        Text(realLatencyText(
                            delay: delay, probe: probe, connected: connected,
                            connecting: connecting, nodeID: node.id,
                            isOpenVPN: node.protocolName == "openvpn"))
                        .font(.system(size: 9.2, weight: .medium))
                        .monospacedDigit()
                        .foregroundStyle(realLatencyTextColor(
                            delay: delay, probe: probe, connected: connected,
                            connecting: connecting, nodeID: node.id))
                        .lineLimit(1)
                        .help(probe?.realFailureReason ?? "真实代理请求延迟")
                        .frame(width: 88, alignment: .leading)
                    } else {
                        Text(realLatencyText(
                            delay: delay, probe: probe, connected: connected,
                            connecting: connecting, nodeID: node.id,
                            isOpenVPN: node.protocolName == "openvpn"))
                            .font(.system(size: 10.3, weight: connected || delay != nil ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(realLatencyTextColor(
                                delay: delay, probe: probe, connected: connected,
                                connecting: connecting, nodeID: node.id))
                            .lineLimit(1)
                            .help(probe?.realFailureReason ?? "真实代理请求延迟")
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
        .background(rowBackground, in: RoundedRectangle(cornerRadius: 8))
        .onHover { hovering in
            if hovering { hoveredNodeID = node.id }
            else if hoveredNodeID == node.id { hoveredNodeID = nil }
        }
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

    private func gridCard(_ node: HarborProxyNode) -> some View {
        let active = proxy.activeNodeID == node.id && proxy.running
        let connected = active && proxy.healthy
        let connecting = visibleSwitchingNodeID == node.id
        let probe = proxy.probeResults[node.id]
        let delay = probe?.milliseconds
        let previewed = previewNodeID == node.id
        let cardBackground: Color = connected ? HarborColors.green.opacity(0.105)
            : ((active || connecting) ? HarborColors.orange.opacity(0.07)
               : ((previewed || hoveredNodeID == node.id)
                  ? HarborColors.blue.opacity(0.055) : Color.primary.opacity(0.018)))
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
                    Text("\(categoryOf(node).rawValue) · \(node.host)")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text("\(regionFlag(node)) \(locationLabel(of: node))")
                            .help(regionHint(node))
                        Spacer(minLength: 2)
                        Text(realLatencyText(
                            delay: delay, probe: probe, connected: connected,
                            connecting: connecting, nodeID: node.id,
                            isOpenVPN: node.protocolName == "openvpn"))
                            .lineLimit(1)
                            .font(.system(size: 10.5, weight: delay == nil ? .regular : .semibold))
                            .monospacedDigit()
                            .foregroundStyle(realLatencyTextColor(
                                delay: delay, probe: probe, connected: connected,
                                connecting: connecting, nodeID: node.id))
                            .help(probe?.realFailureReason ?? "真实代理请求延迟")
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
            VStack(spacing: 2) {
                Button {
                    toggleFavorite(node.id)
                } label: {
                    Image(systemName: favorites.contains(node.id) ? "star.fill" : "star")
                        .foregroundStyle(favorites.contains(node.id) ? HarborColors.orange : Color.secondary)
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.orange))
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
        .background(cardBackground, in: RoundedRectangle(cornerRadius: 10))
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
        .onHover { hovering in
            if hovering { hoveredNodeID = node.id }
            else if hoveredNodeID == node.id { hoveredNodeID = nil }
        }
    }

    @ViewBuilder
    private func nodeNameActions(_ node: HarborProxyNode) -> some View {
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

    private var pagination: some View {
        HStack(spacing: 4) {
            Text("共 \(shownNodes.count) 条")
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
                            .frame(width: 27, height: 27)
                            .background(value == currentPage ? HarborColors.blue : .clear,
                                        in: RoundedRectangle(cornerRadius: 7))
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

    private var pageChoices: [Int] {
        if maxPage <= 5 { return Array(1...maxPage) }
        let middle = min(max(2, currentPage), maxPage - 1)
        var values = [1]
        if middle > 2 { values.append(0) }
        if middle != 1 && middle != maxPage { values.append(middle) }
        if middle < maxPage - 1 { values.append(0) }
        values.append(maxPage)
        return values
    }

    private func pageButton(_ icon: String, to index: Int) -> some View {
        Button { page = index } label: {
            Image(systemName: icon)
                .font(.system(size: 10))
                .frame(width: 24, height: 27)
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
                                 connected: Bool, connecting: Bool, nodeID: String,
                                 isOpenVPN: Bool) -> String {
        if connecting { return "切换中" }
        if proxy.latencyTestingIDs.contains(nodeID) {
            return "测速中"
        }
        if let delay {
            return "\(delay) ms" + (probe?.isStale() == true ? " · 旧" : "")
        }
        guard probe?.realTested == true else { return "未测速" }
        if isOpenVPN, let reason = probe?.realFailureReason {
            if reason.contains("握手") { return "握手超时" }
            if reason.contains("HTTPS") { return "出口验证失败" }
            if reason.contains("Mihomo") { return "内核启动失败" }
        }
        return probe?.isConfirmedUnavailable == true ? "不可用" : "待复测"
    }

    private func realLatencyTextColor(delay: Int?, probe: HarborProxyProbeResult?,
                                      connected: Bool, connecting: Bool, nodeID: String) -> Color {
        if connecting { return HarborColors.orange }
        if proxy.latencyTestingIDs.contains(nodeID) {
            return HarborColors.orange
        }
        if let delay { return latencyColor(delay) }
        guard probe?.realTested == true else { return Color.secondary }
        return probe?.isConfirmedUnavailable == true ? HarborColors.red : HarborColors.orange
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
                ?? HarborProxyIPLocation(ip: node.host, countryCode: node.path).flag
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

    private func location(of node: HarborProxyNode) -> String {
        if node.protocolName == "openvpn" {
            return proxy.exitLocation(for: node)?.displayRegion
                ?? HarborProxyIPLocation(ip: node.host, countryCode: node.path).displayRegion
        }
        if categoryOf(node) == .residential {
            return proxy.exitLocation(for: node)?.displayRegion
                ?? HarborProxyAutomaticName.unresolvedRegion
        }
        return proxy.serverLocation(for: node)?.displayRegion
            ?? HarborProxyAutomaticName.unresolvedRegion
    }

    private func locationLabel(of node: HarborProxyNode) -> String {
        let region = location(of: node)
        if node.protocolName == "openvpn", proxy.exitLocation(for: node) == nil {
            return region + "·来源"
        }
        guard region != HarborProxyAutomaticName.unresolvedRegion,
              proxy.exitLocation(for: node) == nil else { return region }
        return region + "·入口"
    }

    private func regionHint(_ node: HarborProxyNode) -> String {
        if let exit = proxy.exitLocation(for: node) {
            return "普通网站检测到的出口 IP：\(exit.ip) · 优先显示出口地区"
        }
        if node.protocolName == "openvpn" {
            return "VPN Gate 发布者报告的地区：\(location(of: node))；实际出口尚未确认"
        }
        if categoryOf(node) == .residential {
            return "住宅候选节点的实际出口尚未确认；识别前不按入口地区筛选"
        }
        if let location = proxy.serverLocation(for: node) {
            if location.countryCode == "ZZ" {
                return "节点服务器 IP：\(location.ip) · 正在识别归属地"
            }
            return "节点服务器 IP：\(location.ip) · 出口未确认，使用服务器地区"
        }
        return "出口 IP 尚未确认；将独立识别，失败时使用服务器 IP 地区"
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
                .disabled(subscriptionSaving || portUpdating)
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
                VStack(alignment: .leading, spacing: 7) {
                    TextField("HTTP 端口（例如 18080）", text: $listenPortText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13, design: .monospaced))
                        .frame(height: 38)
                        .accessibilityLabel("HTTP 代理监听端口")
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
                    .disabled(subscriptionSaving || portUpdating)
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
                            let reconnectID = changed && proxy.running ? proxy.selectedID : nil
                            editor = nil
                            if let reconnectID {
                                Task { await proxy.select(reconnectID) }
                            }
                        } catch {
                            forcedDomainError = error.localizedDescription
                        }
                    } label: {
                        Text("保存规则")
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(proxy.busy || proxy.latencyTesting)
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
                            subscriptionSaving = true
                            subscriptionError = nil
                            Task {
                                let saved = await proxy.updateSubscription(id, name: name, url: url)
                                subscriptionSaving = false
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
                            proxy.addLinks(nodeLinks)
                            nodeLinks = ""
                        }
                        editor = nil
                    } label: {
                        HStack(spacing: 7) {
                            if mode == .editSubscription && subscriptionSaving {
                                ProgressView().controlSize(.small)
                            }
                            Text(mode == .editSubscription
                                 ? (subscriptionSaving ? "正在更新节点…" : "保存订阅")
                                 : (mode == .subscription ? "添加订阅" : "导入节点"))
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(HarborActionButtonStyle(
                        tint: .blue, prominence: .prominent))
                    .disabled((mode == .subscription || mode == .editSubscription)
                              ? (subscriptionName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 || subscriptionURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                 || subscriptionSaving || proxy.busy || proxy.latencyTesting)
                              : nodeLinks.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
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
            if !subscriptionSaving && !portUpdating { editor = nil }
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

/// SwiftUI's hidden indicator can still leave a visible NSScroller when the
/// macOS preference is "Always". Keep the horizontal content scrollable and
/// translate vertical wheel motion only while the pointer is over this bar.
private struct HarborHorizontalWheelBridge: NSViewRepresentable {
    func makeNSView(context: Context) -> WheelView { WheelView() }
    func updateNSView(_ nsView: WheelView, context: Context) { nsView.hideScroller() }

    final class WheelView: NSView {
        nonisolated(unsafe) private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor); self.monitor = nil }
            guard window != nil else { return }
            hideScroller()
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, let scroll = enclosingScrollView,
                      event.window === window,
                      abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
                      let document = scroll.documentView else { return event }
                let clip = scroll.contentView
                let point = clip.convert(event.locationInWindow, from: nil)
                guard clip.bounds.contains(point) else { return event }
                let maxX = max(0, document.frame.width - clip.bounds.width)
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 20
                let nextX = min(maxX, max(0, clip.bounds.origin.x - event.scrollingDeltaY * step))
                guard nextX != clip.bounds.origin.x else { return event }
                clip.scroll(to: NSPoint(x: nextX, y: clip.bounds.origin.y))
                scroll.reflectScrolledClipView(clip)
                return nil
            }
        }

        func hideScroller() {
            enclosingScrollView?.hasHorizontalScroller = false
        }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
