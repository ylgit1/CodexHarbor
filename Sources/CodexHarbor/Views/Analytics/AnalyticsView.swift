import SwiftUI
import CodexHarborCore

private enum HarborAnalyticsRange: String, CaseIterable, Identifiable {
    case today = "今日"
    case sevenDays = "7日"
    case month = "当月"

    var id: String { rawValue }
}

private enum HarborAnalyticsMetric: String, CaseIterable, Identifiable {
    case requests = "请求数"
    case token = "Token"
    case latency = "响应"

    var id: String { rawValue }
}

struct HarborAnalyticsView: View {
    @ObservedObject var model: AppModel

    @State private var range: HarborAnalyticsRange = .sevenDays
    @State private var metric: HarborAnalyticsMetric = .requests

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 15) {
                header
                summaryCards
                trendCard
                performanceCard
            }
            .frame(maxWidth: 1220)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text("使用统计")
                .font(.system(size: 22, weight: .bold, design: .rounded))

            Spacer()

            HarborSegmentControl(
                options: HarborAnalyticsRange.allCases.map { ($0, $0.rawValue) },
                selection: $range
            )
            .frame(width: 200)

            HarborSegmentControl(
                options: HarborAnalyticsMetric.allCases.map { ($0, $0.rawValue) },
                selection: $metric
            )
            .frame(width: 220)
        }
    }

    private var summaryCards: some View {
        let kinds: [CodexConnectionKind] = [.account, .harborKey, .apiKey]
        let since = startDate
        let requestMetrics = kinds.map { model.codexRequestMetrics(for: $0, profileID: nil, since: since) }
        let requestCount = requestMetrics.reduce(0) { $0 + $1.count }
        let successful = requestMetrics.reduce(0) { $0 + $1.successfulCount }
        let tokenCount = kinds.reduce(0) {
            $0 + model.codexTokenSummary(for: $1, profileID: nil, since: since).totalTokens
        }
        let durations = model.activityEvents
            .filter { $0.kind == .codexRequest && $0.timestamp >= since }
            .compactMap(\.durationMilliseconds)
        let averageDuration = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count

        return HStack(spacing: 10) {
            metricCard("请求数", value: requestCount.formatted(), icon: "paperplane.fill", color: HarborColors.blue)
            metricCard("Token", value: compactNumber(tokenCount), icon: "square.stack.3d.up.fill", color: HarborColors.purple)
            metricCard("平均响应", value: durationText(averageDuration), icon: "clock.fill", color: HarborColors.orange)
            metricCard(
                "成功率",
                value: requestCount > 0
                    ? (Double(successful) / Double(requestCount)).formatted(.percent.precision(.fractionLength(0)))
                    : "—",
                icon: "checkmark.shield.fill",
                color: HarborColors.green
            )
        }
        .frame(height: 104)
    }

    private var trendCard: some View {
        HarborCard(padding: 16) {
            HarborInteractiveTrendChart(
                title: "使用趋势 · \(metric.rawValue)",
                labels: trendLabels,
                series: trendSeries,
                height: 290,
                compact: false
            )
        }
    }

    private var performanceCard: some View {
        let rows: [(CodexConnectionKind, String, Color)] = [
            (.account, "账户", HarborColors.blue),
            (.harborKey, "托管密钥", HarborColors.purple),
            (.apiKey, "自定义 API", HarborColors.green)
        ]

        return HarborCard(padding: 0) {
            VStack(spacing: 0) {
                HStack {
                    Text("连接类型")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("请求数")
                        .frame(width: 90, alignment: .trailing)
                    Text("成功率")
                        .frame(width: 90, alignment: .trailing)
                    Text("平均响应")
                        .frame(width: 110, alignment: .trailing)
                }
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 38)
                .background(Color.primary.opacity(0.022))

                Divider().opacity(0.4)

                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    performanceRow(kind: row.0, title: row.1, color: row.2)
                    if index < rows.count - 1 {
                        Divider().opacity(0.35).padding(.leading, 16)
                    }
                }
            }
        }
    }

    private func performanceRow(kind: CodexConnectionKind, title: String, color: Color) -> some View {
        let metrics = model.codexRequestMetrics(for: kind, profileID: nil, since: startDate)
        let durations = model.activityEvents
            .filter {
                $0.kind == .codexRequest
                    && $0.connectionKind == kind
                    && $0.timestamp >= startDate
            }
            .compactMap(\.durationMilliseconds)
        let average = durations.isEmpty ? nil : durations.reduce(0, +) / durations.count

        return HStack {
            HStack(spacing: 9) {
                Circle()
                    .fill(color)
                    .frame(width: 8, height: 8)
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Text(metrics.count.formatted())
                .monospacedDigit()
                .frame(width: 90, alignment: .trailing)

            Text(
                metrics.count > 0
                    ? (Double(metrics.successfulCount) / Double(metrics.count))
                        .formatted(.percent.precision(.fractionLength(0)))
                    : "—"
            )
            .monospacedDigit()
            .frame(width: 90, alignment: .trailing)

            Text(durationText(average))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .frame(width: 110, alignment: .trailing)
        }
        .font(.system(size: 11))
        .padding(.horizontal, 16)
        .frame(height: 50)
    }

    private func metricCard(_ title: String, value: String, icon: String, color: Color) -> some View {
        HarborCard(padding: 14) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(color)
                    .frame(width: 38, height: 38)
                    .background(color.opacity(0.09), in: RoundedRectangle(cornerRadius: 11))

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                    Text(value)
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                }

                Spacer(minLength: 0)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func legend(_ title: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Circle()
                .fill(color)
                .frame(width: 7, height: 7)
            Text(title)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(.secondary)
        }
    }

    private var startDate: Date {
        let calendar = Calendar.current
        let now = Date()
        switch range {
        case .today:
            return calendar.startOfDay(for: now)
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now))
                ?? calendar.startOfDay(for: now)
        case .month:
            return calendar.date(from: calendar.dateComponents([.year, .month], from: now))
                ?? calendar.startOfDay(for: now)
        }
    }

    private var trendSeries: [HarborTrendSeriesData] {
        let now = Date()
        let kinds: [(CodexConnectionKind, String, Color)] = [
            (.account, "账户", HarborColors.blue),
            (.harborKey, "托管密钥", HarborColors.purple),
            (.apiKey, "自定义 API", HarborColors.green)
        ]

        return kinds.map { kind, title, color in
            let values: [Int]
            switch (range, metric) {
            case (.today, .requests):
                values = model.codexRequestHourlyCounts(for: kind, profileID: nil, now: now, since: startDate)
            case (.today, .token):
                values = model.codexTokenHourlyCounts(for: kind, profileID: nil, now: now, since: startDate)
            case (.today, .latency):
                values = model.codexResponseHourlyAverages(for: kind, profileID: nil, now: now, since: startDate)
            case (_, .requests):
                values = model.codexRequestDailyCounts(for: kind, profileID: nil, days: dayCount, now: now)
            case (_, .token):
                values = model.codexTokenDailyCounts(for: kind, profileID: nil, days: dayCount, now: now)
            case (_, .latency):
                values = model.codexResponseDailyAverages(for: kind, profileID: nil, days: dayCount, now: now)
            }

            return HarborTrendSeriesData(id: kind.rawValue, title: title, color: color, values: values)
        }
    }

    private var trendLabels: [String] {
        let now = Date()
        let calendar = Calendar.current

        if range == .today {
            let currentHour = calendar.component(.hour, from: now)
            return Array(0...currentHour).map { String(format: "%02d:00", $0) }
        }

        return (0..<dayCount).map { offset in
            let date = calendar.date(byAdding: .day, value: offset - (dayCount - 1), to: now) ?? now
            return date.formatted(.dateTime.month(.twoDigits).day(.twoDigits))
        }
    }

    private var dayCount: Int {
        switch range {
        case .today:
            return 1
        case .sevenDays:
            return 7
        case .month:
            return max(1, Calendar.current.component(.day, from: Date()))
        }
    }

    private func linePath(values: [Int], maxValue: Int, size: CGSize) -> Path {
        var path = Path()
        guard !values.isEmpty else { return path }

        let width = max(size.width, 1)
        let height = max(size.height, 1)
        let denominator = max(values.count - 1, 1)

        for index in values.indices {
            let x = width * CGFloat(index) / CGFloat(denominator)
            let normalized = CGFloat(values[index]) / CGFloat(maxValue)
            let y = height - (normalized * max(height - 10, 1)) - 5
            let point = CGPoint(x: x, y: y)

            if index == values.startIndex {
                path.move(to: point)
            } else {
                path.addLine(to: point)
            }
        }

        return path
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

    private func compactNumber(_ value: Int) -> String {
        if value >= 100_000_000 {
            return "\((Double(value) / 100_000_000).formatted(.number.precision(.fractionLength(1))))亿"
        }
        if value >= 10_000 {
            return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(1))))万"
        }
        return value.formatted()
    }
}
