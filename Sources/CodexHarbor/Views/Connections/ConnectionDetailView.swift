import SwiftUI
import CodexHarborCore

private enum HarborConnectionDetailTab: String, CaseIterable, Identifiable {
    case overview = "概览"
    case usage = "使用统计"

    var id: String { rawValue }
}

enum HarborConnectionDetailTarget {
    case account(CodexAccountProfile)
    case profile(HarborProfile)
}

struct HarborConnectionDetailView: View {
    @ObservedObject var model: AppModel

    let target: HarborConnectionDetailTarget
    let onBack: () -> Void
    let onRenameAccount: (CodexAccountProfile) -> Void
    let onRenameProfile: (HarborProfile) -> Void
    let onDeleteAccount: (CodexAccountProfile) -> Void
    let onDeleteProfile: (HarborProfile) -> Void

    @State private var tab: HarborConnectionDetailTab = .overview

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Button(action: onBack) {
                Label("返回 Codex 连接", systemImage: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            .foregroundStyle(HarborColors.blue)

            header

            HarborSegmentControl(
                options: HarborConnectionDetailTab.allCases.map { ($0, $0.rawValue) },
                selection: $tab
            )
            .frame(width: 250)

            switch tab {
            case .overview:
                HarborConnectionInfoGrid(fields: overviewFields)
            case .usage:
                usageView
            }
        }
    }

    @ViewBuilder
    private var header: some View {
        switch target {
        case let .account(profile):
            let active = model.environment.activeMode == .chatGPT
                && model.selectedAccountProfileID == profile.id
            let diagnostic = model.accountProfileDiagnostics[profile.id]
            let health = model.accountProfileHealth[profile.id] ?? .unchecked

            HarborConnectionDetailHeader(
                name: profile.name,
                kind: profile.method.title,
                icon: "person.crop.circle.fill",
                providerIdentity: nil,
                status: healthTitle(health),
                active: active,
                modelName: active ? (model.environment.model ?? "—") : "—",
                latency: diagnostic?.latencyMilliseconds,
                lastChecked: diagnostic?.checkedAt,
                isBusy: model.isBusy,
                isCheckingHealth: model.isCheckingConnectionHealth,
                canDelete: !active,
                activate: { Task { await model.switchAccount(to: profile.id) } },
                test: { Task { await model.refreshConnectionHealth() } },
                rename: { onRenameAccount(profile) },
                delete: { onDeleteAccount(profile) }
            )

        case let .profile(profile):
            let kind = profile.kind.connectionKind
            let active = model.environment.activeMode == .harbor
                && model.activeProfileID == profile.id
            let diagnostic = model.apiProfileDiagnostics[profile.id]
            let health = model.apiProfileHealth[profile.id] ?? .unchecked

            HarborConnectionDetailHeader(
                name: profile.name,
                kind: profile.kind == .harbor ? "托管密钥" : "\(profile.provider.title) · 自定义 API",
                icon: profile.kind == .harbor ? "key.fill" : "globe",
                providerIdentity: profile.kind == .customResponses
                    ? ProviderCatalog.identity(for: profile.apiBaseURL)
                    : nil,
                status: healthTitle(health),
                active: active,
                modelName: profile.model.isEmpty
                    ? (active ? (model.environment.model ?? "—") : "—")
                    : profile.model,
                latency: diagnostic?.latencyMilliseconds,
                lastChecked: diagnostic?.checkedAt,
                isBusy: model.isBusy,
                isCheckingHealth: model.isCheckingConnectionHealth,
                canDelete: !active,
                activate: { Task { await model.switchProfile(to: profile.id) } },
                test: { Task { await model.refreshConnectionHealth() } },
                rename: { onRenameProfile(profile) },
                delete: { onDeleteProfile(profile) }
            )

            let _ = kind
        }
    }

    private var overviewFields: [(String, String)] {
        switch target {
        case let .account(profile):
            return [
                ("名称", profile.name),
                ("类型", profile.method.title),
                ("状态", healthTitle(model.accountProfileHealth[profile.id] ?? .unchecked)),
                ("会员类型", profile.subscriptionPlanTitle ?? "—"),
                ("到期时间", profile.subscriptionExpiryDate()?.formatted(date: .abbreviated, time: .shortened) ?? "暂无"),
                ("最近使用", lastUsedText(kind: .account, profileID: profile.id))
            ]

        case let .profile(profile):
            return [
                ("名称", profile.name),
                ("类型", profile.kind == .harbor ? "托管密钥" : "自定义 API"),
                ("状态", healthTitle(model.apiProfileHealth[profile.id] ?? .unchecked)),
                ("服务地址", profile.apiBaseURL.absoluteString),
                ("当前模型", profile.model.isEmpty ? "由服务端选择" : profile.model),
                ("最近使用", lastUsedText(kind: profile.kind.connectionKind, profileID: profile.id))
            ]
        }
    }

