import AppKit
import SwiftUI
import CodexHarborCore
import ChatGPTBridgeCore

/// Technology-themed home, backed by the same models used by the detail pages.
/// Lines depict *available* networking paths, not observed per-process traffic.
struct HarborTechDashboardContent: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: ChatGPTBridgeViewModel
    @ObservedObject var proxy: HarborProxyManager

    let effectiveConnectionKind: CodexConnectionKind?
    let activeDisplayName: String
    let connected: Bool
    let accountExpiryText: String?
    let onSwitchCodex: () -> Void
    let onManageCodex: () -> Void
    let onOpenLocalAccess: () -> Void
    let onOpenNetworkProxy: () -> Void

    @State private var nodePickerOpen = false
    @State private var nodeSearch = ""
    @State private var copiedPort: Int?
    @State private var isRefreshing = false
    @State private var isCheckingMCP = false
    @State private var dashboardFeedback: String?
    @State private var dashboardFeedbackIsError = false
    @State private var dashboardFeedbackID = UUID()

    private let teal = Color(red: 0.03, green: 0.72, blue: 0.57)
    private let electric = Color(red: 0.16, green: 0.51, blue: 0.98)
    private let violet = Color(red: 0.58, green: 0.34, blue: 0.96)

    private var systemProxyAvailable: Bool { proxy.running && proxy.healthy && proxy.systemManaged }
    private var codexModel: String {
        guard let modelName = model.environment.model, !modelName.isEmpty else { return "模型未识别" }
        return modelName
    }
    private var bridgeConnected: Bool {
        bridge.configuration.enabled && bridge.overallReady && !bridge.toolCatalogRefreshRequired
    }
    private var bridgeState: String {
        if !bridge.configuration.enabled { return "未启用" }
        if bridge.toolCatalogRefreshRequired { return "工具待刷新" }
        return bridgeConnected ? "已连接" : "恢复中"
    }
    private var proxyState: String {
        if proxy.requiresRecovery { return "等待恢复" }
        if proxy.switchingNodeID != nil { return "正在切换" }
        if proxy.running && proxy.checkingConnectivity { return "正在检测" }
        if proxy.running && !proxy.healthy { return "连通性异常" }
        if systemProxyAvailable { return "系统代理已接管" }
        if proxy.running { return "本地代理已启动" }
        return "未使用代理"
    }
    private var proxyColor: Color {
        if proxy.requiresRecovery || (proxy.running && !proxy.healthy && !proxy.checkingConnectivity) {
            return HarborColors.orange
        }
        return systemProxyAvailable ? teal : (proxy.running ? electric : .secondary)
    }
    private var allEnabledServicesHealthy: Bool {
        connected
            && (!proxy.running || proxy.healthy)
            && (!bridge.configuration.enabled || bridgeConnected)
    }
    private var latestActivityText: String {
        guard let latest = model.activityEvents.map(\.timestamp).max() else { return "尚未同步" }
        return latest.formatted(date: .numeric, time: .shortened)
    }

    var body: some View {
        GeometryReader { geometry in
            let space = geometry.size
            let flowHeight = max(306, space.height * 0.465)
            let cardsHeight = max(274, space.height * 0.40)
            let gap = max(12, min(24, space.width * 0.013))
            ScrollView {
                VStack(alignment: .leading, spacing: gap) {
                    pageHeader
                    pathPanel
                        .frame(height: flowHeight)
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .top, spacing: gap) {
                            codexCard.frame(maxWidth: .infinity)
                            proxyCard.frame(maxWidth: .infinity)
                            chatGPTCard.frame(maxWidth: .infinity)
                        }
                        VStack(spacing: gap) {
                            codexCard
                            proxyCard
                            chatGPTCard
                        }
                    }
                    .frame(minHeight: cardsHeight, alignment: .top)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                .padding(.horizontal, max(20, min(48, space.width * 0.025)))
                .padding(.top, max(15, min(30, space.height * 0.024)))
                .padding(.bottom, 22)
            }
            .scrollIndicators(.automatic)
            .overlay(alignment: .topTrailing) {
                if let dashboardFeedback {
                    Label(dashboardFeedback,
                          systemImage: dashboardFeedbackIsError
                              ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(dashboardFeedbackIsError ? HarborColors.orange : teal)
                        .padding(.horizontal, 14)
                        .frame(minHeight: 36)
                        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(HarborColors.cardBorder)
                        )
                        .shadow(color: .black.opacity(0.09), radius: 12, y: 4)
                        .padding(.trailing, 24)
                        .padding(.top, 73)
                        .accessibilityAddTraits(.updatesFrequently)
                }
            }
        }
    }

    @MainActor
    private func showFeedback(_ text: String, isError: Bool = false) {
        dashboardFeedback = text
        dashboardFeedbackIsError = isError
        let id = UUID()
        dashboardFeedbackID = id
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3.5))
            guard dashboardFeedbackID == id else { return }
            dashboardFeedback = nil
        }
    }

    private func refreshAll() {
        guard !isRefreshing && !isCheckingMCP else { return }
        isRefreshing = true
        dashboardFeedback = nil
        Task { @MainActor in
            defer { isRefreshing = false }
            await bridge.refresh()
            await model.refreshConnectionHealth(logResult: false)
            showFeedback(allEnabledServicesHealthy
                ? "状态已刷新 · Codex 与 MCP 数据已更新"
                : "刷新完成 · 部分服务仍需检查", isError: !allEnabledServicesHealthy)
        }
    }

    private func checkMCPConnection() {
        guard !isRefreshing && !isCheckingMCP && !bridge.isDiagnosing else { return }
        guard bridge.configuration.enabled else {
            showFeedback("尚未启用 ChatGPT 接入，请先配置", isError: true)
            return
        }
        isCheckingMCP = true
        dashboardFeedback = nil
        Task { @MainActor in
            defer { isCheckingMCP = false }
            await bridge.runPipelineDiagnostics()
            let errors = bridge.diagnosticResults.filter { $0.status == .failed }
            let warnings = bridge.diagnosticResults.filter { $0.status == .warning }
            if let first = errors.first {
                showFeedback("MCP 检测失败：\(first.message)", isError: true)
            } else if let first = warnings.first {
                showFeedback("MCP 检测完成：\(first.message)", isError: true)
            } else if bridge.overallReady {
                showFeedback("MCP 链路检测通过 · 所有检查节点正常")
            } else {
                showFeedback("MCP 检测完成 · 连接仍未就绪", isError: true)
            }
        }
    }

    private var pageHeader: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("工作台")
                    .font(.system(size: 25, weight: .bold, design: .rounded))
                Text("AI 开发环境与连接状态 · 一站式管理")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 12)
            HarborStatusBadge(
                title: allEnabledServicesHealthy ? "当前服务状态就绪" : "部分服务需要关注",
                color: allEnabledServicesHealthy ? teal : HarborColors.orange,
                pulses: false
            )
            Text("最近事件  \(latestActivityText)")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Button(action: refreshAll) {
                HStack(spacing: 6) {
                    if isRefreshing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: "arrow.clockwise")
                    }
                    Text(isRefreshing ? "刷新中…" : "刷新状态")
                        .lineLimit(1)
                }
                .frame(minWidth: 82)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(isRefreshing || isCheckingMCP || bridge.isWorking ||
                      bridge.isDiagnosing || model.isCheckingConnectionHealth)
            .help("检查 Codex 凭据、ChatGPT MCP 状态；完成后显示结果")
            Button {
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            } label: {
                Image(systemName: "sun.max")
                    .frame(width: 18)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .help("切换浅色/深色外观")
        }
        .frame(minHeight: 50)
    }

    // Diagram instead of three more cards: the AI services are independent
    // endpoints; the central network layer is optional and never asserts
    // that a specific client request actually traversed the proxy.
    private var pathPanel: some View {
        GeometryReader { area in
            let w = area.size.width
            let h = area.size.height
            let scale = min(1.42, max(0.88, w / 1000))
            ZStack {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(red: 0.035, green: 0.085, blue: 0.18),
                                Color(red: 0.045, green: 0.09, blue: 0.21),
                                Color(red: 0.095, green: 0.07, blue: 0.23)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                // Decorative optics remain independent of view state.
                RadialGradient(
                    colors: [electric.opacity(0.23), electric.opacity(0.04), .clear],
                    center: .center, startRadius: 0, endRadius: w * 0.32
                )
                .frame(width: w * 0.65, height: h)
                .position(x: w * 0.10, y: h * 0.34)
                RadialGradient(
                    colors: [violet.opacity(0.18), violet.opacity(0.02), .clear],
                    center: .center, startRadius: 0, endRadius: w * 0.34
                )
                .frame(width: w * 0.70, height: h)
                .position(x: w * 0.93, y: h * 0.68)

                HarborTechFlowLines(proxyActive: systemProxyAvailable)
                    .allowsHitTesting(false)

                HStack(spacing: 7) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .foregroundStyle(electric)
                    Text("NETWORK FABRIC")
                        .tracking(2)
                        .foregroundStyle(Color.white.opacity(0.84))
                    Text("/ 可选网络层")
                        .foregroundStyle(Color.white.opacity(0.54))
                    Spacer()
                    Circle().fill(systemProxyAvailable ? teal : Color.white.opacity(0.38))
                        .frame(width: 6, height: 6)
                    Text(systemProxyAvailable ? "代理已接管" : "系统网络")
                        .foregroundStyle(Color.white.opacity(0.80))
                }
                .font(.system(size: 10 * scale, weight: .semibold, design: .monospaced))
                .padding(.horizontal, max(22, w * 0.032))
                .position(x: w / 2, y: max(26, h * 0.10))

                hologramEndpoint(
                    title: "CODEX", status: connected ? "已配置" : "未连接",
                    detail: activeDisplayName, subtitle: codexModel,
                    icon: "terminal.fill",
                    tint: teal, scale: scale
                )
                .frame(width: max(175, min(w * 0.275, 330)))
                .position(x: w * 0.19, y: h * 0.46)

                hologramEndpoint(
                    title: "CHATGPT / MCP", status: bridgeState,
                    detail: bridge.configuration.enabled
                        ? bridge.configuration.transportMode.displayName : "尚未启用",
                    subtitle: bridge.runtime.toolCatalogCount.map { "工具目录 \($0) 项" } ?? "工具目录待检测",
                    icon: "sparkles", tint: electric,
                    scale: scale
                )
                .frame(width: max(175, min(w * 0.275, 330)))
                .position(x: w * 0.81, y: h * 0.46)

                // The network core deliberately sits below the two AI
                // endpoints, emphasizing infrastructure rather than a peer app.
                VStack(spacing: max(4, h * 0.015)) {
                        ZStack {
                            Circle()
                                .stroke(violet.opacity(0.13), lineWidth: 12)
                                .frame(width: 120 * scale, height: 120 * scale)
                            Circle()
                                .stroke(
                                    AngularGradient(
                                        colors: [violet.opacity(0.2), electric, teal, violet],
                                        center: .center
                                    ), lineWidth: 2.3
                                )
                                .frame(width: 105 * scale, height: 105 * scale)
                            Circle()
                                .stroke(violet.opacity(0.45),
                                        style: StrokeStyle(lineWidth: 1, dash: [3, 5]))
                                .frame(width: 84 * scale, height: 84 * scale)
                            Image(systemName: systemProxyAvailable ? "network" : "globe")
                                .font(.system(size: 34 * scale, weight: .light))
                                .foregroundStyle(Color.white)
                                .shadow(color: violet, radius: 14)
                        }
                        Text("NETWORK CORE")
                            .font(.system(size: 11 * scale, weight: .bold, design: .monospaced))
                            .tracking(1.4)
                            .foregroundStyle(.white)
                        Text(proxyState)
                            .font(.system(size: 10 * scale, weight: .semibold))
                            .foregroundStyle(systemProxyAvailable ? teal : Color.white.opacity(0.7))
                            .lineLimit(1)
                        Text(proxy.running
                             ? (proxy.selectedNode?.displayName ?? "本地代理")
                             : "直连可用 · 代理非必需")
                            .font(.system(size: 9 * scale))
                            .foregroundStyle(Color.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .frame(width: max(160, w * 0.22))
                    .contentShape(Rectangle())
                .position(x: w * 0.50, y: h * 0.66)
                .help("网络路径示意，代理管理请使用下方功能卡片")

                // Compact, non-interactive circuit labels add visual depth
                // without extra polling, network probes or SwiftUI timers.
                topologySignal("CODEX CLI", tint: teal, scale: scale)
                    .position(x: w * 0.35, y: h * 0.55)
                topologySignal("MCP BRIDGE", tint: electric, scale: scale)
                    .position(x: w * 0.65, y: h * 0.55)

                HStack(spacing: 10) {
                    Image(systemName: "arrow.triangle.branch")
                        .foregroundStyle(teal)
                    Text("实线 · 可选代理")
                    Rectangle().fill(Color.white.opacity(0.20)).frame(width: 1, height: 12)
                    Image(systemName: "arrow.up.right").foregroundStyle(electric)
                    Text("虚线 · 直连通道")
                    Spacer()
                    Text("网络路径示意 ≠ 实际流量归属")
                        .foregroundStyle(Color.white.opacity(0.52))
                }
                .font(.system(size: 9 * scale, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.78))
                .padding(.horizontal, max(22, w * 0.032))
                .position(x: w / 2, y: h * 0.925)
            }
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 24).stroke(electric.opacity(0.27)))
        }
    }

    private func hologramEndpoint(
        title: String, status: String, detail: String, subtitle: String,
        icon: String, tint: Color, scale: CGFloat
    ) -> some View {
        VStack(spacing: 6 * scale) {
                ZStack {
                    Circle()
                        .stroke(tint.opacity(0.17), lineWidth: 12 * scale)
                        .frame(width: 98 * scale, height: 98 * scale)
                    Circle()
                        .stroke(tint.opacity(0.60), lineWidth: 1.3)
                        .frame(width: 88 * scale, height: 88 * scale)
                    Circle()
                        .fill(tint.opacity(0.13))
                        .frame(width: 66 * scale, height: 66 * scale)
                    Image(systemName: icon)
                        .font(.system(size: 27 * scale, weight: .medium))
                        .foregroundStyle(.white)
                        .shadow(color: tint, radius: 8)
                }
                Text(title)
                    .font(.system(size: 11 * scale, weight: .bold, design: .monospaced))
                    .tracking(1)
                    .foregroundStyle(.white)
                HStack(spacing: 5) {
                    Circle().fill(tint).frame(width: 5 * scale, height: 5 * scale)
                    Text(status)
                }
                .font(.system(size: 10 * scale, weight: .medium))
                .foregroundStyle(tint)
                Text(detail)
                    .font(.system(size: 11 * scale, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(0.86))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitle)
                    .font(.system(size: 9 * scale))
                    .foregroundStyle(Color.white.opacity(0.57))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .help(title + " 的当前状态；管理操作请使用下方卡片")
    }

    private func topologySignal(_ name: String, tint: Color, scale: CGFloat) -> some View {
        HStack(spacing: 5) {
            Circle().fill(tint).frame(width: 4, height: 4)
            Text(name)
                .tracking(0.9)
        }
        .font(.system(size: 8 * scale, weight: .semibold, design: .monospaced))
        .foregroundStyle(tint.opacity(0.78))
        .padding(.horizontal, 9)
        .frame(height: 19 * scale)
        .background(Color(red: 0.05, green: 0.095, blue: 0.18).opacity(0.90),
                    in: Capsule())
        .overlay(Capsule().stroke(tint.opacity(0.20)))
        .fixedSize()
        .accessibilityHidden(true)
    }

    private func glassCard<Content: View>(
        tint: Color, @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 12, content: content)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 270, alignment: .topLeading)
            .background {
                RoundedRectangle(cornerRadius: 16)
                    .fill(HarborColors.cardBackground)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(
                                LinearGradient(
                                    colors: [tint.opacity(0.07), Color.clear, tint.opacity(0.015)],
                                    startPoint: .topLeading, endPoint: .bottomTrailing
                                )
                            )
                    }
            }
            .overlay(RoundedRectangle(cornerRadius: 16).stroke(tint.opacity(0.18)))
            .shadow(color: tint.opacity(0.05), radius: 11, y: 4)
    }

    private func cardHeader(_ title: String, icon: String, tint: Color,
                            status: String, action: @escaping () -> Void) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).foregroundStyle(tint)
            Text(title).font(.system(size: 12.5, weight: .semibold))
            Spacer(minLength: 0)
            Text(status)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(tint)
                .lineLimit(1)
            Button(action: action) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: tint, cornerRadius: 7))
            .help("进入" + title)
        }
    }

    private func detailRow(_ label: String, _ value: String, color: Color = .primary) -> some View {
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary).lineLimit(1)
            Spacer(minLength: 4)
            Text(value).foregroundStyle(color)
                .lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .font(.system(size: 10.5))
        .frame(height: 19)
    }

    private var codexCard: some View {
        let since = Calendar.current.startOfDay(for: .now)
        let kinds: [CodexConnectionKind] = [.account, .harborKey, .apiKey]
        let stats = kinds.map { model.codexRequestMetrics(for: $0, profileID: nil, since: since) }
        let count = stats.reduce(0) { $0 + $1.count }
        let successes = stats.reduce(0) { $0 + $1.successfulCount }
        let tokens = kinds.reduce(0) { $0 + model.codexTokenSummary(for: $1, profileID: nil, since: since).totalTokens }
        return glassCard(tint: teal) {
            cardHeader("Codex 连接", icon: "point.3.connected.trianglepath.dotted", tint: teal,
                       status: connected ? "已配置" : "未连接", action: onManageCodex)
            HStack(spacing: 11) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(teal)
                    .frame(width: 49, height: 49)
                    .background(teal.opacity(0.11), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 4) {
                    Text(activeDisplayName)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    Text(codexModel)
                        .font(.system(size: 10.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.3)
            detailRow("今日请求", String(count))
            detailRow("Token", tokens.formatted())
            detailRow("成功率", count > 0 ?
                      (Double(successes) / Double(count)).formatted(.percent.precision(.fractionLength(1))) : "—")
            if let accountExpiryText, effectiveConnectionKind == .account {
                Text(accountExpiryText)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                actionPill("切换连接", icon: "arrow.left.arrow.right", tint: teal, action: onSwitchCodex)
                actionPill("管理", icon: "slider.horizontal.3", tint: teal, action: onManageCodex)
            }
        }
    }

    private var proxyCard: some View {
        glassCard(tint: violet) {
            cardHeader("网络代理", icon: "network", tint: violet,
                       status: proxyState, action: onOpenNetworkProxy)
            HStack(spacing: 9) {
                Image(systemName: proxy.running ? "globe.asia.australia.fill" : "network.slash")
                    .font(.system(size: 23))
                    .foregroundStyle(violet)
                    .frame(width: 44, height: 44)
                    .background(violet.opacity(0.09), in: RoundedRectangle(cornerRadius: 13))
                VStack(alignment: .leading, spacing: 3) {
                    Text(proxy.running ? (proxy.selectedNode?.displayName ?? "当前节点") : "使用系统网络")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(proxy.running ? (proxy.routingRules ? "规则模式" : "全局模式") : "Harbor 代理未启动")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.3)
            detailRow("系统代理", systemProxyAvailable ? "已接管" : "未接管",
                      color: systemProxyAvailable ? teal : .secondary)
            proxyPortRow("HTTP", port: proxy.running ? proxy.localPort : nil)
            proxyPortRow("SOCKS5", port: proxy.running ? proxy.localPort.map { $0 + 1 } : nil)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button {
                    nodePickerOpen = true
                } label: {
                    Label("切换节点", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(HarborActionButtonStyle(tint: violet, prominence: .secondary))
                .popover(isPresented: $nodePickerOpen, arrowEdge: .bottom) { proxySwitcher }
                actionPill("代理管理", icon: "arrow.up.right", tint: violet, action: onOpenNetworkProxy)
            }
        }
    }

    private func proxyPortRow(_ title: String, port: Int?) -> some View {
        HStack(spacing: 6) {
            Text(title).foregroundStyle(.secondary)
            Spacer(minLength: 0)
            if let port {
                Text(verbatim: "127.0.0.1:\(String(port))")
                    .font(.system(size: 10, design: .monospaced))
                    .lineLimit(1).minimumScaleFactor(0.85)
                Button {
                    let board = NSPasteboard.general
                    board.clearContents()
                    let scheme = title == "HTTP" ? "http" : "socks5"
                    board.setString("\(scheme)://127.0.0.1:\(String(port))", forType: .string)
                    copiedPort = port
                } label: {
                    Image(systemName: copiedPort == port ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 10))
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: violet, cornerRadius: 5))
                .help("复制" + title + "代理地址")
            } else {
                Text("—").foregroundStyle(.secondary)
            }
        }
        .font(.system(size: 10.5))
        .frame(height: 19)
    }

    private var proxySwitcher: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("选择代理节点").font(.system(size: 14, weight: .semibold))
            TextField("搜索名称", text: $nodeSearch)
                .textFieldStyle(.roundedBorder)
            ScrollView {
                LazyVStack(spacing: 3) {
                    ForEach(proxy.nodes.filter {
                        nodeSearch.isEmpty || $0.displayName.localizedCaseInsensitiveContains(nodeSearch)
                    }) { node in
                        Button {
                            nodePickerOpen = false
                            Task { await proxy.activate(node.id) }
                        } label: {
                            HStack(spacing: 8) {
                                Image(systemName: node.id == proxy.selectedID ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(node.id == proxy.selectedID ? teal : .secondary)
                                Text(node.displayName).lineLimit(1)
                                Spacer()
                                if proxy.switchingNodeID == node.id {
                                    ProgressView().controlSize(.mini)
                                }
                            }
                            .font(.system(size: 11))
                            .padding(.horizontal, 9).frame(height: 33)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(HarborInteractivePlainButtonStyle(tint: violet, cornerRadius: 7))
                    }
                }
            }
            .frame(maxHeight: 280)
            Button("进入网络代理管理", action: onOpenNetworkProxy)
                .buttonStyle(HarborActionButtonStyle(tint: violet, prominence: .secondary))
        }
        .padding(14)
        .frame(width: 330)
    }

    private var chatGPTCard: some View {
        glassCard(tint: electric) {
            cardHeader("ChatGPT 接入", icon: "desktopcomputer", tint: electric,
                       status: bridgeState, action: onOpenLocalAccess)
            HStack(spacing: 11) {
                Image(systemName: "point.3.connected.trianglepath.dotted")
                    .font(.system(size: 22))
                    .foregroundStyle(electric)
                    .frame(width: 49, height: 49)
                    .background(electric.opacity(0.10), in: RoundedRectangle(cornerRadius: 14))
                VStack(alignment: .leading, spacing: 3) {
                    Text(bridge.configuration.enabled ? bridge.configuration.transportMode.displayName : "本地 MCP 服务")
                        .font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    Text(bridge.runtime.toolCatalogVersion ?? "MCP 工具目录")
                        .font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            Divider().opacity(0.3)
            detailRow("MCP 服务", bridge.localReady ? "运行正常" : "未就绪",
                      color: bridge.localReady ? teal : .secondary)
            detailRow("工具目录", bridge.runtime.toolCatalogCount.map { "\($0) 项" } ?? "待检测")
            detailRow("远端链路", bridgeConnected ? "可用" : bridgeState,
                      color: bridgeConnected ? teal : .secondary)
            Spacer(minLength: 0)
            HStack(spacing: 8) {
                Button(action: checkMCPConnection) {
                    HStack(spacing: 6) {
                        if isCheckingMCP {
                            ProgressView().controlSize(.mini)
                        } else {
                            Image(systemName: "waveform.path.ecg")
                        }
                        Text(isCheckingMCP ? "检测中…" : "检测连接")
                            .lineLimit(1)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(HarborActionButtonStyle(tint: electric, prominence: .secondary))
                .disabled(isCheckingMCP || isRefreshing || bridge.isDiagnosing || bridge.isWorking)
                .help("完整检测 MCP、网络代理、Tunnel 与远端端点，并显示结果")
                actionPill("管理配置", icon: "gearshape", tint: electric, action: onOpenLocalAccess)
            }
        }
    }

    private func actionPill(_ title: String, icon: String, tint: Color,
                            action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Label(title, systemImage: icon)
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(HarborActionButtonStyle(tint: tint, prominence: .secondary))
    }

}

/// Static, composited network topology. Particle movement is delegated to
/// Core Animation rather than a SwiftUI TimelineView (no recurring body/layout
/// invalidation or main-thread Canvas redraws).
private struct HarborTechFlowLines: View {
    let proxyActive: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Canvas(opaque: false) { context, size in
                let left = curve(size, targetX: 0.19, wave: -0.08)
                let right = curve(size, targetX: 0.81, wave: 0.08)
                for (path, color) in [
                    (left, Color(red: 0.02, green: 0.75, blue: 0.62)),
                    (right, Color(red: 0.37, green: 0.48, blue: 0.99))
                ] {
                    context.stroke(
                        path, with: .color(color.opacity(proxyActive ? 0.13 : 0.06)),
                        style: StrokeStyle(lineWidth: 13, lineCap: .round)
                    )
                    context.stroke(
                        path, with: .color(color.opacity(proxyActive ? 0.82 : 0.22)),
                        style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
                    )
                }

                // Direct network remains an available fallback regardless of
                // whether Harbor has taken over the macOS system proxy.
                var bypass = Path()
                bypass.move(to: CGPoint(x: size.width * 0.19, y: size.height * 0.44))
                bypass.addQuadCurve(
                    to: CGPoint(x: size.width * 0.81, y: size.height * 0.44),
                    control: CGPoint(x: size.width * 0.50, y: size.height * 0.04)
                )
                context.stroke(bypass,
                               with: .color(Color.secondary.opacity(proxyActive ? 0.16 : 0.32)),
                               style: StrokeStyle(lineWidth: 1.4, dash: [4, 6]))

                for i in 0..<9 {
                    let y = size.height * (0.72 + CGFloat(i) * 0.03)
                    var line = Path()
                    line.move(to: CGPoint(x: 0, y: y))
                    line.addLine(to: CGPoint(x: size.width, y: y))
                    context.stroke(line, with: .color(Color.blue.opacity(0.04)), lineWidth: 0.5)
                }
            }
            HarborFlowParticles(active: proxyActive && !reduceMotion && scenePhase == .active)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    private func curve(_ size: CGSize, targetX: CGFloat, wave: CGFloat) -> Path {
        var path = Path()
        let start = CGPoint(x: size.width * 0.50, y: size.height * 0.63)
        let end = CGPoint(x: size.width * targetX, y: size.height * 0.44)
        path.move(to: start)
        path.addCurve(
            to: end,
            control1: CGPoint(x: start.x + size.width * wave, y: start.y - size.height * 0.20),
            control2: CGPoint(x: end.x - size.width * wave * 0.65, y: end.y + size.height * 0.16)
        )
        return path
    }
}

private struct HarborFlowParticles: NSViewRepresentable {
    let active: Bool

    func makeNSView(context: Context) -> HarborParticleLayerView {
        HarborParticleLayerView(frame: .zero)
    }

    func updateNSView(_ nsView: HarborParticleLayerView, context: Context) {
        nsView.setActive(active)
    }
}

private final class HarborParticleLayerView: NSView {
    private let first = CALayer()
    private let second = CALayer()
    private var active = false
    private var configuredSize: CGSize = .zero

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        for (particle, color) in [
            (first, NSColor.systemGreen),
            (second, NSColor.systemBlue)
        ] {
            particle.bounds = CGRect(x: 0, y: 0, width: 7, height: 7)
            particle.cornerRadius = 3.5
            particle.backgroundColor = color.cgColor
            particle.shadowColor = color.cgColor
            particle.shadowRadius = 4
            particle.shadowOpacity = 0.35
            particle.isHidden = true
            layer?.addSublayer(particle)
        }
    }

    required init?(coder: NSCoder) {
        fatalError("HarborParticleLayerView is created programmatically")
    }

    func setActive(_ enabled: Bool) {
        guard active != enabled else { return }
        active = enabled
        updateAnimations()
    }

    override func layout() {
        super.layout()
        guard bounds.size != configuredSize else { return }
        configuredSize = bounds.size
        updateAnimations()
    }

    private func updateAnimations() {
        for particle in [first, second] {
            particle.removeAnimation(forKey: "harborNetworkFlow")
            particle.isHidden = !active
        }
        guard active, bounds.width > 30, bounds.height > 30 else { return }

        let w = bounds.width
        let h = bounds.height
        let routes: [(CALayer, CGFloat, CGFloat)] = [
            (first, 0.19, -0.08),
            (second, 0.81, 0.08)
        ]
        for (index, route) in routes.enumerated() {
            let (particle, targetX, bend) = route
            let start = CGPoint(x: w * 0.50, y: h * 0.63)
            let end = CGPoint(x: w * targetX, y: h * 0.44)
            let curve = CGMutablePath()
            curve.move(to: start)
            curve.addCurve(
                to: end,
                control1: CGPoint(x: start.x + w * bend, y: start.y - h * 0.20),
                control2: CGPoint(x: end.x - w * bend * 0.65, y: end.y + h * 0.16)
            )
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            particle.position = start
            CATransaction.commit()

            let motion = CAKeyframeAnimation(keyPath: "position")
            motion.path = curve
            motion.calculationMode = .paced
            motion.duration = 3.4
            motion.beginTime = CACurrentMediaTime() - Double(index) * 0.85
            motion.repeatCount = .infinity
            motion.isRemovedOnCompletion = false
            particle.add(motion, forKey: "harborNetworkFlow")
        }
    }
}
