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
    @State private var region = "全部"
    @State private var protocolFilter = "全部"
    @State private var latencyFilter = "全部"
    @State private var latencyAscending: Bool? = nil
    @State private var latencySortMetric: HarborProxyLatencyTestKind = .real
    @State private var page = 1
    @State private var pageSize = 10
    @State private var gridMode = false
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
    @State private var deletionTargetID: DeletionTarget?
    @State private var renameTarget: RenameTarget?
    @State private var renameText = ""
    @AppStorage("com.codexharbor.proxy.nodeNameColumnWidth")
    private var nodeNameColumnWidth = 230.0
    @State private var nodeNameDragStart: Double?
    @FocusState private var nodeSearchFocused: Bool

    private struct DeletionTarget: Identifiable { let id: String }
    private struct RenameTarget: Identifiable { let id: String }

    private enum Editor: String, Identifiable {
        case subscription, editSubscription, links, importChoice, routing, ports
        var id: String { rawValue }
    }

    private let favoritesKey = "com.codexharbor.proxy.favoriteNodeIDs"
    private let subscriptionTints: [Color] = [
        HarborColors.blue, HarborColors.green, HarborColors.orange, HarborColors.purple
    ]

    private var groupNodes: [HarborProxyNode] {
        proxy.nodes.filter { node in
            if let groupID { return node.subscriptionID == groupID }
            return favorites.contains(node.id)
        }
    }

    private var shownNodes: [HarborProxyNode] {
        var result = groupNodes.filter { node in
            if region != "全部" && location(of: node) != region { return false }
            if protocolFilter != "全部" && node.protocolName.uppercased() != protocolFilter { return false }
            if latencyFilter != "全部" {
                guard let delay = proxy.probeResults[node.id]?.milliseconds else { return false }
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
        if let ascending = latencyAscending {
            let position = Dictionary(uniqueKeysWithValues: result.enumerated().map { ($0.element.id, $0.offset) })
            result.sort { a, b in
                let x = latencySortMetric == .tcp
                    ? proxy.probeResults[a.id]?.tcpMilliseconds
                    : proxy.probeResults[a.id]?.milliseconds
                let y = latencySortMetric == .tcp
                    ? proxy.probeResults[b.id]?.tcpMilliseconds
                    : proxy.probeResults[b.id]?.milliseconds
                switch (x, y) {
                case let (lhs?, rhs?) where lhs != rhs: return ascending ? lhs < rhs : lhs > rhs
                case (_?, nil): return true
                case (nil, _?): return false
                default: return (position[a.id] ?? 0) < (position[b.id] ?? 0)
                }
            }
        }
        return result
    }
    private var maxPage: Int { max(1, (shownNodes.count + pageSize - 1) / pageSize) }
    private var currentPage: Int { min(max(1, page), maxPage) }
    private var visibleNodes: [HarborProxyNode] {
        Array(shownNodes.dropFirst((currentPage - 1) * pageSize).prefix(pageSize))
    }
    private var title: String {
        if let groupID { return proxy.subscriptions.first(where: { $0.id == groupID })?.name ?? "订阅节点" }
        return "我的收藏"
    }
    private var protocols: [String] {
        ["全部"] + Array(Set(groupNodes.map { $0.protocolName.uppercased() })).sorted()
    }
    private var regions: [String] {
        let actual = Set(groupNodes.map(location))
        let priority = ["香港", "美国", "日本", "新加坡", "台湾", "德国", "韩国", "英国"]
        return ["全部"] + priority.filter(actual.contains)
            + actual.subtracting(Set(priority)).sorted()
    }

    var body: some View {
        GeometryReader { geometry in
            VStack(alignment: .leading, spacing: 9) {
                header
                    .frame(height: 42)
                currentNode
                    .frame(height: 68)
                HStack(alignment: .top, spacing: 11) {
                    subscriptionSidebar
                        .frame(width: min(300, max(220, geometry.size.width * 0.22)))
                    nodeTable(compact: HarborProxyTableSizing.usesCompactRows(
                        workspaceWidth: Double(geometry.size.width)
                    ))
                        .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(minHeight: 0, maxHeight: .infinity)
                .layoutPriority(1)
            }
            .padding(.horizontal, geometry.size.width < 850 ? 16 : 22)
            .padding(.top, 3)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .task { await proxy.bootstrap() }
        .onAppear {
            favorites = Set(UserDefaults.standard.stringArray(forKey: favoritesKey) ?? [])
            if groupID == nil && !favoritesOnly {
                groupID = proxy.subscriptions.first?.id
                favoritesOnly = groupID == nil
            }
        }
        .onChange(of: proxy.subscriptions.map(\.id)) { _, ids in
            if let groupID, !ids.contains(groupID) {
                self.groupID = ids.first
                favoritesOnly = ids.isEmpty
                resetFilters()
            } else if self.groupID == nil && !favoritesOnly {
                self.groupID = ids.first
                favoritesOnly = ids.isEmpty
            }
        }
        .onChange(of: keyword) { _, _ in page = 1 }
        .onChange(of: region) { _, _ in page = 1 }
        .onChange(of: protocolFilter) { _, _ in page = 1 }
        .onChange(of: latencyFilter) { _, _ in page = 1 }
        .onChange(of: latencyAscending) { _, _ in page = 1 }
        .onChange(of: proxy.latencyCompletionSerial) { _, _ in
            guard let kind = proxy.lastCompletedLatencyTestKind else { return }
            latencySortMetric = kind
            latencyAscending = true
            page = 1
        }
        .onChange(of: pageSize) { _, _ in page = 1 }
        .onChange(of: proxy.localPort) { _, _ in copiedProxyURL = nil }
        .onChange(of: proxy.nodeServerLocations) { _, _ in
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
                let inUse = proxy.running && proxy.selectedNode?.subscriptionID == id
                HarborDestructiveConfirmDialog(
                    title: "删除订阅「\(subscription.name)」？",
                    message: inUse
                        ? "该订阅正在提供当前代理连接，请先清理代理，再删除订阅。"
                        : "这将从 CodexHarbor 中移除该订阅及其 \(count) 个节点，不会删除 v2rayN 中的原始配置。",
                    confirmTitle: inUse ? "返回" : "删除订阅",
                    onCancel: { deletionTargetID = nil },
                    onConfirm: {
                        if !inUse { _ = proxy.removeSubscription(id) }
                        deletionTargetID = nil
                    }
                )
            }
        }
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

    /// The header represents what is *actually* active, not a saved selection.
    /// A configured-but-idle node must never be labeled as an active proxy.
    private var proxyStateColor: Color {
        if proxy.requiresRecovery { return HarborColors.red }
        if proxy.switchingNodeID != nil { return HarborColors.orange }
        if proxy.running && !proxy.healthy { return HarborColors.orange }
        if proxy.running && proxy.systemManaged { return HarborColors.green }
        if proxy.running { return HarborColors.blue }
        if proxy.busy { return HarborColors.orange }
        return .secondary
    }

    private var proxyStateTitle: String {
        if proxy.requiresRecovery { return "系统代理等待恢复" }
        if proxy.switchingNodeID != nil { return "正在切换节点…" }
        if proxy.running && proxy.checkingConnectivity { return "代理已启动 · 检测网络中" }
        if proxy.running && !proxy.healthy { return "代理连接异常" }
        if proxy.running && proxy.systemManaged { return "正在使用代理" }
        if proxy.running { return "本地代理已连接" }
        if proxy.busy { return "正在处理代理…" }
        return "未使用 Harbor 代理"
    }

    private var proxyStateSubtitle: String {
        if proxy.requiresRecovery { return "请先恢复系统代理设置，避免网络异常" }
        if proxy.switchingNodeID != nil { return "正在准备新节点，仍可继续选择其他节点" }
        if proxy.running && proxy.checkingConnectivity {
            return "HTTP/SOCKS5 端口已就绪，正在后台检测节点连通性"
        }
        if proxy.running && !proxy.healthy { return "内核已启动，但连通性检查未通过" }
        if proxy.running && proxy.systemManaged {
            return proxy.selectedNode.map { "系统代理已接管 · \($0.displayName)" } ?? "系统代理已接管"
        }
        if proxy.running {
            if proxy.detail.hasPrefix("本地节点已连接，但系统代理未接管") {
                return proxy.detail
            }
            return proxy.selectedNode.map { "节点 \($0.displayName) 已连接 · 未接管 macOS 系统代理" }
                ?? "内核已连接 · 未接管系统代理"
        }
        if proxy.busy { return "操作正在后台执行，页面仍可浏览" }
        if let node = proxy.selectedNode { return "上次选择：\(node.displayName) · 点击下方节点重新连接" }
        return "点击下方的订阅节点选择并连接"
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
                    Circle()
                        .fill(proxyStateColor)
                        .frame(width: 7, height: 7)
                    Text(proxyStateTitle)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    if proxy.running, let node = proxy.selectedNode,
                       let latency = proxy.probeResults[node.id]?.milliseconds {
                        Text("延迟 " + HarborProxyMeasurementLabel.measured(latency))
                            .font(.system(size: 10, weight: .medium))
                            .monospacedDigit()
                            .foregroundStyle(latencyColor(latency))
                            .padding(.horizontal, 8)
                            .frame(height: 21)
                            .background(latencyColor(latency).opacity(0.09), in: Capsule())
                            .help(HarborProxyMeasurementLabel.explanation
                                  + " · 检测于 "
                                  + (proxy.probeResults[node.id]?.checkedAt.formatted(
                                      date: .abbreviated, time: .shortened
                                  ) ?? "未知"))
                    }
                }
                Text(proxyStateSubtitle)
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
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
                    Task { await proxy.clearProxy() }
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
                Spacer(minLength: 0)
                Button {
                    editor = .importChoice
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 30, height: 30)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                .help("新增订阅或节点")
                .accessibilityLabel("新增订阅或节点链接")
                Button {
                    if let groupID,
                       let item = proxy.subscriptions.first(where: { $0.id == groupID }) {
                        beginEditingSubscription(item)
                    }
                } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 30)
                }
                .disabled(groupID == nil || proxy.busy || proxy.latencyTesting)
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                .help(groupID == nil ? "先在左侧选择要编辑的订阅"
                      : (proxy.busy || proxy.latencyTesting
                         ? "请等待当前代理操作完成" : "编辑选中订阅的名称与链接"))
                .accessibilityLabel("编辑当前订阅")
                Button {
                    if let groupID {
                        Task { await proxy.refreshSubscription(groupID) }
                    }
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11, weight: .semibold))
                        .frame(width: 28, height: 30)
                }
                .disabled(groupID == nil || proxy.busy || proxy.latencyTesting)
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                .help(groupID == nil ? "请先选择需要更新的订阅"
                      : (proxy.busy || proxy.latencyTesting
                         ? "请等待当前代理操作完成" : "更新选中订阅的节点"))
                .accessibilityLabel("刷新当前订阅")
                Button {
                    if let groupID { deletionTargetID = DeletionTarget(id: groupID) }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 11.5, weight: .semibold))
                        .frame(width: 28, height: 30)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                .disabled(groupID == nil || proxy.busy || proxy.latencyTesting)
                .help(groupID == nil ? "先选择需要删除的订阅" : "删除当前选中的订阅")
                .accessibilityLabel("删除当前订阅")
            }
            .padding(.horizontal, 15)
            .padding(.top, 13)
            .padding(.bottom, 3)

            // The navigation intentionally contains no “全部节点” category.
            groupButton("我的收藏", icon: "star", count: proxy.nodes.filter { favorites.contains($0.id) }.count,
                        selected: groupID == nil) {
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
        let count = proxy.nodes.filter { $0.subscriptionID == item.id }.count

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
                    if let updated = proxy.subscriptionUpdatedAt[item.id] {
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
            Button("更新订阅") { Task { await proxy.refreshSubscription(item.id) } }
                .disabled(proxy.busy || proxy.latencyTesting)
            Button("删除订阅", role: .destructive) {
                deletionTargetID = DeletionTarget(id: item.id)
            }
        }
    }

    // One compact row replaces the previous dedicated filter panel.
    private var regionBar: some View {
        HStack(spacing: 7) {
            ScrollView(.horizontal) {
                HStack(spacing: 2) {
                    ForEach(regions, id: \.self) { name in
                        let selected = region == name
                        let count = name == "全部"
                            ? groupNodes.count
                            : groupNodes.filter { location(of: $0) == name }.count
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
                .padding(.leading, 10)
            }
            .scrollIndicators(.hidden)
            .frame(minWidth: 0, maxWidth: .infinity)

            if proxy.latencyTesting {
                Button { proxy.cancelLatencyTests() } label: {
                    Label("停止 \(proxy.latencyCompleted)/\(proxy.latencyTotal)",
                          systemImage: "stop.circle")
                        .font(.system(size: 10.5, weight: .medium))
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.orange, prominence: .secondary))
            } else {
                HStack(spacing: 6) {
                    Button {
                        Task { await proxy.testTCPLatency(visibleNodes.map(\.id)) }
                    } label: {
                        Label("TCP 测速", systemImage: "dot.radiowaves.left.and.right")
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(visibleNodes.isEmpty || proxy.busy)
                    .help("仅测试节点服务器端口的 TCP 握手，不代表代理可用")

                    Button {
                        Task { await proxy.testRealLatency(visibleNodes.map(\.id)) }
                    } label: {
                        Label("真实测速", systemImage: "speedometer")
                            .font(.system(size: 10.5, weight: .medium))
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.green, prominence: .secondary))
                    .disabled(visibleNodes.isEmpty || proxy.busy || !proxy.coreInstalled)
                    .help("通过独立 Xray 完成 HTTPS 请求；不改变当前节点或系统代理")
                }
            }

            if gridMode {
                latencySortButton(for: latencySortMetric)
                    .frame(width: 96)
            }

            HStack(spacing: 2) {
                modeButton("list.bullet", selected: !gridMode) { gridMode = false }
                modeButton("square.grid.2x2", selected: gridMode) { gridMode = true }
            }
            .padding(2)
            .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 8))
            .padding(.trailing, 10)
        }
        .frame(height: 40)
    }

    private func latencySortButton(for kind: HarborProxyLatencyTestKind) -> some View {
        let selected = latencySortMetric == kind && latencyAscending != nil
        return Button {
            if selected {
                latencyAscending = !(latencyAscending ?? false)
            } else {
                latencySortMetric = kind
                latencyAscending = true
            }
            page = 1
        } label: {
            HStack(spacing: 3) {
                Text(kind == .tcp ? "TCP 延迟" : "真实延迟")
                    .lineLimit(1)
                    .fixedSize(horizontal: true, vertical: false)
                Image(systemName: !selected ? "arrow.up.arrow.down"
                      : (latencyAscending == true ? "arrow.up" : "arrow.down"))
                    .font(.system(size: 9, weight: .semibold))
            }
            .font(.system(size: 10.5, weight: selected ? .semibold : .medium))
            .frame(height: 32, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
        .help(kind == .tcp ? "按 TCP 握手延迟排序（不能证明代理可用）"
              : "按真实 HTTPS 延迟排序；节点名称中的 ms 并非本机测试结果")
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
    }

    /// Only node content scrolls. Controls and pagination stay in view at any
    /// supported window height; there is no outer page scrolling.
    private func nodeTable(compact: Bool) -> some View {
        VStack(spacing: 0) {
            regionBar
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
                        Text("地址")
                            .lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("地区").frame(width: 76, alignment: .leading)
                    }
                    if compact {
                        Text("TCP / 真实")
                            .lineLimit(1)
                            .frame(width: 88, alignment: .leading)
                    } else {
                        latencySortButton(for: .tcp).frame(width: 68, alignment: .leading)
                        latencySortButton(for: .real).frame(width: 96, alignment: .leading)
                    }
                    Image(systemName: "dot.radiowaves.left.and.right").frame(width: 26)
                        .help("单节点 TCP 测速")
                        .accessibilityLabel("TCP 测速")
                    Image(systemName: "speedometer").frame(width: 26)
                        .help("单节点真实测速")
                        .accessibilityLabel("真实测速")
                    Image(systemName: "star").frame(width: 29)
                        .help("收藏节点")
                        .accessibilityLabel("收藏")
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
                        Text(proxy.nodes.isEmpty ? "暂无节点，请先导入订阅"
                             : (groupID == nil && favorites.isEmpty ? "还没有收藏的节点"
                             : "没有符合条件的节点"))
                            .font(.system(size: 11))
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
                        ForEach(visibleNodes) { node in row(node, compact: compact) }
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

    private func row(_ node: HarborProxyNode, compact: Bool) -> some View {
        let active = proxy.selectedID == node.id && proxy.running
        let connected = active && proxy.healthy
        let probe = proxy.probeResults[node.id]
        let delay = probe?.milliseconds
        let tcpDelay = probe?.tcpMilliseconds
        let connecting = proxy.switchingNodeID == node.id
        return HStack(spacing: 10) {
            Button {
                Task { await proxy.activate(node.id) }
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
                                Text(node.host)
                                    .truncationMode(.middle)
                                    .lineLimit(1)
                                Text(regionFlag(node))
                            }
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
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
                        Text(node.host)
                            .font(.system(size: 9.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        HStack(spacing: 5) {
                            Text(regionFlag(node)).font(.system(size: 13))
                            Text(location(of: node)).lineLimit(1)
                                .help(regionHint(node))
                        }
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                            .frame(width: 76, alignment: .leading)
                    }
                    if compact {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("TCP " + (tcpDelay.map { "\($0)ms" }
                                 ?? (proxy.latencyTestingIDs.contains(node.id)
                                     && proxy.latencyTestKind == .tcp ? "测速中" : "--")))
                                .foregroundStyle(tcpDelay.map(tcpLatencyColor) ?? Color.secondary)
                            Text("真实 " + realLatencyText(
                                delay: delay, probe: probe, connected: connected,
                                connecting: connecting, nodeID: node.id))
                                .foregroundStyle(realLatencyTextColor(
                                    delay: delay, probe: probe, connected: connected,
                                    connecting: connecting, nodeID: node.id))
                        }
                        .font(.system(size: 9.2, weight: .medium))
                        .monospacedDigit()
                        .lineLimit(1)
                        .frame(width: 88, alignment: .leading)
                    } else {
                        Text(tcpDelay.map { "\($0) ms" }
                             ?? (proxy.latencyTestingIDs.contains(node.id)
                                 && proxy.latencyTestKind == .tcp ? "测速中"
                                 : (probe?.tcpTested == true ? "不可达" : "未测")))
                            .font(.system(size: 10.1, weight: tcpDelay == nil ? .regular : .medium))
                            .monospacedDigit()
                            .foregroundStyle(tcpDelay.map(tcpLatencyColor) ?? Color.secondary)
                            .lineLimit(1)
                            .frame(width: 68, alignment: .leading)
                        Text(realLatencyText(
                            delay: delay, probe: probe, connected: connected,
                            connecting: connecting, nodeID: node.id))
                            .font(.system(size: 10.3, weight: connected || delay != nil ? .semibold : .regular))
                            .monospacedDigit()
                            .foregroundStyle(realLatencyTextColor(
                                delay: delay, probe: probe, connected: connected,
                                connecting: connecting, nodeID: node.id))
                            .lineLimit(1)
                            .frame(width: 96, alignment: .leading)
                    }
                }
                .frame(height: compact ? 54 : 46)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("点击连接：\(node.displayName)。延迟为经过该节点的真实 HTTPS 请求耗时，右键可以重命名")
            .accessibilityLabel("连接节点：" + node.displayName)

            Button {
                Task { await proxy.testTCPLatency([node.id]) }
            } label: {
                Image(systemName: proxy.latencyTestingIDs.contains(node.id)
                      && proxy.latencyTestKind == .tcp ? "hourglass"
                      : "dot.radiowaves.left.and.right")
                    .font(.system(size: 11.5))
                    .foregroundStyle(proxy.latencyTestingIDs.contains(node.id)
                                     && proxy.latencyTestKind == .tcp
                                     ? HarborColors.orange : HarborColors.blue)
                    .frame(width: 26, height: 30)
            }
            .disabled(proxy.latencyTesting || proxy.busy)
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 7))
            .help("TCP 测速：只测试服务器端口握手")
            Button {
                Task { await proxy.testRealLatency([node.id]) }
            } label: {
                Image(systemName: proxy.latencyTestingIDs.contains(node.id)
                      && proxy.latencyTestKind == .real ? "hourglass" : "speedometer")
                    .font(.system(size: 11.5))
                    .foregroundStyle(proxy.latencyTestingIDs.contains(node.id)
                                     && proxy.latencyTestKind == .real
                                     ? HarborColors.orange : HarborColors.green)
                    .frame(width: 26, height: 30)
            }
            .disabled(proxy.latencyTesting || proxy.busy || !proxy.coreInstalled)
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.green, cornerRadius: 7))
            .help("真实测速：通过独立 Xray 发出 HTTPS 请求")
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
        }
        .padding(.horizontal, 8)
        .contentShape(RoundedRectangle(cornerRadius: 8))
        .background(
            connected ? HarborColors.green.opacity(0.105)
                : ((active || connecting) ? HarborColors.orange.opacity(0.07)
                   : (hoveredNodeID == node.id ? HarborColors.blue.opacity(0.055) : .clear)),
            in: RoundedRectangle(cornerRadius: 8))
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
                .stroke(connected ? HarborColors.green.opacity(0.34)
                        : ((active || connecting) ? HarborColors.orange.opacity(0.24) : .clear),
                        lineWidth: 1)
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
        let active = proxy.selectedID == node.id && proxy.running
        let connected = active && proxy.healthy
        let connecting = proxy.switchingNodeID == node.id
        let probe = proxy.probeResults[node.id]
        let delay = probe?.milliseconds
        let tcpDelay = probe?.tcpMilliseconds
        return HStack(alignment: .center, spacing: 6) {
            Button {
                Task { await proxy.activate(node.id) }
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
                    Text(node.host)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    HStack(spacing: 8) {
                        Text("\(regionFlag(node)) \(location(of: node))")
                            .help(regionHint(node))
                        Spacer(minLength: 2)
                        VStack(alignment: .trailing, spacing: 2) {
                            Text(tcpDelay.map { "TCP \($0) ms" }
                                 ?? (probe?.tcpTested == true ? "TCP 不可达" : "TCP 未测"))
                                .lineLimit(1)
                                .foregroundStyle(tcpDelay.map(tcpLatencyColor) ?? Color.secondary)
                            Text(delay.map { "真实 \($0) ms" }
                                 ?? (probe?.realTested == true ? "真实不可用" : "真实未测"))
                                .lineLimit(1)
                                .font(.system(size: 10.5, weight: delay == nil ? .regular : .semibold))
                                .monospacedDigit()
                                .foregroundStyle(delay.map(latencyColor) ?? Color.secondary)
                        }
                    }
                    .font(.system(size: 9.5))
                }
                .padding(.leading, 11)
                .padding(.vertical, 9)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
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
                    Task { await proxy.testTCPLatency([node.id]) }
                } label: {
                    Image(systemName: proxy.latencyTestingIDs.contains(node.id)
                          && proxy.latencyTestKind == .tcp ? "hourglass"
                          : "dot.radiowaves.left.and.right")
                        .foregroundStyle(HarborColors.blue)
                        .frame(width: 27, height: 27)
                }
                .disabled(proxy.latencyTesting || proxy.busy)
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 7))
                .help("TCP 测速：只测试服务器端口握手")
                Button {
                    Task { await proxy.testRealLatency([node.id]) }
                } label: {
                    Image(systemName: proxy.latencyTestingIDs.contains(node.id)
                          && proxy.latencyTestKind == .real ? "hourglass" : "speedometer")
                        .foregroundStyle(HarborColors.green)
                        .frame(width: 27, height: 27)
                }
                .disabled(proxy.latencyTesting || proxy.busy || !proxy.coreInstalled)
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.green, cornerRadius: 7))
                .help("真实测速：通过独立 Xray 发出 HTTPS 请求")
            }
        }
        .padding(.trailing, 8)
        .contentShape(RoundedRectangle(cornerRadius: 10))
        .background(
            connected ? HarborColors.green.opacity(0.105)
                : ((active || connecting) ? HarborColors.orange.opacity(0.07)
                   : (hoveredNodeID == node.id
                      ? HarborColors.blue.opacity(0.055) : Color.primary.opacity(0.018))),
            in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10)
            .stroke(connected ? HarborColors.green.opacity(0.36)
                    : ((active || connecting) ? HarborColors.orange.opacity(0.25)
                       : HarborColors.cardBorder)))
        .overlay(alignment: .leading) {
            if connected {
                Capsule().fill(HarborColors.green).frame(width: 3, height: 30)
            }
        }
        .contextMenu { nodeNameActions(node) }
        .help("点击连接：\(node.displayName)；右键可重命名")
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
                Label("恢复订阅名称", systemImage: "arrow.uturn.backward")
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

    private func tcpLatencyColor(_ milliseconds: Int) -> Color {
        if milliseconds < 200 { return HarborColors.green }
        if milliseconds < 500 { return HarborColors.orange }
        return HarborColors.red
    }

    private func realLatencyText(delay: Int?, probe: HarborProxyProbeResult?,
                                 connected: Bool, connecting: Bool, nodeID: String) -> String {
        if connecting { return "切换中" }
        if proxy.latencyTestingIDs.contains(nodeID), proxy.latencyTestKind == .real {
            return "测速中"
        }
        if let delay { return "\(delay) ms" }
        return probe?.realTested == true ? "不可用" : "未测"
    }

    private func realLatencyTextColor(delay: Int?, probe: HarborProxyProbeResult?,
                                      connected: Bool, connecting: Bool, nodeID: String) -> Color {
        if connecting { return HarborColors.orange }
        if proxy.latencyTestingIDs.contains(nodeID), proxy.latencyTestKind == .real {
            return HarborColors.orange
        }
        if let delay { return latencyColor(delay) }
        return probe?.realTested == true ? HarborColors.red : Color.secondary
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
        if let location = proxy.serverLocation(for: node) { return location.flag }
        return switch HarborProxyRegion.infer(from: node.name) {
        case .hongKong: "🇭🇰"
        case .unitedStates: "🇺🇸"
        case .japan: "🇯🇵"
        case .singapore: "🇸🇬"
        case .taiwan: "🇹🇼"
        case .germany: "🇩🇪"
        case .unitedKingdom: "🇬🇧"
        case .korea: "🇰🇷"
        case .other: "🌐"
        }
    }

    private func resetFilters() {
        page = 1
        region = "全部"
        protocolFilter = "全部"
        latencyFilter = "全部"
    }

    private func location(of node: HarborProxyNode) -> String {
        proxy.serverLocation(for: node)?.countryName
            ?? HarborProxyRegion.infer(from: node.name).rawValue
    }

    private func regionHint(_ node: HarborProxyNode) -> String {
        if let location = proxy.serverLocation(for: node) {
            return "节点服务器 IP：\(location.ip) · IP 归属地（不代表代理出口 IP）"
        }
        return "暂按节点名称显示地区，待服务器 IP 归属地识别"
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