    private var usageView: some View {
        let identity = usageIdentity
        let since = Calendar.current.date(byAdding: .day, value: -6, to: Calendar.current.startOfDay(for: Date()))
            ?? Calendar.current.startOfDay(for: Date())
        let metrics = model.codexRequestMetrics(for: identity.kind, profileID: identity.profileID, since: since)
        let tokens = model.codexTokenSummary(for: identity.kind, profileID: identity.profileID, since: since).totalTokens
        let durations = model.activityEvents
            .filter {
                $0.kind == .codexRequest
                    && $0.connectionKind == identity.kind
                    && $0.timestamp >= since
                    && (identity.profileID == nil || $0.profileID == identity.profileID)
            }
            .compactMap(\.durationMilliseconds)
        let average = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count
        let now = Date()
        let daily = model.codexRequestDailyCounts(
            for: identity.kind,
            profileID: identity.profileID,
            days: 7,
            now: now
        )
        let labels = (0..<7).map { offset -> String in
            let date = Calendar.current.date(byAdding: .day, value: offset - 6, to: now) ?? now
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }

        return VStack(alignment: .leading, spacing: 14) {
            HarborCard(padding: 0) {
                HStack(spacing: 0) {
                    usageMetric("请求数", value: metrics.count.formatted(), color: HarborColors.blue)

                    Divider()
                        .frame(height: 48)
                        .opacity(0.38)

                    usageMetric("Token", value: compactNumber(tokens), color: HarborColors.purple)

                    Divider()
                        .frame(height: 48)
                        .opacity(0.38)

                    usageMetric("成功率", value: successText(metrics.count, metrics.successfulCount), color: HarborColors.green)

                    Divider()
                        .frame(height: 48)
                        .opacity(0.38)

                    usageMetric("平均响应", value: durationText(average), color: HarborColors.orange)
                }
                .frame(maxWidth: .infinity, minHeight: 78)
            }

            HarborCard(padding: 14) {
                HarborInteractiveTrendChart(
                    title: "近 7 天请求趋势",
                    labels: labels,
                    series: [
                        HarborTrendSeriesData(
                            id: "current",
                            title: "当前连接",
                            color: HarborColors.blue,
                            values: daily
                        )
                    ],
                    height: 210,
                    compact: false
                )
            }
        }
    }

    private var usageIdentity: (kind: CodexConnectionKind, profileID: UUID?) {
        switch target {
        case let .account(profile):
            return (.account, profile.id)
        case let .profile(profile):
            return (profile.kind.connectionKind, profile.id)
        }
    }

    private func usageMetric(_ title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Capsule()
                    .fill(color)
                    .frame(width: 16, height: 4)

                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            Text(value)
                .font(.system(size: 18, weight: .bold, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .padding(.horizontal, 18)
        .frame(maxWidth: .infinity, minHeight: 78, alignment: .leading)
    }

    private func lastUsedText(kind: CodexConnectionKind, profileID: UUID?) -> String {
        let event = model.activityEvents.last {
            $0.kind == .codexRequest
                && $0.connectionKind == kind
                && (profileID == nil || $0.profileID == profileID)
        }

        return event?.timestamp.formatted(date: .abbreviated, time: .shortened) ?? "暂无"
    }

    private func healthTitle(_ health: ConnectionHealth) -> String {
        switch health {
        case .unchecked: "待检查"
        case .checking: "检查中"
        case .available: "可用"
        case .expired: "已过期"
        case .unavailable: "不可用"
        }
    }

    private func compactNumber(_ value: Int) -> String {
        if value >= 100_000_000 {
            return "\((Double(value) / 100_000_000).formatted(.number.precision(.fractionLength(1))))亿"
        }
        if value >= 10_000 {
            return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(1))))万"
        }
        return value.formatted()
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

    private func successText(_ count: Int, _ successful: Int) -> String {
        guard count > 0 else { return "—" }
        return (Double(successful) / Double(count))
            .formatted(.percent.precision(.fractionLength(0)))
    }
}
