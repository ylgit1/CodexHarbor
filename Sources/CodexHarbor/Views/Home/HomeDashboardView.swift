import SwiftUI
import CodexHarborCore
import ChatGPTBridgeCore

private enum HarborQuickConnectionTarget: Hashable {
    case account(UUID)
    case profile(UUID)
}

struct HarborHomeDashboardView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var bridge: ChatGPTBridgeViewModel

    let effectiveConnectionKind: CodexConnectionKind?
    let activeDisplayName: String
    let connected: Bool
    let accountExpiryText: String?
    let accountExpiryColor: Color?
    let onManageConnections: (CodexConnectionKind?) -> Void
    let onOpenLocalAccess: () -> Void

    @State private var showingQuickSwitcher = false
    @State private var quickSelection: HarborQuickConnectionTarget?

    var body: some View {
        GeometryReader { geometry in
            let compact = geometry.size.height < 800
            let trendHeight = max(108, min(210, geometry.size.height - (compact ? 525 : 555)))

            let since = Calendar.current.startOfDay(for: Date())
            let kinds: [CodexConnectionKind] = [.account, .harborKey, .apiKey]
            let metrics = kinds.map { model.codexRequestMetrics(for: $0, profileID: nil, since: since) }
            let requestCount = metrics.reduce(0) { $0 + $1.count }
            let successfulCount = metrics.reduce(0) { $0 + $1.successfulCount }
            let durations = model.activityEvents
                .filter { $0.kind == .codexRequest && $0.timestamp >= since }
                .compactMap(\.durationMilliseconds)
            let averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count

            VStack(alignment: .leading, spacing: compact ? 12 : 14) {
                currentConnectionHero
                    .frame(height: compact ? 126 : 136)

                HStack(spacing: 12) {
                    metricCard(
                        "今日请求数",
                        value: requestCount.formatted(),
                        icon: "chart.bar.fill",
                        color: HarborColors.blue
                    )
                    metricCard(
                        "成功率",
                        value: percentText(requestCount > 0 ? Double(successfulCount) / Double(requestCount) : nil),
                        icon: "checkmark.shield.fill",
                        color: HarborColors.green
                    )
                    metricCard(
                        "平均响应耗时",
                        value: durationText(averageDuration),
                        icon: "clock.fill",
                        color: HarborColors.purple
                    )
                }
                .frame(height: compact ? 94 : 104)

                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .top, spacing: 12) {
                        connectionModeOverview
                            .frame(maxWidth: .infinity)
                        localAccessSummaryCard
                            .frame(width: 300)
                    }

                    VStack(spacing: 12) {
                        connectionModeOverview
                        localAccessSummaryCard
                    }
                }
                .frame(height: compact ? 220 : 230)

                homeUsageTrend(height: trendHeight)
                    .frame(height: trendHeight)
            }
            .frame(maxWidth: 1220, maxHeight: .infinity, alignment: .top)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .padding(.horizontal, 26)
            .padding(.top, compact ? 16 : 20)
            .padding(.bottom, compact ? 14 : 18)
        }
    }

    private var currentConnectionHero: some View {
        let kindTitle = effectiveConnectionKind?.title
            .replacingOccurrences(of: "自定义 API 密钥", with: "自定义 API") ?? "未连接"
        let currentModel = model.environment.model?.isEmpty == false ? model.environment.model! : "—"
        let latestDuration = model.activityEvents
            .last(where: { $0.kind == .codexRequest && $0.succeeded })?
            .durationMilliseconds
        let latestCheck = model.activityEvents
            .last(where: { $0.kind == .healthCheck })?
            .timestamp

        return HarborCard(padding: 18) {
            HStack(spacing: 18) {
                Image(systemName: effectiveConnectionKind == .apiKey ? "network" : (effectiveConnectionKind == .harborKey ? "key.fill" : "person.crop.circle.fill"))
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(HarborColors.blue)
                    .frame(width: 58, height: 58)
                    .background(Color.blue.opacity(0.09), in: RoundedRectangle(cornerRadius: 17, style: .continuous))

                VStack(alignment: .leading, spacing: 9) {
                    Text("当前工作连接")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)

                    HStack(spacing: 9) {
                        Text("\(kindTitle)  \(activeDisplayName)")
                            .font(.system(size: 20, weight: .bold, design: .rounded))
                            .lineLimit(1)
                        HarborStatusBadge(
                            title: connected ? "当前使用" : "未连接",
                            color: connected ? HarborColors.green : .secondary
                        )
                    }

                    HStack(spacing: 14) {
                        Label("模型：\(currentModel)", systemImage: "cube")
                        Label("延迟：\(latestDuration.map { "\($0) ms" } ?? "—")", systemImage: "bolt.fill")
                        Label("上次检查：\(latestCheck.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—")", systemImage: "clock")

                        if effectiveConnectionKind == .account,
                           let accountExpiryText,
                           !accountExpiryText.isEmpty {
                            Label(accountExpiryText, systemImage: "exclamationmark.triangle.fill")
                                .foregroundStyle(accountExpiryColor ?? HarborColors.orange)
                        }
                    }
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(.secondary)
                }

                Spacer(minLength: 18)

                Button {
                    if showingQuickSwitcher {
                        showingQuickSwitcher = false
                    } else {
                        quickSelection = activeQuickConnectionTarget
                        showingQuickSwitcher = true
                    }
                } label: {
                    Label("切换连接", systemImage: "arrow.left.arrow.right")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                .popover(isPresented: $showingQuickSwitcher, arrowEdge: .top) {
                    quickConnectionSwitcher
                }

                Button {
                    onManageConnections(nil)
                } label: {
                    Label("管理连接", systemImage: "gearshape")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            }
        }
        .frame(minHeight: 118)
    }

    private var quickConnectionSwitcher: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("切换连接")
                        .font(.system(size: 16, weight: .semibold))
                    Text("选择连接后点击“立即切换”，切换完成会自动重载 Codex。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Button {
                    showingQuickSwitcher = false
                    quickSelection = nil
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 27, height: 27)
                        .background(Color.primary.opacity(0.045), in: Circle())
                }
                .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            }

            Divider().opacity(0.35)

            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    sectionTitle("账户")
                    ForEach(model.accountProfiles) { profile in
                        switcherRow(
                            name: profile.name,
                            detail: "ChatGPT 账户",
                            icon: "person.crop.circle.fill",
                            active: effectiveConnectionKind == .account && model.selectedAccountProfileID == profile.id,
                            available: isAvailable(model.accountProfileHealth[profile.id]),
                            selected: quickSelection == .account(profile.id)
                        ) {
                            quickSelection = .account(profile.id)
                        }
                    }

                    let hosted = model.profiles.filter { $0.kind == .harbor }
                    if !hosted.isEmpty {
                        sectionTitle("托管密钥")
                        ForEach(hosted) { profile in
                            switcherRow(
                                name: profile.name,
                                detail: profile.model.isEmpty ? "托管连接" : profile.model,
                                icon: "key.fill",
                                active: effectiveConnectionKind == .harborKey && model.activeProfileID == profile.id,
                                available: isAvailable(model.apiProfileHealth[profile.id]),
                                selected: quickSelection == .profile(profile.id)
                            ) {
                                quickSelection = .profile(profile.id)
                            }
                        }
                    }

                    let custom = model.profiles.filter { $0.kind == .customResponses }
                    if !custom.isEmpty {
                        sectionTitle("自定义 API")
                        ForEach(custom) { profile in
                            switcherRow(
                                name: profile.name,
                                detail: profile.model.isEmpty ? profile.provider.title : "\(profile.provider.title) · \(profile.model)",
                                icon: "network",
                                active: effectiveConnectionKind == .apiKey && model.activeProfileID == profile.id,
                                available: isAvailable(model.apiProfileHealth[profile.id]),
                                selected: quickSelection == .profile(profile.id)
                            ) {
                                quickSelection = .profile(profile.id)
                            }
                        }
                    }
                }
            }
            .frame(maxHeight: 330)

            Divider().opacity(0.35)

            HStack {
                Button("管理连接") {
                    showingQuickSwitcher = false
                    quickSelection = nil
                    onManageConnections(nil)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))

                Spacer()

                Button("取消") {
                    showingQuickSwitcher = false
                    quickSelection = nil
                }
                .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))

                Button {
                    applyQuickSelection()
                } label: {
                    if model.isBusy {
                        Label("切换中", systemImage: "arrow.triangle.2.circlepath")
                    } else {
                        Label("立即切换", systemImage: "arrow.left.arrow.right")
                    }
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                .disabled(
                    quickSelection == nil
                        || quickSelection == activeQuickConnectionTarget
                        || model.isBusy
                )
            }
        }
        .padding(18)
        .frame(width: 430)
        .background(HarborColors.cardBackground)
        .presentationBackground(HarborColors.cardBackground)
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 9.5, weight: .semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func switcherRow(
        name: String,
        detail: String,
        icon: String,
        active: Bool,
        available: Bool,
        selected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(HarborColors.blue)
                    .frame(width: 34, height: 34)
                    .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 7) {
                        Text(name)
                            .font(.system(size: 11.5, weight: .semibold))
                            .lineLimit(1)

                        if active {
                            HarborStatusBadge(title: "当前使用", color: HarborColors.green)
                        }
                    }

                    Text(detail)
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !active {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(available ? HarborColors.green : Color.secondary.opacity(0.4))
                            .frame(width: 6, height: 6)
                        Text(available ? "可用" : "待检查")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(available ? HarborColors.green : .secondary)
                    }
                }

                Image(systemName: active ? "checkmark.circle.fill" : (selected ? "record.circle.fill" : "circle"))
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(
                        active
                            ? HarborColors.green
                            : (selected ? HarborColors.blue : Color.secondary.opacity(0.34))
                    )
            }
            .padding(.horizontal, 11)
            .frame(height: 54)
            .background(
                selected
                    ? HarborColors.blue.opacity(0.13)
                    : (active ? HarborColors.green.opacity(0.045) : Color.primary.opacity(0.018)),
                in: RoundedRectangle(cornerRadius: 11)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? HarborColors.blue.opacity(0.48) : Color.primary.opacity(0.055), lineWidth: selected ? 1.5 : 1)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 11))
        .disabled(active)
    }

    private var activeQuickConnectionTarget: HarborQuickConnectionTarget? {
        switch effectiveConnectionKind {
        case .account:
            if let id = model.selectedAccountProfileID {
                return .account(id)
            }
        case .harborKey, .apiKey:
            if let id = model.activeProfileID {
                return .profile(id)
            }
        case nil:
            break
        }
        return nil
    }

    private func applyQuickSelection() {
        guard let quickSelection,
              quickSelection != activeQuickConnectionTarget else { return }

        Task {
            switch quickSelection {
            case let .account(id):
                await model.switchAccount(to: id)
            case let .profile(id):
                await model.switchProfile(to: id)
            }

            if model.errorMessage == nil {
                await MainActor.run {
                    showingQuickSwitcher = false
                    self.quickSelection = nil
                }
            }
        }
    }

    private func metricCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        HarborCard(padding: 15) {
            HStack(spacing: 13) {
                Image(systemName: icon)
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 42, height: 42)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 12))
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 24, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                Image(systemName: "chart.line.uptrend.xyaxis")
                    .font(.system(size: 24, weight: .light))
                    .foregroundStyle(color.opacity(0.75))
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var connectionModeOverview: some View {
        let accountCount = model.accountProfiles.count
        let hostedCount = model.profiles.filter { $0.kind == .harbor }.count
        let apiCount = model.profiles.filter { $0.kind == .customResponses }.count

        return HarborCard(padding: 15) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("连接方式")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    Button("管理全部连接 →") {
                        onManageConnections(nil)
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(HarborColors.blue)
                }

                HStack(spacing: 10) {
                    modeCard(
                        title: "账户",
                        icon: "person.crop.circle.fill",
                        status: effectiveConnectionKind == .account ? "当前使用" : "\(accountCount) 个连接",
                        detail: effectiveConnectionKind == .account
                            ? "当前：\(activeDisplayName)"
                            : (accountCount > 0 ? "已保存 ChatGPT 登录连接" : "尚未添加账户"),
                        active: effectiveConnectionKind == .account
                    ) { onManageConnections(.account) }

                    modeCard(
                        title: "托管密钥",
                        icon: "key.fill",
                        status: effectiveConnectionKind == .harborKey ? "当前使用" : "\(hostedCount) 个连接",
                        detail: effectiveConnectionKind == .harborKey
                            ? "当前：\(activeDisplayName)"
                            : (hostedCount > 0 ? "由 Harbor 托管并切换密钥" : "尚未添加托管密钥"),
                        active: effectiveConnectionKind == .harborKey
                    ) { onManageConnections(.harborKey) }

                    modeCard(
                        title: "自定义 API",
                        icon: "network",
                        status: effectiveConnectionKind == .apiKey ? "当前使用" : "\(apiCount) 个连接",
                        detail: effectiveConnectionKind == .apiKey
                            ? "当前：\(activeDisplayName)"
                            : (apiCount > 0 ? "兼容 OpenAI Responses 接口" : "尚未添加自定义 API"),
                        active: effectiveConnectionKind == .apiKey
                    ) { onManageConnections(.apiKey) }
                }
            }
        }
    }

    private func modeCard(
        title: String,
        icon: String,
        status: String,
        detail: String,
        active: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(HarborColors.blue)
                        .frame(width: 38, height: 38)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                    Spacer()
                    if active {
                        HarborStatusBadge(title: "当前使用", color: HarborColors.green)
                    }
                }

                Text(title)
                    .font(.system(size: 13, weight: .semibold))

                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)

                HStack(spacing: 6) {
                    Circle()
                        .fill(active ? HarborColors.green : Color.secondary.opacity(0.45))
                        .frame(width: 6, height: 6)
                    Text(status)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(active ? HarborColors.green : .secondary)

                    Spacer()

                    Text(active ? "管理 →" : "查看 →")
                        .font(.system(size: 10.5, weight: .semibold))
                        .foregroundStyle(HarborColors.blue)
                }
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 136, alignment: .topLeading)
            .background(
                active ? HarborColors.blue.opacity(0.035) : Color.primary.opacity(0.022),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(active ? HarborColors.blue.opacity(0.18) : Color.primary.opacity(0.07))
            )
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 12))
    }

    private var localAccessSummaryCard: some View {
        let tunnelConfigured = isConfigured(.secureTunnel)
        let httpsConfigured = isConfigured(.httpsCompatibility)
        let activeMode = bridge.configuration.enabled ? bridge.configuration.transportMode : nil

        return HarborCard(padding: 12) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "display")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(HarborColors.blue)
                    Text("ChatGPT 接入")
                        .font(.system(size: 14, weight: .semibold))
                    Spacer()
                    HarborStatusBadge(
                        title: bridge.configuration.enabled ? "已启用" : "未启用",
                        color: bridge.configuration.enabled ? HarborColors.green : .secondary
                    )
                }

                Spacer(minLength: 4)

                VStack(spacing: 8) {
                    localStatusRow("OpenAI 本地管道", active: activeMode == .secureTunnel, configured: tunnelConfigured)
                    localStatusRow("公网 HTTPS", active: activeMode == .httpsCompatibility, configured: httpsConfigured)
                }

                Spacer(minLength: 4)

                Button(action: onOpenLocalAccess) {
                    HStack {
                        Spacer()
                        Text("进入 ChatGPT 接入")
                        Image(systemName: "arrow.right")
                        Spacer()
                    }
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
            }
        }
    }

    private func localStatusRow(_ title: String, active: Bool, configured: Bool) -> some View {
        HStack(spacing: 9) {
            Image(systemName: title.contains("HTTPS") ? "globe" : "point.3.connected.trianglepath.dotted")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(HarborColors.blue)
                .frame(width: 28, height: 28)
                .background(Color.blue.opacity(0.07), in: RoundedRectangle(cornerRadius: 9))
            Text(title)
                .font(.system(size: 11.5, weight: .semibold))
            Spacer()
            Circle()
                .fill(active ? HarborColors.green : (configured ? HarborColors.orange : Color.secondary.opacity(0.4)))
                .frame(width: 7, height: 7)
            Text(active ? "使用中" : (configured ? "待使用" : "未配置"))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(active ? HarborColors.green : (configured ? HarborColors.orange : .secondary))
        }
        .padding(.horizontal, 10)
        .frame(height: 38)
        .background(Color.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: 10))
    }

    private func homeUsageTrend(height: CGFloat) -> some View {
        let now = Date()
        let labels = (0..<7).map { offset -> String in
            let date = Calendar.current.date(byAdding: .day, value: offset - 6, to: now) ?? now
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }

        let series = [
            HarborTrendSeriesData(
                id: "account",
                title: "账户",
                color: HarborColors.blue,
                values: model.codexRequestDailyCounts(for: .account, profileID: nil, days: 7, now: now)
            ),
            HarborTrendSeriesData(
                id: "hosted",
                title: "托管密钥",
                color: HarborColors.purple,
                values: model.codexRequestDailyCounts(for: .harborKey, profileID: nil, days: 7, now: now)
            ),
            HarborTrendSeriesData(
                id: "api",
                title: "自定义 API",
                color: HarborColors.green,
                values: model.codexRequestDailyCounts(for: .apiKey, profileID: nil, days: 7, now: now)
            )
        ]

        return HarborCard(padding: 14) {
            HarborInteractiveTrendChart(
                title: "近 7 天连接使用趋势",
                labels: labels,
                series: series,
                height: max(100, height - 58),
                compact: true
            )
        }
    }

    private func isConfigured(_ mode: BridgeTransportMode) -> Bool {
        switch mode {
        case .secureTunnel:
            return bridge.configuration.secureTunnel != nil && bridge.hasTunnelRuntimeKey
        case .httpsCompatibility:
            return bridge.configuration.httpsCompatibility != nil && bridge.hasPublicHTTPSAccessToken
        }
    }

    private func isAvailable(_ health: ConnectionHealth?) -> Bool {
        guard let health else { return false }
        if case .available = health { return true }
        return false
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func durationText(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "—" }
        if milliseconds < 1_000 {
            return "\(milliseconds) ms"
        }

        let totalSeconds = max(1, Int(round(Double(milliseconds) / 1_000)))
        if totalSeconds < 60 {
            return "\(totalSeconds) 秒"
        }

        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return seconds == 0 ? "\(minutes) 分" : "\(minutes) 分 \(seconds) 秒"
    }
}
