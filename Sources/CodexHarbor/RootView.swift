import CodexHarborCore
import AppKit
import SwiftUI
import UniformTypeIdentifiers

private enum ProfileDeletionTarget: Identifiable {
    case account(CodexAccountProfile)
    case api(HarborProfile)

    var id: String {
        switch self {
        case let .account(profile): "account-\(profile.id.uuidString)"
        case let .api(profile): "api-\(profile.id.uuidString)"
        }
    }

    var name: String {
        switch self {
        case let .account(profile): profile.name
        case let .api(profile): profile.name
        }
    }

    var profileID: UUID {
        switch self {
        case let .account(profile): profile.id
        case let .api(profile): profile.id
        }
    }
}

private enum ProfileRenameTarget: Identifiable {
    case account(CodexAccountProfile)
    case api(HarborProfile)

    var id: String {
        switch self {
        case let .account(profile): "account-\(profile.id.uuidString)"
        case let .api(profile): "api-\(profile.id.uuidString)"
        }
    }

    var profileID: UUID {
        switch self {
        case let .account(profile): profile.id
        case let .api(profile): profile.id
        }
    }

    var name: String {
        switch self {
        case let .account(profile): profile.name
        case let .api(profile): profile.name
        }
    }
}

private struct ProfileDropDelegate: DropDelegate {
    let targetID: UUID
    let draggedID: () -> UUID?
    let reorder: (UUID, UUID) -> Void
    let finish: () -> Void

    func dropEntered(info: DropInfo) {
        guard let sourceID = draggedID(), sourceID != targetID else { return }
        reorder(sourceID, targetID)
    }

    func performDrop(info: DropInfo) -> Bool {
        finish()
        return true
    }
}

private struct HarborActivityTrendChart: View {
    let summaries: [(mode: CodexConnectionKind, summary: ConnectionActivitySummary, color: Color)]
    var tokenCountsByMode: [CodexConnectionKind: [Int]] = [:]
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = false

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let plotHeight = max(1, height - 24)
            let maxValue = max(1, summaries.flatMap { $0.summary.dailyCounts.map(\.count) }.max() ?? 0)
            let dayLabels = summaries.first?.summary.dailyCounts ?? []

            ZStack(alignment: .bottomLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<4, id: \.self) { index in
                        Rectangle()
                            .fill(Color.primary.opacity(index == 3 ? 0.10 : 0.055))
                            .frame(height: 1)
                        if index < 3 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: plotHeight)

                ForEach(summaries, id: \.mode) { item in
                    trendLine(
                        counts: item.summary.dailyCounts.map(\.count),
                        tokenCounts: tokenCountsByMode[item.mode] ?? [],
                        color: item.color,
                        width: width,
                        height: plotHeight,
                        maxValue: maxValue
                    )
                }

                HStack(spacing: 0) {
                    ForEach(Array(dayLabels.enumerated()), id: \.offset) { index, day in
                        Text(index == dayLabels.count - 1 ? "今天" : day.date.formatted(.dateTime.month(.abbreviated).day()))
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity)
                    }
                }
                .frame(height: 18)
            }
        }
        .clipped()
        .opacity(reveal || reduceMotion ? 1 : 0.35)
        .offset(y: reveal || reduceMotion ? 0 : 6)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.38)) {
                reveal = true
            }
        }
    }

    private func trendLine(
        counts: [Int],
        tokenCounts: [Int],
        color: Color,
        width: CGFloat,
        height: CGFloat,
        maxValue: Int
    ) -> some View {
        let points = counts.enumerated().map { index, count in
            CGPoint(
                x: counts.count <= 1 ? width / 2 : width * CGFloat(index) / CGFloat(counts.count - 1),
                y: height - (CGFloat(count) / CGFloat(maxValue)) * (height - 12) - 6
            )
        }

        return ZStack {
            if points.count > 1 {
                Path { path in
                    path.move(to: CGPoint(x: points[0].x, y: height))
                    for point in points {
                        path.addLine(to: point)
                    }
                    path.addLine(to: CGPoint(x: points[points.count - 1].x, y: height))
                    path.closeSubpath()
                }
                .fill(color.opacity(0.055))
            }

            Path { path in
                guard let first = points.first else { return }
                path.move(to: first)
                for point in points.dropFirst() {
                    path.addLine(to: point)
                }
            }
            .stroke(color.opacity(0.84), style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))

            ForEach(Array(points.enumerated()), id: \.offset) { index, point in
                Circle()
                    .fill(Color(nsColor: .windowBackgroundColor))
                    .frame(width: 7, height: 7)
                    .overlay(Circle().stroke(color, lineWidth: 2))
                    .position(point)
                    .help(tokenTooltip(requests: counts[safe: index] ?? 0, tokens: tokenCounts[safe: index]))
            }
        }
    }

    private func formatCompactToken(_ value: Int) -> String {
        if value >= 100_000_000 { return "\((Double(value) / 100_000_000).formatted(.number.precision(.fractionLength(1))))亿" }
        if value >= 10_000 { return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(1))))万" }
        return "\(value.formatted(.number)) 个"
    }

    private func tokenTooltip(requests: Int, tokens: Int?) -> String {
        "请求 \(requests) 次 · Token \(tokens.map(formatCompactToken) ?? "暂无")"
    }
}

private enum TrendRange: String, CaseIterable {
    case today = "今日"
    case sevenDays = "近 7 日"
    case month = "当月"
}

private enum TrendMetric: String, CaseIterable {
    case token = "Token 用量"
    case requests = "请求次数"
    case latency = "响应耗时"

    var unit: String {
        switch self {
        case .token: "单位：个"
        case .requests: "单位：次"
        case .latency: "单位：毫秒"
        }
    }
}

private struct MonthlyTokenSummaryBadge: View {
    let total: Int
    let accountTokens: Int
    let harborTokens: Int
    let apiTokens: Int

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var pulse = false

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: "number")
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(.purple)
                .frame(width: 24, height: 24)
                .background(Color.purple.opacity(0.11), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .scaleEffect(pulse && !reduceMotion ? 1.08 : 1)
                .rotationEffect(.degrees(pulse && !reduceMotion ? 3 : 0))

            VStack(alignment: .leading, spacing: 2) {
                Text("全部模式 · 本月")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
                Text(formatTokenCount(total))
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(.purple)
                    .lineLimit(1)
                    .contentTransition(.numericText(value: Double(total)))
            }
        }
        .padding(.horizontal, 8)
        .frame(minWidth: 118, minHeight: 38, maxHeight: 38, alignment: .leading)
        .background(Color.purple.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.purple.opacity(0.12), lineWidth: 1)
        )
        .help(
            "本月全部模式合计：账户 \(formatTokenCount(accountTokens)) · 托管 \(formatTokenCount(harborTokens)) · 自定义 API \(formatTokenCount(apiTokens))"
        )
        .accessibilityElement(children: .combine)
        .accessibilityLabel("本月全部模式 Token 使用量")
        .accessibilityValue(formatTokenCount(total))
        .onChange(of: total) { _, _ in
            guard !reduceMotion else { return }
            pulse = true
            withAnimation(.easeOut(duration: 0.34)) {
                pulse = false
            }
        }
    }

    private func formatTokenCount(_ value: Int) -> String {
        if value >= 100_000_000 {
            return "\((Double(value) / 100_000_000).formatted(.number.precision(.fractionLength(1))))亿"
        }
        if value >= 10_000 {
            return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(1))))万"
        }
        return "\(value.formatted(.number)) 个"
    }
}

private struct HoverLocationReader: NSViewRepresentable {
    let onMove: (CGPoint) -> Void
    let onExit: () -> Void

    func makeNSView(context: Context) -> TrackingView {
        let view = TrackingView()
        view.onMove = onMove
        view.onExit = onExit
        return view
    }

    func updateNSView(_ nsView: TrackingView, context: Context) {
        nsView.onMove = onMove
        nsView.onExit = onExit
    }

    final class TrackingView: NSView {
        var onMove: ((CGPoint) -> Void)?
        var onExit: (() -> Void)?
        private var trackingArea: NSTrackingArea?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            window?.acceptsMouseMovedEvents = true
        }

        override func updateTrackingAreas() {
            if let trackingArea { removeTrackingArea(trackingArea) }
            let area = NSTrackingArea(
                rect: bounds,
                options: [.activeInKeyWindow, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect],
                owner: self,
                userInfo: nil
            )
            addTrackingArea(area)
            trackingArea = area
            super.updateTrackingAreas()
        }

        override func mouseMoved(with event: NSEvent) {
            onMove?(convert(event.locationInWindow, from: nil))
        }

        override func mouseExited(with event: NSEvent) {
            onExit?()
        }
    }
}

private struct HarborTrendSeries: Identifiable {
    let id: String
    let title: String
    let values: [Int]
    let requestCounts: [Int]
    let color: Color
    let dash: [CGFloat]
}

private struct HarborTrendChart: View {
    let series: [HarborTrendSeries]
    let labels: [String]
    let metric: TrendMetric
    let accent: Color
    /// Position of the real current time within a full-day chart. Keeping the
    /// 24-hour axis makes gaps visible while the curve still ends at the
    /// actual current time.
    let currentFraction: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var reveal = false
    @State private var hoveredIndex: Int?
    @State private var hoverX: CGFloat?

    var body: some View {
        GeometryReader { proxy in
            let width = proxy.size.width
            let height = proxy.size.height
            let plotHeight = max(1, height - 22)
            let normalizedSeries = normalizedSeries(length: chartLength)
            let currentHourIndex = currentFraction.map {
                min(max(Int(floor($0 * 24)), 0), max(0, chartLength - 1))
            }
            let visibleIndices = currentHourIndex.map { Array(0...$0) } ?? Array(0..<chartLength)
            let visibleValues = normalizedSeries.flatMap { item in
                visibleIndices.compactMap { item.values[safe: $0] }
            }
            let maxValue = max(1, visibleValues.max() ?? 0)
            let allPoints = normalizedSeries.map { item in
                (series: item, points: points(for: item.values, visibleIndices: visibleIndices, currentHourIndex: currentHourIndex, currentFraction: currentFraction, width: width, plotHeight: plotHeight, maxValue: maxValue))
            }

            ZStack(alignment: .bottomLeading) {
                VStack(spacing: 0) {
                    ForEach(0..<3, id: \.self) { index in
                        Rectangle()
                            .fill(Color.primary.opacity(index == 2 ? 0.10 : 0.05))
                            .frame(height: 1)
                        if index < 2 { Spacer(minLength: 0) }
                    }
                }
                .frame(height: plotHeight)

                ForEach(allPoints, id: \.series.id) { item in
                    let points = item.points
                    if points.count > 1 {
                        if normalizedSeries.count == 1 {
                            Path { path in
                                path.move(to: CGPoint(x: points[0].x, y: plotHeight))
                                path.addLine(to: points[0])
                                appendSmoothCurveSegments(to: &path, points: points)
                                path.addLine(to: CGPoint(x: points[points.count - 1].x, y: plotHeight))
                                path.closeSubpath()
                            }
                            .fill(
                                LinearGradient(
                                    stops: [
                                        .init(color: item.series.color.opacity(0.24), location: 0),
                                        .init(color: item.series.color.opacity(0.075), location: 0.55),
                                        .init(color: item.series.color.opacity(0.008), location: 1)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .opacity(reveal || reduceMotion ? 1 : 0)
                        }

                        Path { path in
                            appendSmoothCurve(to: &path, points: points)
                        }
                        .trim(from: 0, to: reveal || reduceMotion ? 1 : 0)
                        .stroke(item.series.color.opacity(0.16), style: StrokeStyle(lineWidth: 8, lineCap: .round, lineJoin: .round, dash: item.series.dash))
                        .blur(radius: 5)

                        Path { path in
                            appendSmoothCurve(to: &path, points: points)
                        }
                        .trim(from: 0, to: reveal || reduceMotion ? 1 : 0)
                        .stroke(
                            item.series.color.opacity(0.90),
                            style: StrokeStyle(lineWidth: normalizedSeries.count == 1 ? 2.6 : 2.25, lineCap: .round, lineJoin: .round, dash: item.series.dash)
                        )

                        if let endpoint = points.last {
                            Circle()
                                .fill(item.series.color.opacity(0.12))
                                .frame(width: normalizedSeries.count == 1 ? 20 : 15, height: normalizedSeries.count == 1 ? 20 : 15)
                                .position(endpoint)
                                .allowsHitTesting(false)
                            Circle()
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 8, height: 8)
                                .overlay(Circle().stroke(item.series.color, lineWidth: 2))
                                .shadow(color: item.series.color.opacity(0.26), radius: 4)
                                .position(endpoint)
                                .allowsHitTesting(false)

                            if normalizedSeries.count > 1 {
                                Text(item.series.title)
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(item.series.color)
                                    .lineLimit(1)
                                    .padding(.horizontal, 5)
                                    .padding(.vertical, 2)
                                    .background(.regularMaterial, in: Capsule())
                                    .position(
                                        x: min(max(endpoint.x + 22, 32), max(32, width - 32)),
                                        y: min(max(endpoint.y - 10, 12), max(12, plotHeight - 8))
                                    )
                                    .allowsHitTesting(false)
                            }
                        }
                    } else if let point = points.first {
                        Circle()
                            .fill(item.series.color)
                            .frame(width: 6, height: 6)
                            .position(point)
                            .allowsHitTesting(false)
                    }
                }

                if let hoveredIndex,
                   visibleIndices.indices.contains(hoveredIndex) {
                    let sourceIndex = visibleIndices[hoveredIndex]
                    ForEach(allPoints, id: \.series.id) { item in
                        if item.points.indices.contains(hoveredIndex) {
                            Circle()
                                .fill(Color(nsColor: .windowBackgroundColor))
                                .frame(width: 9, height: 9)
                                .overlay(Circle().stroke(item.series.color, lineWidth: 2))
                                .position(item.points[hoveredIndex])
                                .allowsHitTesting(false)
                                .zIndex(2)
                        }
                    }

                    tooltipView(index: sourceIndex, series: normalizedSeries)
                        .position(
                            x: min(max(hoverX ?? width / 2, 94), max(94, width - 94)),
                            y: 24
                        )
                        .transition(.opacity.combined(with: .scale(scale: 0.94)))
                        .zIndex(2)
                }

                if let hoverX {
                    Rectangle()
                        .fill(accent.opacity(0.22))
                        .frame(width: 1, height: plotHeight)
                        .position(x: hoverX, y: plotHeight / 2)
                        .allowsHitTesting(false)
                        .zIndex(1)
                }

                HoverLocationReader { point in
                    guard width > 0, !visibleIndices.isEmpty else { return }
                    let x = min(max(point.x, 0), width)
                    let samplePoints = allPoints.first?.points ?? []
                    guard x <= (samplePoints.last?.x ?? width) + 8 else {
                        hoverX = nil
                        hoveredIndex = nil
                        return
                    }
                    let index = samplePoints.indices.min { lhs, rhs in
                        abs(samplePoints[lhs].x - x) < abs(samplePoints[rhs].x - x)
                    } ?? 0
                    withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.08)) {
                        hoverX = x
                        hoveredIndex = index
                    }
                } onExit: {
                    withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.10)) {
                        hoverX = nil
                        hoveredIndex = nil
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(true)

                HStack(spacing: 0) {
                    ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                        Text(axisLabel(for: index, label: label))
                        if index < labels.count - 1 { Spacer() }
                    }
                }
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(height: 14)
            }
        }
        .clipped()
        .opacity(reveal || reduceMotion ? 1 : 0.3)
        .offset(y: reveal || reduceMotion ? 0 : 4)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.28),
            value: series.map(\.values)
        )
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeOut(duration: 0.46)) { reveal = true }
        }
    }

    private var chartLength: Int {
        max(1, series.map { $0.values.count }.max() ?? max(1, labels.count))
    }

    private func normalizedSeries(length: Int) -> [HarborTrendSeries] {
        let fallback = HarborTrendSeries(
            id: "empty",
            title: "暂无",
            values: Array(repeating: 0, count: length),
            requestCounts: Array(repeating: 0, count: length),
            color: accent,
            dash: []
        )
        let source = series.isEmpty ? [fallback] : series
        return source.map { item in
            HarborTrendSeries(
                id: item.id,
                title: item.title,
                values: padded(item.values, length: length),
                requestCounts: padded(item.requestCounts, length: length),
                color: item.color,
                dash: item.dash
            )
        }
    }

    private func padded(_ values: [Int], length: Int) -> [Int] {
        if values.count == length { return values }
        if values.count > length { return Array(values.prefix(length)) }
        return values + Array(repeating: 0, count: length - values.count)
    }

    private func points(
        for values: [Int],
        visibleIndices: [Int],
        currentHourIndex: Int?,
        currentFraction: Double?,
        width: CGFloat,
        plotHeight: CGFloat,
        maxValue: Int
    ) -> [CGPoint] {
        visibleIndices.enumerated().map { displayIndex, sourceIndex in
            let x: CGFloat
            if let currentFraction, sourceIndex == currentHourIndex {
                x = width * CGFloat(min(max(currentFraction, 0), 1))
            } else if currentFraction != nil {
                x = width * CGFloat(sourceIndex) / 24
            } else {
                x = visibleIndices.count <= 1
                    ? width / 2
                    : width * CGFloat(displayIndex) / CGFloat(visibleIndices.count - 1)
            }
            return CGPoint(
                x: x,
                y: plotHeight - (CGFloat(values[sourceIndex]) / CGFloat(maxValue)) * (plotHeight - 18) - 8
            )
        }
    }

    /// Draw a smooth Catmull–Rom style curve through the hourly points.
    /// This keeps the chart light while giving the detail panel the gentle,
    /// breathing arc requested by the UI direction.
    private func appendSmoothCurve(to path: inout Path, points: [CGPoint]) {
        guard let first = points.first else { return }
        path.move(to: first)
        appendSmoothCurveSegments(to: &path, points: points)
    }

    private func appendSmoothCurveSegments(to path: inout Path, points: [CGPoint]) {
        guard points.count > 1 else { return }
        for index in 0..<(points.count - 1) {
            let p0 = index > 0 ? points[index - 1] : points[index]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = index + 2 < points.count ? points[index + 2] : p2
            let c1 = CGPoint(
                x: p1.x + (p2.x - p0.x) / 6,
                y: p1.y + (p2.y - p0.y) / 6
            )
            let c2 = CGPoint(
                x: p2.x - (p3.x - p1.x) / 6,
                y: p2.y - (p3.y - p1.y) / 6
            )
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
    }

    private func formatCompactToken(_ value: Int) -> String {
        if value >= 100_000_000 { return "\((Double(value) / 100_000_000).formatted(.number.precision(.fractionLength(1))))亿" }
        if value >= 10_000 { return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(1))))万" }
        return "\(value.formatted(.number)) 个"
    }

    private func tooltipView(index: Int, series: [HarborTrendSeries]) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(labels[safe: index] ?? "")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.primary)
            ForEach(series, id: \.id) { item in
                HStack(spacing: 5) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)
                    Text(item.title)
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Text(metricValueText(value: item.values[safe: index] ?? 0, requests: item.requestCounts[safe: index] ?? 0))
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(width: series.count > 1 ? 188 : 138, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(accent.opacity(0.22)))
        .shadow(color: .black.opacity(0.12), radius: 4, y: 2)
    }

    private func metricValueText(value: Int, requests: Int) -> String {
        let valueText: String
        switch metric {
        case .token: valueText = "Token \(formatCompactToken(value))"
        case .requests: valueText = "请求 \(value) 次"
        case .latency: valueText = "平均响应 \(value)ms"
        }
        return metric == .requests ? valueText : "\(valueText) · \(requests) 次"
    }

    private func axisLabel(for index: Int, label: String) -> String {
        guard labels.count > 7 else { return label }
        return index == 0 || index == labels.count / 2 || index == labels.count - 1 ? label : ""
    }
}

private extension Collection {
    subscript(safe index: Index) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

private struct HarborMetricIcon: View {
    let icon: String
    let color: Color

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPulsing = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(color.opacity(0.11))
                .overlay(
                    RoundedRectangle(cornerRadius: 9, style: .continuous)
                        .stroke(color.opacity(isPulsing ? 0.24 : 0.12), lineWidth: 1)
                )
            Image(systemName: icon)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(color)
                .scaleEffect(isPulsing && !reduceMotion ? 1.07 : 1)
        }
        .frame(width: 28, height: 28)
        .onAppear {
            guard !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.8).repeatForever(autoreverses: true)) {
                isPulsing = true
            }
        }
    }
}

private struct HarborActionButtonStyle: ButtonStyle {
    enum Prominence {
        case prominent
        case secondary
    }

    let tint: Color
    let prominence: Prominence

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.caption.weight(.semibold))
            .foregroundStyle(prominence == .prominent ? Color.white : tint)
            .padding(.horizontal, prominence == .prominent ? 14 : 12)
            .frame(minHeight: prominence == .prominent ? 32 : 30)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(
                        prominence == .prominent
                            ? tint.opacity(configuration.isPressed ? 0.82 : 0.96)
                            : tint.opacity(configuration.isPressed ? 0.16 : 0.075)
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(tint.opacity(prominence == .prominent ? 0.16 : 0.24), lineWidth: 1)
            )
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.965 : 1)
            .shadow(
                color: prominence == .prominent ? tint.opacity(configuration.isPressed ? 0.08 : 0.18) : .clear,
                radius: configuration.isPressed ? 3 : 6,
                y: configuration.isPressed ? 1 : 3
            )
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16),
                value: configuration.isPressed
            )
    }
}

private struct BreathingStatusDot: View {
    let color: Color
    let active: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isBreathing = false

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.16))
                .frame(width: 20, height: 20)
                .scaleEffect(active && isBreathing ? 1.22 : 0.76)
                .opacity(active ? (isBreathing ? 0.95 : 0.30) : 0)
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
        }
        .frame(width: 20, height: 20)
        .onAppear {
            guard active, !reduceMotion else { return }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
        .onChange(of: active) { _, newValue in
            guard newValue, !reduceMotion else {
                isBreathing = false
                return
            }
            withAnimation(.easeInOut(duration: 1.7).repeatForever(autoreverses: true)) {
                isBreathing = true
            }
        }
    }
}

private enum FlowStepState: Equatable {
    case idle
    case active
    case complete
}

private struct APIConnectionPreset: Identifiable {
    let id: String
    let name: String
    let baseURL: String

    static let common: [APIConnectionPreset] = [
        .init(id: "openai", name: "OpenAI", baseURL: "https://api.openai.com/v1"),
        .init(id: "kimi", name: "Kimi", baseURL: "https://api.moonshot.cn/v1"),
        .init(id: "qwen", name: "通义千问", baseURL: "https://dashscope.aliyuncs.com/compatible-mode/v1"),
        .init(id: "deepseek", name: "DeepSeek", baseURL: "https://api.deepseek.com/v1"),
        .init(id: "openrouter", name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1"),
        .init(id: "siliconflow", name: "SiliconFlow", baseURL: "https://api.siliconflow.cn/v1")
    ]
}

struct RootView: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsActivationKey = false
    @State private var showsNewActivationKey = false
    @State private var newActivationKey = ""
    @State private var newProfileAPIBaseURL = HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
    @State private var showsActivationSheet = false
    @State private var showsAccountSetupSheet = false
    @State private var showsCustomAPISheet = false
    @State private var customAPIName = ""
    @State private var customAPIKey = ""
    @State private var customAPIProvider: CustomAPIProvider = .openAI
    @State private var customAPIBaseURL = CustomAPIProvider.openAI.defaultBaseURL
    @State private var customAPIModel = ""
    @State private var showsCustomAPIKey = false
    @State private var deletionTarget: ProfileDeletionTarget?
    @State private var renameTarget: ProfileRenameTarget?
    @State private var renameText = ""
    @State private var libraryMode: CodexConnectionKind = .account
    @State private var isLogExpanded = false
    @State private var accountPulse = false
    @State private var pendingConnectionID: String?
    @State private var previewAccountID: UUID?
    @State private var previewAPIProfileID: UUID?
    @State private var didSeedLibraryMode = false
    @State private var queryingUsageProfileID: UUID?
    @State private var draggingProfileID: UUID?
    @State private var hoveredDetailKey: String?
    @State private var hoveredMode: CodexConnectionKind?
    @State private var hoveredProfileID: UUID?
    @State private var trendRange: TrendRange = .today
    @State private var trendMetric: TrendMetric = .token

    var body: some View {
        content
        .background(Color(nsColor: .textBackgroundColor))
        .sheet(isPresented: $showsActivationSheet) {
            activationSheet
        }
        .sheet(isPresented: $showsAccountSetupSheet) {
            accountSetupSheet
        }
        .sheet(isPresented: $showsCustomAPISheet) {
            customAPISheet
        }
        .confirmationDialog(
            "删除连接档案？",
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) { deleteSelectedProfile() }
            Button("取消", role: .cancel) { deletionTarget = nil }
        } message: {
            Text("将删除“\(deletionTarget?.name ?? "")”及其本地凭据；Codex 会话记录不会被删除。")
        }
        .alert("重命名连接档案", isPresented: Binding(
            get: { renameTarget != nil },
            set: { if !$0 { renameTarget = nil } }
        )) {
            TextField("连接名称", text: $renameText)
            Button("取消", role: .cancel) { renameTarget = nil }
            Button("保存") { renameSelectedProfile() }
                .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        } message: {
            Text("只修改 Harbor 中的显示名称，不会改变 Codex 配置。")
        }
        .onChange(of: showsAccountSetupSheet) {
            if showsAccountSetupSheet {
                model.resetAccountLoginFlow()
            }
        }
        .onChange(of: model.environment.activeMode, initial: true) {
            syncLibraryModeToActiveConnection()
        }
        .onChange(of: model.activeProfileID, initial: true) {
            syncLibraryModeToActiveConnection()
        }
        .onChange(of: model.isBusy) {
            if !model.isBusy {
                syncLibraryModeToActiveConnection()
                seedPreviewSelection(for: libraryMode)
            }
        }
        .onChange(of: libraryMode, initial: true) {
            seedPreviewSelection(for: libraryMode)
        }
    }

    private func syncLibraryModeToActiveConnection() {
        // Keep the user's selected tab stable while a connection transaction is
        // in flight. The live environment changes in several steps during a
        // switch; syncing on each intermediate change causes a visible flash
        // back to the previous list.
        guard !didSeedLibraryMode, !model.isBusy, pendingConnectionID == nil else { return }
        switch model.environment.activeMode {
        case .chatGPT:
            libraryMode = .account
            previewAccountID = model.selectedAccountProfileID
            didSeedLibraryMode = true
        case .harbor:
            libraryMode = activeHarborProfile?.kind.connectionKind ?? .harborKey
            previewAPIProfileID = model.activeProfileID
            didSeedLibraryMode = true
        case nil:
            if !model.accountProfiles.isEmpty || !model.profiles.isEmpty {
                libraryMode = !model.accountProfiles.isEmpty
                    ? .account
                    : (model.profiles.first?.kind.connectionKind ?? .account)
                didSeedLibraryMode = true
            }
        }
    }

    private func seedPreviewSelection(for mode: CodexConnectionKind) {
        switch mode {
        case .account:
            if previewAccountID == nil || !model.accountProfiles.contains(where: { $0.id == previewAccountID }) {
                previewAccountID = effectiveConnectionKind == .account
                    ? model.selectedAccountProfileID
                    : preferredAccountProfileID
            }
        case .harborKey, .apiKey:
            let candidates = model.profiles.filter { $0.kind.connectionKind == mode }
            if previewAPIProfileID == nil || !candidates.contains(where: { $0.id == previewAPIProfileID }) {
                previewAPIProfileID = effectiveConnectionKind == mode
                    ? model.activeProfileID
                    : preferredAPIProfileID(in: candidates)
            }
        }
    }

    private var preferredAccountProfileID: UUID? {
        model.accountProfiles.first(where: {
            if case .available = model.accountProfileHealth[$0.id] { return true }
            return false
        })?.id ?? model.accountProfiles.first?.id
    }

    private func preferredAPIProfileID(in profiles: [HarborProfile]) -> UUID? {
        profiles.first(where: {
            if case .available = model.apiProfileHealth[$0.id] { return true }
            return false
        })?.id ?? profiles.first?.id
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            currentConnectionStrip
            HStack(alignment: .top, spacing: 16) {
                sidebarPanel
                    .frame(width: 318)
                currentConnectionCard
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            }
        }
        .padding(.top, 48)
        .padding(.horizontal, 28)
        .padding(.bottom, 22)
        .frame(minWidth: 980, minHeight: 640, alignment: .top)
    }

    private var sidebarPanel: some View {
        VStack(spacing: 12) {
            modeBar
            profileLibrary
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 9) {
                    Text("Codex Harbor")
                        .font(.title2.weight(.bold))
                    Text(effectiveMode == nil ? "等待连接" : "Codex 已就绪")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.blue)
                }
            }

            Spacer(minLength: 20)
            monthlyTokenSummaryBadge
            Spacer(minLength: 18)
            statusPill
            Menu {
                Button {
                    Task {
                        await model.refreshEnvironment()
                        await model.refreshConnectionHealth()
                    }
                } label: {
                    Label("检查所有连接", systemImage: "checkmark.shield")
                }
                if model.environment.deploymentExists {
                    Divider()
                    Button(role: .destructive) {
                        Task { await model.uninstall() }
                    } label: {
                        Label("安全卸载配置", systemImage: "arrow.uturn.backward")
                    }
                }
                Divider()
                Toggle("到期与余额提醒", isOn: Binding(
                    get: { model.notificationsEnabled },
                    set: { enabled in Task { await model.setNotificationsEnabled(enabled) } }
                ))
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 30, height: 30)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("更多操作")
        }
    }

    private var modeBar: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack {
                Text("连接类型")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("仅浏览列表")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 5) {
                modeSelector(mode: .account, title: "账户", icon: "person.crop.circle.fill")
                modeSelector(mode: .harborKey, title: "托管", icon: "key.fill")
                modeSelector(mode: .apiKey, title: "API", icon: "network")
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color.primary.opacity(0.032), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.085))
        )
    }

    /// A compact, read-only reflection of Codex's live connection. Browsing a
    /// category below never changes this strip; it updates only after the
    /// configuration transaction succeeds and `environment` is re-inspected.
    private var currentConnectionStrip: some View {
        let kind = effectiveConnectionKind
        let profileName: String
        let kindTitle: String
        let status: ConnectionHealth
        let icon: String
        let tint: Color
        let metadata: String

        switch kind {
        case .account:
            let profile = model.accountProfiles.first(where: { $0.id == model.selectedAccountProfileID })
            profileName = profile?.name ?? "账户登录"
            kindTitle = "账户登录"
            status = profile.map { model.accountProfileHealth[$0.id] ?? .unchecked } ?? .unchecked
            icon = "person.crop.circle.fill"
            tint = .green
            metadata = [
                profile?.method.title,
                profile.map { "最近使用 \(relativeTime($0.lastUsedAt))" }
            ].compactMap { $0 }.joined(separator: " · ")
        case .harborKey:
            let profile = activeHarborProfile
            profileName = profile?.name ?? "托管密钥"
            kindTitle = "托管密钥"
            status = profile.map { model.apiProfileHealth[$0.id] ?? .unchecked } ?? .unchecked
            icon = "key.fill"
            tint = .blue
            metadata = hostedConnectionMetadata
        case .apiKey:
            let profile = activeHarborProfile
            profileName = profile?.name ?? "自定义 API"
            kindTitle = "自定义 API"
            status = profile.map { model.apiProfileHealth[$0.id] ?? .unchecked } ?? .unchecked
            icon = "network"
            tint = .purple
            metadata = profile.map {
                let identity = ProviderCatalog.identity(for: $0.apiBaseURL)
                return "\(identity.brand.title) · \(identity.protocolTitle)"
            } ?? "Responses API 兼容连接"
        case nil:
            profileName = "当前没有连接"
            kindTitle = ""
            status = .unchecked
            icon = "link.badge.plus"
            tint = .secondary
            metadata = "等待连接"
        }

        return HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(tint)
                .frame(width: 38, height: 38)
                .background(tint.opacity(0.10), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("当前连接")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(profileName)
                        .font(.callout.weight(.semibold))
                        .lineLimit(1)
                }
                Text(metadata)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            Spacer(minLength: 20)

            currentConnectionField(
                label: "模式",
                value: kindTitle.isEmpty ? "未连接" : kindTitle,
                color: tint
            )

            Divider().frame(height: 34)

            currentConnectionField(
                label: "当前模型",
                value: currentConnectionModel(for: kind),
                color: tint
            )

            Divider().frame(height: 34)

            currentConnectionField(
                label: "本月 Token",
                value: currentConnectionTokenText(for: kind),
                color: .purple
            )

            HStack(spacing: 5) {
                BreathingStatusDot(color: healthColor(status), active: kind != nil)
                Text(kind == nil ? "未连接" : healthTitle(status))
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(healthColor(status))
            }
        }
        .padding(.horizontal, 16)
        .frame(height: 58)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(tint.opacity(0.18))
        )
    }

    private var monthlyTokenSummaryBadge: some View {
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: Date())?.start
        let accountTokens = model.codexTokenSummary(
            for: .account,
            profileID: nil,
            since: monthStart
        ).totalTokens
        let harborTokens = model.codexTokenSummary(
            for: .harborKey,
            profileID: nil,
            since: monthStart
        ).totalTokens
        let apiTokens = model.codexTokenSummary(
            for: .apiKey,
            profileID: nil,
            since: monthStart
        ).totalTokens
        let total = accountTokens + harborTokens + apiTokens

        return MonthlyTokenSummaryBadge(
            total: total,
            accountTokens: accountTokens,
            harborTokens: harborTokens,
            apiTokens: apiTokens
        )
    }

    private func currentConnectionField(label: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: 150, alignment: .leading)
        }
    }

    private func currentConnectionModel(for kind: CodexConnectionKind?) -> String {
        switch kind {
        case .account:
            return model.environment.model ?? CodexDefaults.model
        case .harborKey:
            return CodexDefaults.model
        case .apiKey:
            return activeHarborProfile?.model ?? "未设置"
        case nil:
            return "—"
        }
    }

    private func currentConnectionTokenText(for kind: CodexConnectionKind?) -> String {
        guard let kind else { return "—" }
        let calendar = Calendar.current
        let monthStart = calendar.dateInterval(of: .month, for: Date())?.start
        let profileID: UUID?
        switch kind {
        case .account:
            profileID = model.selectedAccountProfileID
        case .harborKey, .apiKey:
            profileID = model.activeProfileID
        }
        let total = model.codexTokenSummary(
            for: kind,
            profileID: profileID,
            since: monthStart
        ).totalTokens
        return total > 0 ? formatTokenCount(total) : "暂无记录"
    }

    private var hostedConnectionMetadata: String {
        guard let usage = model.usage else { return "托管认证 · 用量待查询" }
        let remaining = formatCurrency(usage.remaining)
        let expiry = displayExpiry(usage.expiresAt ?? model.expiresAt)
        return "剩余 \(remaining) · 有效期 \(expiry)"
    }

    private var effectiveMode: CodexMode? {
        model.environment.activeMode
            ?? (model.environment.chatGPTSessionExists ? .chatGPT : nil)
    }

    private var effectiveConnectionKind: CodexConnectionKind? {
        switch effectiveMode {
        case .chatGPT: .account
        case .harbor: activeHarborProfile?.kind.connectionKind ?? .harborKey
        case nil: nil
        }
    }

    private func modeSelector(mode: CodexConnectionKind, title: String, icon: String) -> some View {
        let selected = libraryMode == mode
        let active = effectiveConnectionKind == mode
        let hovered = hoveredMode == mode
        let tint: Color = switch mode {
        case .account: .green
        case .harborKey: .blue
        case .apiKey: .purple
        }
        return Button {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.28, dampingFraction: 0.82)) {
                libraryMode = mode
            }
        } label: {
            VStack(spacing: 4) {
                Image(systemName: icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(selected ? tint : Color.primary.opacity(0.72))
                Text(title)
                    .font(.system(size: 10.5, weight: .semibold))
                    .foregroundStyle(selected ? tint : Color.primary.opacity(0.78))
            }
            .frame(maxWidth: .infinity, minHeight: 42)
            .contentShape(Rectangle())
            .background(
                selected
                    ? tint.opacity(0.11)
                    : (hovered ? tint.opacity(0.055) : Color.clear)
            )
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(selected ? tint.opacity(0.44) : Color.clear, lineWidth: selected ? 1 : 0)
            )
            .overlay(alignment: .topTrailing) {
                if active {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 6, height: 6)
                        .padding(5)
                        .accessibilityLabel("当前已激活")
                }
            }
        }
        .buttonStyle(.plain)
        .frame(maxWidth: .infinity, minHeight: 46, maxHeight: 46)
        .contentShape(Rectangle())
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveredMode = isHovering ? mode : nil
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16), value: hovered)
        .help(active ? "当前正在使用；点击查看档案" : "查看\(title)档案")
    }

    private var analyticsDashboard: some View {
        let summaries = analyticsSummaries
        let totalEvents = summaries.reduce(0) { $0 + $1.summary.eventsLast7Days }
        let weightedSuccessRate: Double? = {
            let events = summaries.reduce(0) { $0 + $1.summary.eventsLast7Days }
            guard events > 0 else { return nil }
            let successes = summaries.reduce(0) { $0 + $1.summary.successfulEventsLast7Days }
            return Double(successes) / Double(events)
        }()
        let allDurations = summaries.compactMap { $0.summary.averageDurationMilliseconds }
        let averageLatency = allDurations.isEmpty ? nil : allDurations.reduce(0, +) / allDurations.count
        let totalTokens = summaries.reduce(0) { total, item in
            total + model.codexTokenSummary(for: item.mode, profileID: nil).totalTokens
        }

        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("使用分析")
                        .font(.system(size: 21, weight: .bold, design: .rounded))
                    Text("最近 7 天 · Codex 请求统计")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 7) {
                    BreathingStatusDot(color: .green, active: true)
                    Text("实时更新")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                }
            }

            HStack(spacing: 10) {
                analyticsKPI(title: "7天请求", value: "\(totalEvents)", detail: "全部连接", icon: "arrow.up.right.circle.fill", color: .blue)
                analyticsKPI(title: "成功率", value: percentText(weightedSuccessRate), detail: "最近 7 天", icon: "checkmark.shield.fill", color: weightedSuccessRate == nil ? .secondary : .green)
                analyticsKPI(title: "平均响应", value: durationText(averageLatency), detail: "Codex 任务耗时", icon: "speedometer", color: latencyColor(averageLatency ?? 0))
                analyticsKPI(title: "Token", value: totalTokens > 0 ? formatTokenCount(totalTokens) : "暂无", detail: "Codex 实际记录", icon: "number", color: .purple)
            }
            .frame(height: 74)

            HStack(alignment: .top, spacing: 12) {
                analyticsTrendBoard
                analyticsPerformanceTable
                    .frame(width: 252)
            }
            .frame(maxWidth: .infinity, minHeight: 330, maxHeight: .infinity, alignment: .top)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private var analyticsSummaries: [(mode: CodexConnectionKind, summary: ConnectionActivitySummary, color: Color)] {
        [
            (.account, model.codexRequestSummary(for: .account), .green),
            (.harborKey, model.codexRequestSummary(for: .harborKey), .blue),
            (.apiKey, model.codexRequestSummary(for: .apiKey), .purple)
        ]
    }

    private func analyticsKPI(title: String, value: String, detail: String, icon: String, color: Color) -> some View {
        HStack(spacing: 9) {
            HarborMetricIcon(icon: icon, color: color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.system(size: 16, weight: .bold, design: .rounded))
                    .foregroundStyle(color)
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.78)
                Text(detail)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(
            LinearGradient(
                colors: [color.opacity(0.095), Color(nsColor: .textBackgroundColor)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(color.opacity(0.16))
        )
    }

    private var analyticsTrendBoard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("活动趋势")
                        .font(.callout.weight(.semibold))
                    Text("按模式统计 Codex 真实请求")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                HStack(spacing: 10) {
                    analyticsLegend("账户", color: .green)
                    analyticsLegend("托管", color: .blue)
                    analyticsLegend("API", color: .purple)
                }
            }

            HarborActivityTrendChart(
                summaries: analyticsSummaries,
                tokenCountsByMode: Dictionary(uniqueKeysWithValues: analyticsSummaries.map {
                    ($0.mode, model.codexTokenDailyCounts(for: $0.mode, profileID: nil))
                })
            )
                .frame(maxWidth: .infinity, minHeight: 278, maxHeight: .infinity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
    }

    private func analyticsLegend(_ title: String, color: Color) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title)
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
        }
    }

    private var analyticsPerformanceTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("连接表现")
                .font(.callout.weight(.semibold))
            HStack {
                Text("模式")
                Spacer()
                Text("请求")
                    .frame(width: 38, alignment: .trailing)
                Text("成功")
                    .frame(width: 48, alignment: .trailing)
                Text("Token")
                    .frame(width: 58, alignment: .trailing)
            }
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)

            ForEach(analyticsSummaries, id: \.mode) { item in
                let summary = item.summary
                HStack(spacing: 5) {
                    Circle().fill(item.color).frame(width: 7, height: 7)
                    Text(item.mode.title.replacingOccurrences(of: "自定义 API 密钥", with: "自定义 API"))
                        .font(.caption.weight(.semibold))
                        .lineLimit(1)
                    Spacer(minLength: 3)
                    Text("\(summary.eventsLast7Days)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.primary)
                        .frame(width: 38, alignment: .trailing)
                    Text(percentText(summary.successRate))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(summary.failedEventsLast7Days > 0 ? .orange : .green)
                        .frame(width: 48, alignment: .trailing)
                    let tokenSummary = model.codexTokenSummary(for: item.mode, profileID: nil)
                    Text(tokenSummary.totalTokens > 0 ? formatTokenCount(tokenSummary.totalTokens) : "—")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .frame(width: 58, alignment: .trailing)
                }
                .padding(.vertical, 7)
                .padding(.horizontal, 8)
                .background(item.color.opacity(0.045), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }

            Spacer(minLength: 0)
            Text("数据来自 Codex 本地任务记录，不代表服务商账单用量")
                .font(.system(size: 9.5))
                .foregroundStyle(.tertiary)
                .lineLimit(2)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
    }

    private var analyticsRecentActivity: some View {
        let recent = model.activityEvents.sorted { $0.timestamp > $1.timestamp }.prefix(4)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("最近活动")
                    .font(.callout.weight(.semibold))
                Spacer()
                Text("\(model.activityEvents.count) 条记录")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            if recent.isEmpty {
                HStack {
                    Image(systemName: "waveform.path.ecg")
                        .foregroundStyle(.secondary)
                    Text("完成一次连接检查、查询或切换后，这里会显示活动记录")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
            } else {
                VStack(spacing: 0) {
                    ForEach(Array(recent), id: \.id) { event in
                        HStack(spacing: 8) {
                            Circle()
                                .fill(event.succeeded ? Color.green : Color.red)
                                .frame(width: 7, height: 7)
                            Text(event.kind.title)
                                .font(.caption.weight(.semibold))
                                .frame(width: 68, alignment: .leading)
                            Text(event.connectionKind.title.replacingOccurrences(of: "自定义 API 密钥", with: "自定义 API"))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(width: 86, alignment: .leading)
                            Text(event.succeeded ? "完成" : "失败")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(event.succeeded ? .green : .red)
                            Spacer(minLength: 6)
                            if let duration = event.durationMilliseconds {
                                Text("\(duration)ms")
                                    .font(.caption.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                            Text(relativeTime(event.timestamp))
                                .font(.caption2)
                                .foregroundStyle(.tertiary)
                                .frame(width: 58, alignment: .trailing)
                        }
                        .padding(.vertical, 5)
                        if event.id != recent.last?.id {
                            Divider()
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
    }

    private func analyticsModeCard(
        mode: CodexConnectionKind,
        title: String,
        subtitle: String,
        accent: Color
    ) -> some View {
        let summary = model.activitySummary(for: mode, profileID: nil)
        return VStack(alignment: .leading, spacing: 10) {
            HStack {
                Image(systemName: mode.icon)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 28, height: 28)
                    .background(accent.opacity(0.10), in: Circle())
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.callout.weight(.semibold))
                    Text(subtitle)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if effectiveConnectionKind == mode {
                    BreathingStatusDot(color: .green, active: true)
                }
            }

            HStack(spacing: 0) {
                activityMetric("今日", "\(summary.eventsLast24Hours)", accent)
                activityDivider
                activityMetric("成功率", percentText(summary.successRate), summary.failedEventsLast7Days > 0 ? .orange : .green)
                activityDivider
                activityMetric("平均", durationText(summary.averageDurationMilliseconds), latencyColor(summary.averageDurationMilliseconds ?? 0))
            }
            activityTrend(summary: summary, accent: accent)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(15)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .stroke(accent.opacity(effectiveConnectionKind == mode ? 0.30 : 0.13), lineWidth: effectiveConnectionKind == mode ? 1.5 : 1)
        )
        .shadow(color: Color.black.opacity(0.028), radius: 12, y: 5)
    }

    private var analyticsComparisonCard: some View {
        card {
            VStack(alignment: .leading, spacing: 13) {
                Label("连接对比", systemImage: "chart.bar.xaxis")
                    .font(.callout.weight(.semibold))
                comparisonRow(title: "账户登录", mode: .account, color: .green)
                comparisonRow(title: "托管密钥", mode: .harborKey, color: .blue)
                comparisonRow(title: "自定义 API", mode: .apiKey, color: .purple)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var activityLedgerCard: some View {
        card {
            VStack(alignment: .leading, spacing: 13) {
                Label("统计口径", systemImage: "list.bullet.rectangle")
                    .font(.callout.weight(.semibold))
                capabilityLine("本地统计", value: "\(model.activityEvents.count) 条事件", color: .blue)
                capabilityLine("余额查询", value: "仅托管密钥", color: .green)
                capabilityLine("保存位置", value: "本机私有", color: .purple)
                capabilityLine("敏感数据", value: "不记录", color: .orange)
            }
        }
        .frame(width: 270)
        .frame(maxHeight: .infinity)
    }

    private func comparisonRow(title: String, mode: CodexConnectionKind, color: Color) -> some View {
        let summary = model.activitySummary(for: mode, profileID: nil)
        return HStack(spacing: 10) {
            Circle()
                .fill(color)
                .frame(width: 8, height: 8)
            Text(title)
                .font(.caption.weight(.semibold))
                .frame(width: 82, alignment: .leading)
            Text("7天 \(summary.eventsLast7Days)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Text(percentText(summary.successRate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(summary.failedEventsLast7Days > 0 ? .orange : .green)
            Spacer()
            Text(durationText(summary.averageDurationMilliseconds))
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(latencyColor(summary.averageDurationMilliseconds ?? 0))
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(color.opacity(0.045), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    private func capabilityLine(_ title: String, value: String, color: Color) -> some View {
        HStack {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(.caption.weight(.semibold))
                .foregroundStyle(color)
        }
    }

    private var profileLibrary: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text(profileListTitle)
                    .font(.headline)
                Spacer()
                Button(action: showAddSheet) {
                    Image(systemName: "plus")
                        .font(.body.weight(.medium))
                        .frame(width: 30, height: 30)
                        .background(Color.accentColor.opacity(0.09), in: RoundedRectangle(cornerRadius: 9))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
                .disabled(model.isBusy)
                .help("添加\(libraryMode.title)")
            }
            .padding(.horizontal, 18)
            .frame(height: 58)

            Divider()

            ScrollView {
                LazyVStack(spacing: 10) {
                if libraryMode == .account {
                    if model.accountProfiles.isEmpty {
                        profileEmptyState(
                            title: "还没有 Codex 账户",
                            detail: "点击上方 + 添加账户"
                        )
                    } else {
                        ForEach(model.accountProfiles) { profile in
                            let isActive = model.selectedAccountProfileID == profile.id && model.environment.activeMode == .chatGPT
                            let isPreviewed = previewAccountID == profile.id
                            profileRow(
                                title: profile.name,
                                subtitle: profile.method.title,
                                icon: "person.crop.circle.fill",
                                color: .green,
                                selected: isPreviewed,
                                active: isActive,
                                health: model.accountProfileHealth[profile.id] ?? .unchecked,
                                diagnostic: model.accountProfileDiagnostics[profile.id],
                                pending: pendingConnectionID == "account-\(profile.id.uuidString)",
                                deletionTarget: .account(profile),
                                deletionDisabled: isActive,
                                renameAction: {
                                    renameText = profile.name
                                    renameTarget = .account(profile)
                                },
                                moveToFrontAction: {
                                    Task { await model.moveAccountToBoundary(profile.id, toFront: true) }
                                },
                                moveToBottomAction: {
                                    Task { await model.moveAccountToBoundary(profile.id, toFront: false) }
                                },
                                action: {
                                    withAnimation(.easeOut(duration: 0.16)) {
                                        previewAccountID = profile.id
                                    }
                                }
                            )
                            .onDrag {
                                draggingProfileID = profile.id
                                return NSItemProvider(object: profile.id.uuidString as NSString)
                            }
                            .onDrop(of: [UTType.text], delegate: ProfileDropDelegate(
                                targetID: profile.id,
                                draggedID: { draggingProfileID },
                                reorder: { sourceID, targetID in
                                    Task { await model.reorderAccount(moving: sourceID, before: targetID) }
                                },
                                finish: { draggingProfileID = nil }
                            ))
                        }
                    }
                } else if model.profiles.filter({ $0.kind.connectionKind == libraryMode }).isEmpty {
                    profileEmptyState(
                        title: "没有可用的\(libraryMode.title)",
                        detail: "点击上方 + 添加连接"
                    )
                } else {
                    ForEach(model.profiles.filter({ $0.kind.connectionKind == libraryMode })) { profile in
                        let isCurrent = model.activeProfileID == profile.id && model.environment.activeMode == .harbor
                        let isPreviewed = previewAPIProfileID == profile.id
                        profileRow(
                            title: profile.name,
                            subtitle: profile.kind == .customResponses
                                ? "\(ProviderCatalog.identity(for: profile.apiBaseURL).brand.title) · \(ProviderCatalog.identity(for: profile.apiBaseURL).host)"
                                : profile.kind.title,
                                icon: profile.kind == .customResponses ? profile.provider.icon : "key.fill",
                                color: .blue,
                                providerIdentity: profile.kind == .customResponses
                                    ? ProviderCatalog.identity(for: profile.apiBaseURL)
                                    : nil,
                            selected: isPreviewed,
                            active: isCurrent,
                            health: model.apiProfileHealth[profile.id] ?? .unchecked,
                            diagnostic: model.apiProfileDiagnostics[profile.id],
                            pending: pendingConnectionID == "api-\(profile.id.uuidString)",
                            deletionTarget: .api(profile),
                            deletionDisabled: isCurrent,
                            renameAction: {
                                renameText = profile.name
                                renameTarget = .api(profile)
                            },
                            moveToFrontAction: {
                                Task { await model.moveProfileToBoundary(profile.id, toFront: true) }
                            },
                            moveToBottomAction: {
                                Task { await model.moveProfileToBoundary(profile.id, toFront: false) }
                            },
                            action: {
                                withAnimation(.easeOut(duration: 0.16)) {
                                    previewAPIProfileID = profile.id
                                }
                            }
                        )
                        .onDrag {
                            draggingProfileID = profile.id
                            return NSItemProvider(object: profile.id.uuidString as NSString)
                        }
                        .onDrop(of: [UTType.text], delegate: ProfileDropDelegate(
                            targetID: profile.id,
                            draggedID: { draggingProfileID },
                            reorder: { sourceID, targetID in
                                Task { await model.reorderProfile(moving: sourceID, before: targetID) }
                            },
                            finish: { draggingProfileID = nil }
                        ))
                    }
                }
            }
                .padding(14)
            }
            .scrollIndicators(.automatic)
            .frame(maxHeight: .infinity)

        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(Color.accentColor.opacity(0.018))
    }

    private var profileListTitle: String {
        switch libraryMode {
        case .account: "账户列表"
        case .harborKey: "托管密钥列表"
        case .apiKey: "自定义 API 列表"
        }
    }

    private func showAddSheet() {
        switch libraryMode {
        case .account:
            showsAccountSetupSheet = true
        case .harborKey:
            newActivationKey = ""
            newProfileAPIBaseURL = HarborRemoteConfiguration.fallback.apiBaseURL.absoluteString
            showsActivationSheet = true
        case .apiKey:
            customAPIName = ""
            customAPIKey = ""
            customAPIProvider = .openAI
            customAPIBaseURL = customAPIProvider.defaultBaseURL
            customAPIModel = ""
            showsCustomAPISheet = true
        }
    }

    private func profileEmptyState(title: String, detail: String) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption.weight(.semibold))
            Text(detail)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.vertical, 9)
        .foregroundStyle(.tertiary)
    }

    private func profileRow(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        providerIdentity: ProviderIdentity? = nil,
        selected: Bool,
        active: Bool,
        health: ConnectionHealth,
        diagnostic: ConnectionDiagnostic? = nil,
        pending: Bool,
        deletionTarget target: ProfileDeletionTarget,
        deletionDisabled: Bool,
        renameAction: @escaping () -> Void,
        moveToFrontAction: @escaping () -> Void,
        moveToBottomAction: @escaping () -> Void,
        action: @escaping () -> Void
    ) -> some View {
        let hovered = hoveredProfileID == target.profileID
        return HStack(spacing: 2) {
            Button(action: action) {
                HStack(spacing: 9) {
                if let providerIdentity {
                    ProviderIconView(identity: providerIdentity, size: 30)
                } else {
                    Image(systemName: icon)
                        .font(.callout)
                        .foregroundStyle(color)
                        .frame(width: 30)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.caption.weight(.semibold)).lineLimit(1)
                    Text(subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer(minLength: 4)
                VStack(alignment: .trailing, spacing: 3) {
                    if pending {
                        HStack(spacing: 5) {
                            ProgressView().controlSize(.mini)
                            Text("切换中")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.blue)
                        }
                    } else if active {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 7, height: 7)
                            Text("当前")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.green)
                        }
                    }
                    HStack(spacing: 4) {
                        Circle().fill(healthColor(health)).frame(width: 6, height: 6)
                        Text(healthTitle(health) + diagnosticLatencySuffix(diagnostic))
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(healthColor(health))
                    }
                }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(model.isBusy && !pending)
            .accessibilityAddTraits(selected ? .isSelected : [])
            .help(active ? "当前正在使用；点击查看详情" : "查看连接详情")

            Menu {
                Button("重命名") { renameAction() }
                Divider()
                Button("移到最前") { moveToFrontAction() }
                Button("移到最后") { moveToBottomAction() }
                Divider()
                Button("删除档案", role: .destructive) {
                    deletionTarget = target
                }
                .disabled(deletionDisabled)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 22, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help(deletionDisabled ? "请先切换到其他连接，再删除当前档案" : "更多操作")
        }
        .padding(.leading, 10)
        .padding(.trailing, 6)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity)
        .frame(minHeight: 62)
        .background(
            selected
                ? color.opacity(0.11)
                : (hovered ? color.opacity(0.045) : Color(nsColor: .textBackgroundColor)),
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(selected ? color.opacity(0.72) : Color.primary.opacity(0.10), lineWidth: selected ? 1.5 : 1)
        )
        .shadow(color: selected ? color.opacity(0.08) : Color.black.opacity(hovered ? 0.045 : 0.025), radius: hovered ? 10 : 8, y: hovered ? 4 : 3)
        .scaleEffect(hovered && !selected ? 1.008 : 1)
        .onHover { isHovering in
            withAnimation(.easeOut(duration: 0.14)) {
                hoveredProfileID = isHovering ? target.profileID : nil
            }
        }
        .animation(.easeOut(duration: 0.14), value: hovered)
        .contextMenu {
            Button("重命名") { renameAction() }
            Button("移到最前") { moveToFrontAction() }
            Button("移到最后") { moveToBottomAction() }
            Divider()
            Button("删除档案", role: .destructive) {
                deletionTarget = target
            }
            .disabled(deletionDisabled)
        }
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

    private func healthColor(_ health: ConnectionHealth) -> Color {
        switch health {
        case .unchecked: .secondary
        case .checking: .blue
        case .available: .green
        case .expired: .orange
        case .unavailable: .red
        }
    }

    private func healthDetail(_ health: ConnectionHealth) -> String? {
        switch health {
        case let .available(detail), let .expired(detail), let .unavailable(detail): detail
        case .unchecked: "尚未检查此连接"
        case .checking: "正在检查此连接"
        }
    }

    private func diagnosticLatencySuffix(_ diagnostic: ConnectionDiagnostic?) -> String {
        guard let latency = diagnostic?.latencyMilliseconds else { return "" }
        return " · \(latency)ms"
    }

    private func deleteSelectedProfile() {
        guard let target = deletionTarget else { return }
        deletionTarget = nil
        switch target {
        case let .account(profile):
            Task { await model.removeAccount(profile.id) }
        case let .api(profile):
            Task { await model.removeProfile(profile.id) }
        }
    }

    private func renameSelectedProfile() {
        guard let target = renameTarget else { return }
        let name = renameText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        renameTarget = nil
        switch target {
        case let .account(profile):
            Task { await model.renameAccount(profile.id, to: name) }
        case let .api(profile):
            Task { await model.renameProfile(profile.id, to: name) }
        }
    }

    private func profileSectionHeader(title: String, detail: String, color: Color, icon: String) -> some View {
        HStack(spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 1) {
                Text(title).font(.caption.weight(.bold)).foregroundStyle(.primary)
                Text(detail).font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.top, 2)
    }

    private var currentConnectionCard: some View {
        Group {
            if libraryMode == .account,
               let profile = model.accountProfiles.first(where: { $0.id == previewAccountID }) {
                accountDetail(profile)
            } else if libraryMode != .account,
                      let profile = model.profiles.first(where: { $0.id == previewAPIProfileID }),
                      profile.kind.connectionKind == libraryMode {
                apiDetail(profile)
            } else {
                inactiveModeDetail
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18),
            value: libraryMode == .account ? previewAccountID : previewAPIProfileID
        )
    }

    private var activeHarborProfile: HarborProfile? {
        guard let activeProfileID = model.activeProfileID else { return nil }
        return model.profiles.first(where: { $0.id == activeProfileID })
    }

    private func accountDetail(_ profile: CodexAccountProfile) -> some View {
        let isActive = effectiveConnectionKind == .account && model.selectedAccountProfileID == profile.id
        let health = model.accountProfileHealth[profile.id] ?? .unchecked
        let now = Date()
        let rangeStart = trendStartDate(now: now)
        let metrics = model.codexRequestMetrics(
            for: .account,
            profileID: nil,
            since: rangeStart,
            now: now
        )
        return VStack(alignment: .leading, spacing: 14) {
            connectionHero(
                title: profile.name,
                subtitle: profile.method.title,
                icon: "person.crop.circle.fill",
                color: .green,
                health: health,
                isActive: isActive,
                checkAction: {
                    Task {
                        await model.refreshEnvironment()
                        await model.refreshConnectionHealth()
                    }
                },
                switchAction: {
                    pendingConnectionID = "account-\(profile.id.uuidString)"
                    Task {
                        await model.switchAccount(to: profile.id)
                        pendingConnectionID = nil
                    }
                }
            )

            statisticsRangeControl(accent: .green)

            Divider()

            VStack(spacing: 14) {
                requestMetricsRow(
                    kind: .account,
                    metrics: metrics,
                    workDuration: model.codexWorkDurationMilliseconds(
                        for: .account,
                        profileID: nil,
                        since: rangeStart
                    ),
                    accent: .green
                )
                requestTrendPanel(kind: .account, accent: .green)
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func apiDetail(_ profile: HarborProfile) -> some View {
        let identity = ProviderCatalog.identity(for: profile.apiBaseURL)
        let health = model.apiProfileHealth[profile.id] ?? .unchecked
        let isActive = effectiveConnectionKind == profile.kind.connectionKind && model.activeProfileID == profile.id
        let now = Date()
        let rangeStart = trendStartDate(now: now)
        let metrics = model.codexRequestMetrics(
            for: profile.kind.connectionKind,
            profileID: nil,
            since: rangeStart,
            now: now
        )
        return VStack(alignment: .leading, spacing: 14) {
            connectionHero(
                title: profile.name,
                subtitle: profile.kind == .harbor ? "托管密钥" : identity.brand.title,
                icon: profile.kind == .harbor ? "key.fill" : profile.provider.icon,
                color: profile.kind == .harbor ? .blue : identity.brand.tint,
                health: health,
                providerIdentity: profile.kind == .customResponses ? identity : nil,
                isActive: isActive,
                usage: profile.kind == .harbor ? (model.usageByProfileID[profile.id] ?? (isActive ? model.usage : nil)) : nil,
                usageExpiry: profile.kind == .harbor ? displayExpiry(model.usageByProfileID[profile.id]?.expiresAt ?? profile.expiresAt) : nil,
                usageQueryAction: profile.kind == .harbor ? {
                    queryingUsageProfileID = profile.id
                    Task {
                        await model.queryUsage(for: profile.id)
                        queryingUsageProfileID = nil
                    }
                } : nil,
                isQueryingUsage: queryingUsageProfileID == profile.id,
                checkAction: {
                    Task { await model.refreshConnectionHealth() }
                },
                switchAction: {
                    pendingConnectionID = "api-\(profile.id.uuidString)"
                    Task {
                        await model.switchProfile(to: profile.id)
                        pendingConnectionID = nil
                    }
                }
            )

            statisticsRangeControl(accent: profile.kind == .harbor ? .blue : identity.brand.tint)

            Divider()

            if profile.kind == .harbor {
                requestMetricsRow(
                    kind: .harborKey,
                    metrics: metrics,
                    workDuration: model.codexWorkDurationMilliseconds(
                        for: .harborKey,
                        profileID: nil,
                        since: rangeStart
                    ),
                    accent: .blue
                )
                requestTrendPanel(kind: .harborKey, accent: .blue)
            } else {
                VStack(spacing: 14) {
                    requestMetricsRow(
                        kind: .apiKey,
                        metrics: metrics,
                        workDuration: model.codexWorkDurationMilliseconds(
                            for: .apiKey,
                            profileID: nil,
                            since: rangeStart
                        ),
                        accent: identity.brand.tint
                    )
                    requestTrendPanel(kind: .apiKey, accent: identity.brand.tint)
                }
            }

            Spacer(minLength: 0)
        }
        .padding(14)
    }

    private func connectionHero(
        title: String,
        subtitle: String,
        icon: String,
        color: Color,
        health: ConnectionHealth,
        providerIdentity: ProviderIdentity? = nil,
        isActive: Bool,
        usage: UsageSnapshot? = nil,
        usageExpiry: String? = nil,
        usageQueryAction: (() -> Void)? = nil,
        isQueryingUsage: Bool = false,
        checkAction: @escaping () -> Void,
        switchAction: @escaping () -> Void
    ) -> some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                if let providerIdentity {
                    ProviderIconView(identity: providerIdentity, size: 48)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 25, weight: .semibold))
                        .foregroundStyle(color)
                        .frame(width: 48, height: 48)
                        .background(color.opacity(0.11), in: Circle())
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 19, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .layoutPriority(1)

                Spacer(minLength: 10)

                connectionHeroMeta(isActive: isActive, health: health)
                    .frame(minWidth: 94, alignment: .trailing)
            }

            HStack(spacing: 8) {
                if usage != nil || usageExpiry != nil {
                    hostedInlineUsage(usage: usage, expiry: usageExpiry)
                } else {
                    Color.clear
                        .frame(width: 292, height: 24)
                }

                Spacer(minLength: 8)

                if let usageQueryAction {
                    Button(action: usageQueryAction) {
                        ZStack {
                            Label("查询", systemImage: "arrow.clockwise")
                                .opacity(isQueryingUsage ? 0 : 1)
                            ProgressView()
                                .controlSize(.small)
                                .opacity(isQueryingUsage ? 1 : 0)
                        }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))
                    .help("查询托管用量")
                    .disabled(model.isBusy || isQueryingUsage)
                }

                Button(action: checkAction) {
                    Label("检查", systemImage: "checkmark.shield")
                }
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))
                .disabled(model.isBusy || model.isCheckingConnectionHealth)

                if isActive {
                    Label("已连接", systemImage: "checkmark.circle.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.green)
                        .frame(minWidth: 76)
                } else {
                    Button(action: switchAction) {
                        HStack(spacing: 7) {
                            if pendingConnectionID != nil {
                                ProgressView().controlSize(.small)
                            }
                            Text("切换")
                        }
                        .frame(minWidth: 76)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(model.isBusy)
                }
            }
        }
        .frame(height: 92)
    }

    private func connectionHeroMeta(
        isActive: Bool,
        health: ConnectionHealth
    ) -> some View {
        HStack(spacing: 6) {
            BreathingStatusDot(
                color: healthColor(health),
                active: healthIsAvailable(health)
            )
            Text(isActive ? "当前连接" : "连接详情")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.secondary)
            Text(healthTitle(health))
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(healthColor(health))
        }
        .lineLimit(1)
        .help("连接健康状态；托管连接会在此显示已用、剩余和有效期")
    }

    private func healthIsAvailable(_ health: ConnectionHealth) -> Bool {
        if case .available = health { return true }
        return false
    }

    private func hostedInlineUsage(usage: UsageSnapshot?, expiry: String?) -> some View {
        HStack(spacing: 8) {
            Text("已用 " + formatCurrency(usage?.used))
                .foregroundStyle(.orange)
            Text("余 " + formatCurrency(usage?.remaining))
                .foregroundStyle(.green)
            Text("至 " + (expiry ?? "—"))
                .foregroundStyle(.blue)
                .fontDesign(.monospaced)
                .lineLimit(1)
                .minimumScaleFactor(0.62)
        }
        .font(.system(size: 9, weight: .semibold))
        .lineLimit(1)
        .padding(.horizontal, 8)
        .frame(width: 292, height: 24, alignment: .leading)
        .background(Color.blue.opacity(0.055), in: Capsule())
        .overlay(Capsule().stroke(Color.blue.opacity(0.12)))
        .help("托管用量与有效期")
    }

    private func analyticsMetricsStrip(_ rows: [(String, String, String, Color)]) -> some View {
        HStack(spacing: 0) {
            ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                analyticsMetric(row)
                if index < rows.count - 1 {
                    Rectangle()
                        .fill(Color.primary.opacity(0.075))
                        .frame(width: 1, height: 42)
                }
            }
        }
        .padding(.vertical, 7)
        .overlay(alignment: .top) {
            Rectangle()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 1)
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.primary.opacity(0.075))
                .frame(height: 1)
        }
    }

    private func analyticsMetric(_ row: (String, String, String, Color)) -> some View {
        let isHovered = hoveredDetailKey == row.0
        return VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 8) {
                Image(systemName: row.2)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(row.3)
                    .frame(width: 22, height: 22)
                    .background(row.3.opacity(isHovered ? 0.16 : 0.09), in: Circle())
                Text(row.0)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Text(row.1)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .foregroundStyle(isHovered ? row.3 : Color.primary)
                .lineLimit(1)
                .truncationMode(.middle)
                .minimumScaleFactor(0.72)
                .textSelection(.enabled)
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 7)
        .frame(maxWidth: .infinity, minHeight: 62, alignment: .leading)
        .background(
            Rectangle()
                .fill(isHovered ? row.3.opacity(0.045) : Color.clear)
        )
        .contentShape(Rectangle())
        .onHover { hovering in
            withAnimation(detailHoverAnimation) {
                hoveredDetailKey = hovering ? row.0 : nil
            }
        }
        .animation(detailHoverAnimation, value: isHovered)
    }

    private var detailHoverAnimation: Animation {
        reduceMotion
            ? .linear(duration: 0.01)
            : .spring(response: 0.24, dampingFraction: 0.82)
    }

    private func trendStartDate(now: Date = Date()) -> Date {
        let calendar = Calendar.current
        switch trendRange {
        case .today:
            return calendar.startOfDay(for: now)
        case .sevenDays:
            return calendar.date(byAdding: .day, value: -6, to: calendar.startOfDay(for: now)) ?? calendar.startOfDay(for: now)
        case .month:
            return calendar.dateInterval(of: .month, for: now)?.start ?? calendar.startOfDay(for: now)
        }
    }

    private func requestMetricsRow(
        kind: CodexConnectionKind,
        metrics: AppModel.CodexRequestMetrics,
        workDuration: Int?,
        accent: Color
    ) -> some View {
        let rangeStart = trendStartDate()
        let tokenSummary = model.codexTokenSummary(
            for: kind,
            profileID: nil,
            since: rangeStart
        )
        let billedTokens = model.providerBilledTokenTotal(
            for: kind,
            profileID: nil,
            since: rangeStart
        )
        let requestLabel = trendRange == .today ? "今日请求" : "\(trendRange.rawValue)请求"
        let durationLabel = trendRange == .today ? "今日工作时长" : "\(trendRange.rawValue)工作时长"
        var rows: [(String, String, String, Color)] = [
            (requestLabel, "\(metrics.count)", "arrow.up.right.circle.fill", accent),
            ("请求 Token", tokenSummary.totalTokens > 0 ? formatTokenCount(tokenSummary.totalTokens) : "暂无记录", "number", .purple),
            ("平均响应", durationText(metrics.averageDurationMilliseconds), "speedometer", latencyColor(metrics.averageDurationMilliseconds ?? 0)),
            ("成功率", percentText(metrics.successRate), "checkmark.seal.fill", successRateColor(metrics.successRate)),
            (durationLabel, workDurationText(workDuration), "clock.fill", .blue)
        ]
        if billedTokens > 0 {
            rows.append(("计费 Token", formatTokenCount(billedTokens), "creditcard.fill", .orange))
        }
        return analyticsMetricsStrip(rows)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.20),
                value: trendRange
            )
    }

    private func statisticsRangeControl(accent: Color) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 7) {
                Image(systemName: "calendar")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 25, height: 25)
                    .background(accent.opacity(0.11), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
                Text("统计范围")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.primary)
            }

            Spacer(minLength: 10)

            HStack(spacing: 3) {
                statisticsRangeButton("今日", range: .today, accent: accent)
                statisticsRangeButton("7日", range: .sevenDays, accent: accent)
                statisticsRangeButton("当月", range: .month, accent: accent)
            }
            .padding(3)
            .background(Color.primary.opacity(0.045), in: Capsule())
        }
        .padding(.horizontal, 10)
        .frame(maxWidth: .infinity, minHeight: 42)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.055),
                    Color(nsColor: .controlBackgroundColor).opacity(0.28)
                ],
                startPoint: .leading,
                endPoint: .trailing
            ),
            in: RoundedRectangle(cornerRadius: 12, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(accent.opacity(0.11), lineWidth: 1)
        )
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18),
            value: trendRange
        )
    }

    private func statisticsRangeButton(
        _ title: String,
        range: TrendRange,
        accent: Color
    ) -> some View {
        let selected = trendRange == range
        return Button {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.28, dampingFraction: 0.86)) {
                trendRange = range
            }
        } label: {
            Text(title)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(selected ? accent : .secondary)
                .frame(width: 45, height: 27)
                .background(selected ? accent.opacity(0.14) : Color.clear, in: Capsule())
                .overlay(
                    Capsule()
                        .stroke(selected ? accent.opacity(0.25) : Color.clear, lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
        .help("查看\(range.rawValue)统计")
    }

    private func successRateColor(_ value: Double?) -> Color {
        guard let value else { return .secondary }
        if value >= 0.98 { return .green }
        if value >= 0.90 { return .orange }
        return .red
    }

    private func requestTrendPanel(
        kind: CodexConnectionKind,
        accent: Color
    ) -> some View {
        let now = Date()
        let series: [HarborTrendSeries]
        let labels: [String]
        let currentFraction: Double?
        switch trendRange {
        case .today:
            let dayStart = Calendar.current.startOfDay(for: now)
            series = trendSeries(
                for: kind,
                now: now,
                requestValues: { profileID in
                    model.codexRequestHourlyCounts(for: kind, profileID: profileID, now: now, since: dayStart)
                },
                tokenValues: { profileID in
                    model.codexTokenHourlyCounts(for: kind, profileID: profileID, now: now, since: dayStart)
                },
                latencyValues: { profileID in
                    model.codexResponseHourlyAverages(for: kind, profileID: profileID, now: now, since: dayStart)
                },
                accent: accent
            )
            labels = hourlyTrendLabels(dayStart: dayStart, now: now)
            let minutesSinceMidnight = now.timeIntervalSince(dayStart) / 60
            currentFraction = min(max(minutesSinceMidnight / (24 * 60), 0), 1)
        case .sevenDays:
            series = trendSeries(
                for: kind,
                now: now,
                requestValues: { profileID in
                    model.codexRequestDailyCounts(for: kind, profileID: profileID, days: 7, now: now)
                },
                tokenValues: { profileID in
                    model.codexTokenDailyCounts(for: kind, profileID: profileID, days: 7, now: now)
                },
                latencyValues: { profileID in
                    model.codexResponseDailyAverages(for: kind, profileID: profileID, days: 7, now: now)
                },
                accent: accent
            )
            labels = dailyTrendLabels(days: 7, now: now)
            currentFraction = nil
        case .month:
            let calendar = Calendar.current
            let days = calendar.range(of: .day, in: .month, for: now)?.count ?? 30
            series = trendSeries(
                for: kind,
                now: now,
                requestValues: { profileID in
                    model.codexRequestDailyCounts(for: kind, profileID: profileID, days: days, now: now)
                },
                tokenValues: { profileID in
                    model.codexTokenDailyCounts(for: kind, profileID: profileID, days: days, now: now)
                },
                latencyValues: { profileID in
                    model.codexResponseDailyAverages(for: kind, profileID: profileID, days: days, now: now)
                },
                accent: accent
            )
            labels = dailyTrendLabels(days: days, now: now)
            currentFraction = nil
        }
        return VStack(alignment: .leading, spacing: 7) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(trendRange.rawValue)\(trendMetric == .token ? " Token 使用趋势" : " \(trendMetric.rawValue)趋势")")
                        .font(.callout.weight(.semibold))
                        .help("按上方统计范围展示")
                }
                Spacer()
                HStack(spacing: 4) {
                    trendFilterButton("Token", selected: trendMetric == .token, tint: accent) {
                        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16)) {
                            trendMetric = .token
                        }
                    }
                    trendFilterButton("请求", selected: trendMetric == .requests, tint: accent) {
                        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16)) {
                            trendMetric = .requests
                        }
                    }
                    trendFilterButton("耗时", selected: trendMetric == .latency, tint: accent) {
                        withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16)) {
                            trendMetric = .latency
                        }
                    }
                    Text(trendMetric.unit)
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 3)
                }
            }
            HarborTrendChart(
                series: series,
                labels: labels,
                metric: trendMetric,
                accent: accent,
                currentFraction: currentFraction
            )
                .frame(height: 158)
            if kind == .apiKey, series.count > 1 {
                trendLegend(series)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .background(
            LinearGradient(
                colors: [
                    accent.opacity(0.045),
                    Color(nsColor: .controlBackgroundColor).opacity(0.42)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
        )
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(accent.opacity(0.10)))
    }

    private func trendSeries(
        for kind: CodexConnectionKind,
        now: Date,
        requestValues: (UUID?) -> [Int],
        tokenValues: (UUID?) -> [Int],
        latencyValues: (UUID?) -> [Int],
        accent: Color
    ) -> [HarborTrendSeries] {
        if kind == .apiKey {
            let apiProfiles = model.profiles.filter { $0.kind.connectionKind == .apiKey }
            let palette: [Color] = [.purple, .orange, .teal, .pink, .indigo, .cyan]
            return apiProfiles.enumerated().map { index, profile in
                let requests = requestValues(profile.id)
                let values: [Int] = switch trendMetric {
                case .token: tokenValues(profile.id)
                case .requests: requests
                case .latency: latencyValues(profile.id)
                }
                let identity = ProviderCatalog.identity(for: profile.apiBaseURL)
                return HarborTrendSeries(
                    id: profile.id.uuidString,
                    title: profile.name,
                    values: values,
                    requestCounts: requests,
                    color: index < palette.count ? palette[index] : identity.brand.tint,
                    dash: trendDashStyle(index: index)
                )
            }
        }

        let requests = requestValues(nil)
        let values: [Int] = switch trendMetric {
        case .token: tokenValues(nil)
        case .requests: requests
        case .latency: latencyValues(nil)
        }
        return [
            HarborTrendSeries(
                id: "\(kind.rawValue)-summary",
                title: kind.title,
                values: values,
                requestCounts: requests,
                color: accent,
                dash: []
            )
        ]
    }

    private func trendDashStyle(index: Int) -> [CGFloat] {
        switch index % 4 {
        case 1: [5, 4]
        case 2: [2, 3]
        case 3: [7, 3, 2, 3]
        default: []
        }
    }

    private func trendLegend(_ series: [HarborTrendSeries]) -> some View {
        HStack(spacing: 8) {
            ForEach(series.prefix(6), id: \.id) { item in
                HStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 2, style: .continuous)
                        .fill(item.color)
                        .frame(width: 16, height: 3)
                    Text(item.title)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                .help(item.title)
            }
            if series.count > 6 {
                Text("+\(series.count - 6)")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 16)
    }

    private func hourlyTrendLabels(dayStart: Date, now: Date = Date()) -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "HH:mm"
        return (0...24).map { offset in
            if offset == 24 { return "24:00" }
            guard let hour = calendar.date(byAdding: .hour, value: offset, to: dayStart) else { return "" }
            return formatter.string(from: hour)
        }
    }

    private func dailyTrendLabels(days: Int, now: Date = Date()) -> [String] {
        let calendar = Calendar.current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "M月d日"
        let count = max(days, 1)
        let today = calendar.startOfDay(for: now)
        guard let firstDay = calendar.date(byAdding: .day, value: -(count - 1), to: today) else {
            return Array(repeating: "", count: count)
        }
        return (0..<count).map { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: firstDay) else { return "" }
            return calendar.isDateInToday(date) ? "今天" : formatter.string(from: date)
        }
    }

    private func trendFilterButton(_ title: String, selected: Bool, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(selected ? tint : .secondary)
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(selected ? tint.opacity(0.12) : Color.clear, in: Capsule())
                .overlay(Capsule().stroke(selected ? tint.opacity(0.26) : Color.clear, lineWidth: 1))
        }
        .buttonStyle(.plain)
        .contentShape(Capsule())
    }

    private func formatTokenCount(_ value: Int) -> String {
        if value >= 100_000_000 {
            return "\((Double(value) / 100_000_000).formatted(.number.precision(.fractionLength(1))))亿"
        }
        if value >= 10_000 {
            return "\((Double(value) / 10_000).formatted(.number.precision(.fractionLength(1))))万"
        }
        return "\(value.formatted(.number)) 个"
    }

    private func workDurationText(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "暂无记录" }
        let totalSeconds = max(0, milliseconds) / 1000
        if totalSeconds < 60 { return "\(totalSeconds) 秒" }
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        if minutes < 60 { return "\(minutes) 分 \(seconds) 秒" }
        return "\(minutes / 60) 小时 \(minutes % 60) 分"
    }

    private func connectionInsights(_ profile: HarborProfile) -> some View {
        let diagnostic = model.apiProfileDiagnostics[profile.id]
        let identity = ProviderCatalog.identity(for: profile.apiBaseURL)
        return HStack(spacing: 8) {
            insightChip(
                profile.kind == .harbor ? "托管认证" : identity.brand.title,
                icon: profile.kind == .harbor ? "key.fill" : identity.brand.symbolName,
                color: profile.kind == .harbor ? .blue : identity.brand.tint
            )
            insightChip(
                profile.kind == .harbor ? "可查询用量" : identity.protocolTitle,
                icon: profile.kind == .harbor ? "chart.bar.fill" : "arrow.left.arrow.right",
                color: profile.kind == .harbor ? .green : .purple
            )
            if let latency = diagnostic?.latencyMilliseconds {
                insightChip("\(latency)ms", icon: "speedometer", color: latencyColor(latency))
            }
            insightChip(
                profile.kind == .customResponses ? "新任务隔离" : "安全回滚",
                icon: profile.kind == .customResponses ? "rectangle.split.3x1.fill" : "arrow.uturn.backward.circle.fill",
                color: .teal
            )
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.accentColor.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.accentColor.opacity(0.10))
        )
    }

    private func accountInsights(_ profile: CodexAccountProfile) -> some View {
        HStack(spacing: 8) {
            insightChip("官方登录", icon: "checkmark.seal.fill", color: .green)
            insightChip("本地凭据", icon: "lock.shield.fill", color: .blue)
            insightChip("账户隔离", icon: "person.2.badge.gearshape.fill", color: .purple)
            insightChip("会话保持", icon: "bubble.left.and.bubble.right.fill", color: .teal)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(Color.green.opacity(0.035), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.green.opacity(0.10))
        )
    }

    private func activitySummaryPanel(
        title: String,
        connectionKind: CodexConnectionKind,
        profileID: UUID?,
        accent: Color,
        diagnostic: ConnectionDiagnostic?
    ) -> some View {
        let summary = model.activitySummary(for: connectionKind, profileID: profileID)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(accent)
                    .frame(width: 24, height: 24)
                    .background(accent.opacity(0.10), in: Circle())
                Text(title)
                    .font(.callout.weight(.semibold))
                Spacer()
                if let lastObservedAt = summary.lastObservedAt {
                    Text(relativeTime(lastObservedAt))
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 0) {
                activityMetric("今日活动", "\(summary.eventsLast24Hours)", accent)
                activityDivider
                activityMetric("7天成功率", percentText(summary.successRate), summary.failedEventsLast7Days > 0 ? .orange : .green)
                activityDivider
                activityMetric("平均响应", durationText(summary.averageDurationMilliseconds ?? diagnostic?.latencyMilliseconds), latencyColor(summary.averageDurationMilliseconds ?? diagnostic?.latencyMilliseconds ?? 0))
                activityDivider
                activityTrend(summary: summary, accent: accent)
            }
            .frame(minHeight: 52)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.58), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(accent.opacity(0.16))
        )
    }

    private func activityMetric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: 16, weight: .bold, design: .rounded))
                .foregroundStyle(color)
                .monospacedDigit()
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var activityDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.08))
            .frame(width: 1, height: 38)
            .padding(.horizontal, 12)
    }

    private func activityTrend(summary: ConnectionActivitySummary, accent: Color) -> some View {
        let maxCount = max(summary.dailyCounts.map(\.count).max() ?? 0, 1)
        return VStack(alignment: .leading, spacing: 7) {
            Text("7天趋势")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            HStack(alignment: .bottom, spacing: 5) {
                ForEach(Array(summary.dailyCounts.enumerated()), id: \.offset) { _, day in
                    Capsule(style: .continuous)
                        .fill(day.count == 0 ? Color.primary.opacity(0.12) : accent.opacity(0.76))
                        .frame(width: 8, height: CGFloat(max(8, 28 * day.count / maxCount)))
                        .help("\(day.date.formatted(date: .numeric, time: .omitted))：\(day.count)")
                }
            }
            .frame(height: 30, alignment: .bottom)
        }
        .frame(width: 86, alignment: .leading)
    }

    private func percentText(_ value: Double?) -> String {
        guard let value else { return "暂无" }
        return value.formatted(.percent.precision(.fractionLength(0)))
    }

    private func durationText(_ milliseconds: Int?) -> String {
        guard let milliseconds else { return "暂无" }
        return "\(milliseconds)ms"
    }

    private func insightChip(_ title: String, icon: String, color: Color) -> some View {
        Label(title, systemImage: icon)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .frame(height: 30)
            .background(color.opacity(0.09), in: Capsule())
            .overlay(Capsule().stroke(color.opacity(0.14)))
            .lineLimit(1)
    }

    private func latencyColor(_ milliseconds: Int) -> Color {
        if milliseconds < 500 { return .green }
        if milliseconds < 1_500 { return .orange }
        return .red
    }

    private func relativeTime(_ date: Date) -> String {
        if abs(date.timeIntervalSinceNow) < 2 { return "刚刚" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func hostedUsagePanel(_ profile: HarborProfile) -> some View {
        let isActive = effectiveConnectionKind == .harborKey && model.activeProfileID == profile.id
        let usage = model.usageByProfileID[profile.id] ?? (isActive ? model.usage : nil)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chart.bar.xaxis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.blue)
                    .frame(width: 23, height: 23)
                    .background(Color.blue.opacity(0.11), in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text("用量与有效期")
                        .font(.callout.weight(.semibold))
                }

                Spacer(minLength: 8)

                Button {
                    queryingUsageProfileID = profile.id
                    Task {
                        await model.queryUsage(for: profile.id)
                        queryingUsageProfileID = nil
                    }
                } label: {
                    ZStack {
                        Text("查询用量")
                            .font(.caption.weight(.semibold))
                            .opacity(queryingUsageProfileID == profile.id ? 0 : 1)
                        ProgressView()
                            .controlSize(.small)
                            .opacity(queryingUsageProfileID == profile.id ? 1 : 0)
                    }
                    .frame(width: 70)
                }
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                .disabled(model.isBusy || queryingUsageProfileID != nil)
            }

            HStack(spacing: 0) {
                usageSummaryMetric("已用", formatCurrency(usage?.used), color: .orange)
                usageSummaryDivider
                usageSummaryMetric("剩余", formatCurrency(usage?.remaining), color: .green)
                if let ratio = usageRatio(usage) {
                    usageSummaryDivider
                    VStack(alignment: .leading, spacing: 5) {
                        Text("使用进度")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                        HStack(spacing: 7) {
                            ProgressView(value: ratio, total: 1)
                                .progressViewStyle(.linear)
                                .tint(ratio > 0.9 ? .orange : .blue)
                                .frame(width: 88)
                            Text(ratio.formatted(.percent.precision(.fractionLength(0))))
                                .font(.caption.weight(.semibold).monospacedDigit())
                                .foregroundStyle(ratio > 0.9 ? .orange : .blue)
                        }
                    }
                    .frame(minWidth: 122, alignment: .leading)
                }
                usageSummaryDivider
                usageSummaryMetric(
                    "有效期",
                    displayExpiry(usage?.expiresAt ?? profile.expiresAt),
                    color: .blue
                )
            }
            .frame(maxWidth: .infinity, minHeight: 34, alignment: .leading)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(minHeight: 86)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
    }

    private func usageSummaryMetric(_ title: String, _ value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(title == "有效期" ? .blue : color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
        }
        .frame(minWidth: title == "有效期" ? 132 : 82, alignment: .leading)
    }

    private var usageSummaryDivider: some View {
        Rectangle()
            .fill(Color.primary.opacity(0.09))
            .frame(width: 1, height: 34)
            .padding(.horizontal, 10)
    }

    private func usageRatio(_ usage: UsageSnapshot?) -> Double? {
        guard let used = usage?.used, let remaining = usage?.remaining else { return nil }
        let total = used + remaining
        guard total > 0 else { return nil }
        return min(max(used / total, 0), 1)
    }

    private func hostedUsageCards(_ profile: HarborProfile) -> some View {
        LazyVGrid(columns: [
            GridItem(.flexible(minimum: 118), spacing: 12),
            GridItem(.flexible(minimum: 118), spacing: 12),
            GridItem(.flexible(minimum: 118), spacing: 12)
        ], spacing: 12) {
            usageMetric(
                title: "已用",
                value: formatCurrency(model.usage?.used),
                color: .blue
            )
            usageMetric(
                title: "剩余",
                value: formatCurrency(model.usage?.remaining),
                color: .green
            )
            usageMetric(
                title: "生效日期",
                value: displayExpiry(model.usage?.expiresAt ?? profile.expiresAt ?? model.expiresAt),
                color: .purple
            )
        }
        .frame(maxWidth: .infinity)
    }

    private func usageMetric(title: String, value: String, color: Color) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            Text(value)
                .font(.system(size: title == "生效日期" ? 17 : 24, weight: .semibold, design: .rounded))
                .foregroundStyle(color)
                .lineLimit(1)
                .minimumScaleFactor(0.72)
                .allowsTightening(true)
        }
        .padding(16)
        .frame(minWidth: 0, maxWidth: .infinity, minHeight: 104, alignment: .leading)
        .background(color.opacity(0.075), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(color.opacity(0.18))
        )
    }

    private var inactiveModeDetail: some View {
        VStack(spacing: 14) {
            Image(systemName: libraryMode.icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(width: 72, height: 72)
                .background(Color.secondary.opacity(0.08), in: Circle())
            Text("选择一个\(libraryMode.title)")
                .font(.title3.weight(.semibold))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var accountSetupSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            sheetHeader(
                title: "添加 Codex 账户",
                subtitle: "通过 Codex 官方登录添加账户",
                closeAction: closeAccountSheet
            )

            VStack(alignment: .leading, spacing: 0) {
                accountSetupStep(
                    number: 1,
                    title: "保护当前账户",
                    detail: "已创建隔离登录环境",
                    state: .complete,
                    drawsLine: true
                )
                accountSetupStep(
                    number: 2,
                    title: "登录新账户",
                    detail: model.isAwaitingAccountLogin ? "请在浏览器完成官方授权" : "打开 Codex 官方登录",
                    state: model.detectedAccountName != nil ? .complete : (model.isAwaitingAccountLogin ? .active : .idle),
                    drawsLine: true
                )
                accountSetupStep(
                    number: 3,
                    title: "识别并保存",
                    detail: model.detectedAccountName ?? "自动读取账户名称并加入列表",
                    state: model.detectedAccountName != nil ? .complete : (model.isAwaitingAccountLogin ? .active : .idle),
                    drawsLine: false
                )
            }
            .padding(18)
            .background(Color(nsColor: .controlBackgroundColor).opacity(0.40), in: RoundedRectangle(cornerRadius: 14))

            if let accountName = model.detectedAccountName {
                Label("账户已添加：\(accountName)", systemImage: "checkmark.circle.fill")
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
                    .padding(.horizontal, 12)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .background(Color.green.opacity(0.1), in: RoundedRectangle(cornerRadius: 9))
            } else if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.isAwaitingAccountLogin {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("等待浏览器登录完成")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("检测登录完成") {
                        Task { await model.detectNewAccountLogin() }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))
                    .disabled(model.isBusy)
                }
            }

            HStack {
                Label("Harbor 不会读取账号密码或验证码", systemImage: "lock.shield.fill")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("取消") {
                    closeAccountSheet()
                }
                .keyboardShortcut(.cancelAction)
                .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                .disabled(model.isBusy)

                if !model.isAwaitingAccountLogin && model.detectedAccountName == nil {
                    Button("开始官方登录") {
                        Task { await model.beginAddingAccount() }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(model.isBusy)
                } else if model.detectedAccountName != nil {
                    Button("关闭") { showsAccountSetupSheet = false }
                        .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                }
            }
        }
        .padding(28)
        .frame(width: 560)
        .interactiveDismissDisabled(
            model.isBusy || (model.isAwaitingAccountLogin && model.detectedAccountName == nil)
        )
        .onAppear {
            accountPulse = false
            withAnimation(.easeInOut(duration: 1.1).repeatForever(autoreverses: true)) {
                accountPulse = true
            }
        }
    }

    private func accountSetupStep(
        number: Int,
        title: String,
        detail: String,
        state: FlowStepState,
        drawsLine: Bool
    ) -> some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(spacing: 0) {
                ZStack {
                    if state == .active {
                        Circle()
                            .stroke(Color.accentColor.opacity(0.28), lineWidth: 2)
                            .frame(width: 30, height: 30)
                            .scaleEffect(accountPulse ? 1.24 : 0.92)
                            .opacity(accountPulse ? 0.15 : 0.75)
                    }
                    Circle()
                        .fill(flowStepColor(state))
                        .frame(width: 28, height: 28)
                    if state == .complete {
                        Image(systemName: "checkmark")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                    } else {
                        Text("\(number)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(state == .idle ? Color.secondary : Color.white)
                    }
                }
                if drawsLine {
                    Rectangle()
                        .fill(state == .complete ? Color.green.opacity(0.45) : Color.secondary.opacity(0.20))
                        .frame(width: 2, height: 42)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.top, 3)
        }
    }

    private func flowStepColor(_ state: FlowStepState) -> Color {
        switch state {
        case .idle: Color.secondary.opacity(0.14)
        case .active: Color.accentColor
        case .complete: Color.green
        }
    }

    private func closeAccountSheet() {
        if model.isAwaitingAccountLogin && model.detectedAccountName == nil {
            Task {
                await model.cancelAddingAccount()
                if model.errorMessage == nil { showsAccountSetupSheet = false }
            }
        } else {
            showsAccountSetupSheet = false
        }
    }

    private var activationSheet: some View {
        VStack(alignment: .leading, spacing: 22) {
            sheetHeader(
                title: "添加托管密钥",
                subtitle: "验证连接后保存到本机",
                closeAction: { showsActivationSheet = false }
            )

            secureKeyField(title: "托管密钥", text: $newActivationKey, reveals: $showsNewActivationKey)

            VStack(alignment: .leading, spacing: 7) {
                Text("服务地址").font(.callout.weight(.semibold))
                TextField("留空使用默认服务地址", text: $newProfileAPIBaseURL)
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                Button("取消") { showsActivationSheet = false }
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                Button {
                    Task {
                        await model.addProfile(activationKey: newActivationKey, apiBaseURL: newProfileAPIBaseURL)
                        if model.errorMessage == nil { showsActivationSheet = false; newActivationKey = "" }
                    }
                } label: {
                    if model.isBusy { ProgressView().controlSize(.small) } else { Text("验证并添加") }
                }
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                .disabled(model.isBusy || newActivationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(28)
        .frame(width: 500)
    }

    private var customAPISheet: some View {
        VStack(alignment: .leading, spacing: 20) {
            sheetHeader(
                title: "添加自定义 API 密钥",
                subtitle: "配置一个 Responses API 兼容连接",
                closeAction: { showsCustomAPISheet = false }
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("常用模板")
                    .font(.callout.weight(.semibold))
                LazyVGrid(columns: [
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8),
                    GridItem(.flexible(), spacing: 8)
                ], spacing: 8) {
                    ForEach(APIConnectionPreset.common) { preset in
                        let isSelected = customAPIBaseURL == preset.baseURL
                        Button { applyPreset(preset) } label: {
                            HStack(spacing: 7) {
                                ProviderIconView(identity: ProviderCatalog.identity(for: URL(string: preset.baseURL)!), size: 26)
                                Text(preset.name).font(.caption.weight(.semibold)).lineLimit(1)
                                Spacer(minLength: 0)
                                if isSelected {
                                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.blue).font(.caption)
                                }
                            }
                            .padding(.horizontal, 8)
                            .frame(height: 38)
                            .frame(maxWidth: .infinity)
                            .background(isSelected ? Color.accentColor.opacity(0.10) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                            .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).stroke(isSelected ? Color.accentColor.opacity(0.50) : Color.primary.opacity(0.10), lineWidth: isSelected ? 1.5 : 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                Text("连接提供商").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Picker("连接提供商", selection: $customAPIProvider) {
                    ForEach(CustomAPIProvider.allCases, id: \.self) { provider in
                        Text(provider.title).tag(provider)
                    }
                }
                .pickerStyle(.segmented)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("连接名称").font(.callout.weight(.semibold))
                formTextField("例如 Kimi、公司网关", text: $customAPIName)
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("API Key").font(.callout.weight(.semibold))
                HStack(spacing: 8) {
                    Group {
                        if showsCustomAPIKey {
                            TextField("输入 API Key", text: $customAPIKey)
                        } else {
                            SecureField("输入 API Key", text: $customAPIKey)
                        }
                    }
                    .textFieldStyle(.plain)
                    .textContentType(.oneTimeCode)
                    .font(.system(.body, design: .monospaced))
                    Button { showsCustomAPIKey.toggle() } label: {
                        Image(systemName: showsCustomAPIKey ? "eye.slash.fill" : "eye.fill")
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 10)
                .frame(height: 44)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("API 地址").font(.callout.weight(.semibold))
                formTextField("https://api.example.com/v1", text: $customAPIBaseURL, monospaced: true)
            }
            if let identity = customAPIPreviewIdentity {
                HStack(spacing: 12) {
                    ProviderIconView(identity: identity, size: 38)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(identity.brand.title)
                            .font(.callout.weight(.semibold))
                        Text(identity.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                    Spacer()
                    Label("已自动识别", systemImage: "checkmark.circle.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.green)
                }
                .padding(12)
                .background(identity.brand.tint.opacity(0.055), in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .stroke(identity.brand.tint.opacity(0.14))
                )
            }
            VStack(alignment: .leading, spacing: 7) {
                Text("模型").font(.callout.weight(.semibold))
                formTextField("可留空，将自动选择", text: $customAPIModel, monospaced: true)
            }

            if let error = model.errorMessage {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Spacer()
                Button("取消") { showsCustomAPISheet = false }
                    .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))
                Button {
                    Task {
                        await model.addCustomProfile(
                            name: customAPIName,
                            apiKey: customAPIKey,
                            apiBaseURL: customAPIBaseURL,
                            model: customAPIModel,
                            provider: customAPIProvider
                        )
                        if model.errorMessage == nil {
                            showsCustomAPISheet = false
                            customAPIKey = ""
                        }
                    }
                } label: {
                    if model.isBusy { ProgressView().controlSize(.small) } else { Text("验证并添加") }
                }
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                .disabled(
                    model.isBusy ||
                    customAPIName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    customAPIKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                    customAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                )
            }
        }
        .padding(26)
        .frame(width: 540)
        .onChange(of: customAPIProvider) {
            if customAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                || customAPIBaseURL == CustomAPIProvider.openAI.defaultBaseURL
                || customAPIBaseURL.contains("api.example.com") {
                customAPIBaseURL = customAPIProvider.defaultBaseURL
            }
            customAPIModel = ""
        }
    }

    private var customAPIPreviewIdentity: ProviderIdentity? {
        guard let url = URL(string: customAPIBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              url.scheme?.lowercased() == "https",
              url.host?.isEmpty == false else { return nil }
        return ProviderCatalog.identity(for: url)
    }

    private func applyPreset(_ preset: APIConnectionPreset) {
        customAPIName = preset.name
        customAPIBaseURL = preset.baseURL
        customAPIModel = ""
        customAPIProvider = preset.id == "openai" ? .openAI : .openAICompatible
    }

    private func sheetHeader(
        title: String,
        subtitle: String,
        closeAction: @escaping () -> Void
    ) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.title2.weight(.semibold))
                Text(subtitle).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: closeAction) {
                Image(systemName: "xmark")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color(nsColor: .controlBackgroundColor), in: Circle())
            }
            .buttonStyle(.plain)
            .help("关闭")
        }
    }

    private func formTextField(
        _ placeholder: String,
        text: Binding<String>,
        monospaced: Bool = false
    ) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(monospaced ? .system(.body, design: .monospaced) : .body)
            .padding(.horizontal, 12)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private func secureKeyField(title: String, text: Binding<String>, reveals: Binding<Bool>) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title).font(.callout.weight(.semibold))
            HStack(spacing: 8) {
                Group {
                    if reveals.wrappedValue { TextField("输入托管密钥", text: text) }
                    else { SecureField("输入托管密钥", text: text) }
                }
                .textFieldStyle(.plain)
                .textContentType(.oneTimeCode)
                .font(.system(.body, design: .monospaced))
                Button { reveals.wrappedValue.toggle() } label: {
                    Image(systemName: reveals.wrappedValue ? "eye.slash.fill" : "eye.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 11)
            .frame(height: 44)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
        }
    }

    private var additionalProfileActivationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
            HStack {
                Label("托管密钥", systemImage: "key.fill")
                    .font(.headline)
                Spacer()
                Text("激活后保存为独立密钥档案，并立即切换")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Group {
                            if showsNewActivationKey {
                                TextField("输入新的托管密钥", text: $newActivationKey)
                            } else {
                                SecureField("输入新的托管密钥", text: $newActivationKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .textContentType(.oneTimeCode)
                        .font(.system(.body, design: .monospaced))

                        Button {
                            showsNewActivationKey.toggle()
                        } label: {
                            Image(systemName: showsNewActivationKey ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(showsNewActivationKey ? "隐藏托管密钥" : "显示托管密钥")
                    }
                    .padding(.leading, 13)
                    .padding(.trailing, 9)
                    .frame(height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))

                    Button {
                        Task {
                            await model.addProfile(
                                activationKey: newActivationKey,
                                apiBaseURL: newProfileAPIBaseURL
                            )
                            if model.errorMessage == nil {
                                newActivationKey = ""
                            }
                        }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Text("激活并切换")
                        }
                        .frame(minWidth: 102)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(
                        model.isBusy ||
                        newActivationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                    )
                }

                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("API 地址", systemImage: "network")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("仅支持 HTTPS")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    TextField("https://example.com/v1", text: $newProfileAPIBaseURL)
                        .textFieldStyle(.plain)
                        .font(.system(.callout, design: .monospaced))
                        .padding(.horizontal, 12)
                        .frame(height: 38)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                        .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                        .disabled(model.isBusy)
                }
                Divider()
                HStack(spacing: 16) {
                    usageSummary
                    Spacer(minLength: 12)
                    Button {
                        Task { await model.queryUsage() }
                    } label: {
                        Label("查询", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                    .disabled(model.isBusy)

                    Button(role: .destructive) {
                        Task { await model.uninstall() }
                    } label: {
                        Label("卸载配置", systemImage: "arrow.uturn.backward")
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                    .disabled(model.isBusy)
                }
            }
        }
    }

    @ViewBuilder
    private var usageSummary: some View {
        if let usage = model.usage {
            compactUsageItem(title: "已用", value: formatCurrency(usage.used), color: .orange)
            compactUsageItem(title: "剩余", value: formatCurrency(usage.remaining), color: .green)
            compactUsageItem(
                title: "有效期",
                value: displayExpiry(usage.expiresAt ?? model.expiresAt),
                color: .blue
            )
        } else {
            Label("当前密钥用量尚未查询", systemImage: "chart.bar.xaxis")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func compactUsageItem(title: String, value: String, color: Color) -> some View {
        HStack(spacing: 5) {
            Text(title)
                .foregroundStyle(.secondary)
            Text(value)
                .foregroundStyle(color)
                .fontWeight(.semibold)
        }
        .font(.caption)
        .lineLimit(1)
    }

    private func displayExpiry(_ value: String?) -> String {
        guard let value, !value.isEmpty else { return "—" }
        let normalized = value.replacingOccurrences(of: "T", with: " ")
        guard normalized.count >= 19 else { return normalized }
        return String(normalized.prefix(19))
    }

    private var statusPill: some View {
        let connected = effectiveMode != nil
        return HStack(spacing: 7) {
            BreathingStatusDot(
                color: connected ? .green : .secondary,
                active: connected
            )
            Text(connected ? "已连接" : "未连接")
                .font(.caption.weight(.semibold))
            if model.requiresCodexReload {
                Divider().frame(height: 14)
                Button {
                    Task { await model.reloadCodex() }
                } label: {
                    Label("重新载入", systemImage: "arrow.clockwise")
                }
                .buttonStyle(HarborActionButtonStyle(tint: .orange, prominence: .secondary))
                .disabled(model.isBusy)
                .help("连接已切换，点击重新载入 Codex")
            }
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 7)
        .background(Color(nsColor: .windowBackgroundColor), in: Capsule())
        .overlay(Capsule().stroke(.quaternary))
    }

    private var activationCard: some View {
        card {
            VStack(alignment: .leading, spacing: 16) {
                Label("托管密钥", systemImage: "key.fill")
                    .font(.headline)
                HStack(spacing: 10) {
                    HStack(spacing: 8) {
                        Group {
                            if showsActivationKey {
                                TextField("输入你的托管密钥", text: $model.activationKey)
                            } else {
                                SecureField("输入你的托管密钥", text: $model.activationKey)
                            }
                        }
                        .textFieldStyle(.plain)
                        .font(.system(.body, design: .monospaced))
                        .textContentType(.oneTimeCode)

                        Button {
                            showsActivationKey.toggle()
                        } label: {
                            Image(systemName: showsActivationKey ? "eye.slash.fill" : "eye.fill")
                                .foregroundStyle(.secondary)
                                .frame(width: 24, height: 28)
                        }
                        .buttonStyle(.plain)
                        .help(showsActivationKey ? "隐藏托管密钥" : "显示托管密钥")
                        .accessibilityLabel(showsActivationKey ? "隐藏托管密钥" : "显示托管密钥")
                    }
                    .padding(.leading, 13)
                    .padding(.trailing, 9)
                    .frame(height: 44)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(.quaternary))
                    Button {
                        Task { await model.activate() }
                    } label: {
                        HStack(spacing: 7) {
                            if model.isBusy { ProgressView().controlSize(.small) }
                            Text("激活并配置")
                        }
                        .frame(minWidth: 102)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(model.isBusy || model.activationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Label("API 地址", systemImage: "network")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Text("仅支持 HTTPS")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    TextField("https://example.com/v1", text: Binding(
                        get: { model.apiBaseURLInput },
                        set: { model.setAPIBaseURLInput($0) }
                    ))
                    .textFieldStyle(.plain)
                    .font(.system(.callout, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).stroke(.quaternary))
                    .disabled(model.isBusy)
                }
                HStack {
                    Button("查询用量") {
                        Task { await model.queryUsage() }
                    }
                    .buttonStyle(.link)
                    .disabled(model.isBusy || model.activationKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    Spacer()
                }
                Text("密钥和服务令牌保存在 Harbor 私有凭据文件中，不会写入 Codex 配置或日志。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var logCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                withAnimation(.snappy(duration: 0.24)) {
                    isLogExpanded.toggle()
                }
            } label: {
                HStack(spacing: 10) {
                    Label("运行日志", systemImage: "text.alignleft")
                        .font(.headline)
                    Circle()
                        .fill(effectiveMode == nil ? Color.secondary : Color.green)
                        .frame(width: 7, height: 7)
                    Text(effectiveMode == nil ? "未连接" : "已连接")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(effectiveMode == nil ? Color.secondary : Color.green)
                    // Reserve the same space while an operation is running so
                    // the log bar never changes width or causes a visible jump.
                    HStack(spacing: 7) {
                        if model.isBusy {
                            ProgressView().controlSize(.small)
                        } else {
                            Color.clear.frame(width: 12, height: 12)
                        }
                        Text(model.isBusy ? model.activity : "")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    .frame(width: 170, alignment: .leading)
                    Spacer()
                    if let latest = model.logs.last?.timeText {
                        Text("最近 \(latest)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Image(systemName: isLogExpanded ? "chevron.down" : "chevron.up")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
                .padding(.horizontal, 18)
                .frame(height: 56)
            }
            .buttonStyle(.plain)

            if isLogExpanded {
                Divider()
                HStack {
                    Text("最多保留 200 条")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Spacer()
                    Button("清空") { model.clearLogs() }
                        .buttonStyle(.plain)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 18)
                .padding(.top, 10)

                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 7) {
                            if model.logs.isEmpty {
                                Text("暂无日志")
                                    .foregroundStyle(.tertiary)
                                    .frame(maxWidth: .infinity, minHeight: 92, alignment: .center)
                            } else {
                                ForEach(model.logs) { entry in
                                    logRow(entry)
                                        .id(entry.id)
                                }
                            }
                        }
                        .padding(12)
                    }
                    .frame(height: 96)
                    .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
                    .overlay(RoundedRectangle(cornerRadius: 11).stroke(.quaternary))
                    .padding(.horizontal, 14)
                    .padding(.bottom, 14)
                    .onChange(of: model.logs.count) {
                        guard let last = model.logs.last else { return }
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
        .background(Color(nsColor: .textBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.primary.opacity(0.10))
        )
        .frame(height: isLogExpanded ? 172 : 56)
        .animation(.snappy(duration: 0.24), value: isLogExpanded)
    }

    private func logRow(_ entry: HarborLogEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(entry.timeText)
                .foregroundStyle(.tertiary)
                .frame(width: 68, alignment: .leading)
            Image(systemName: logIcon(entry.level))
                .foregroundStyle(logColor(entry.level))
                .frame(width: 13)
            Text(entry.message)
                .foregroundStyle(entry.level == .error ? Color.red : Color.primary.opacity(0.82))
                .textSelection(.enabled)
        }
        .font(.system(size: 11.5, design: .monospaced))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func logIcon(_ level: HarborLogEntry.Level) -> String {
        switch level {
        case .info: "circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "xmark.octagon.fill"
        }
    }

    private func logColor(_ level: HarborLogEntry.Level) -> Color {
        switch level {
        case .info: .blue
        case .success: .green
        case .error: .red
        }
    }

    private func formatCurrency(_ value: Double?) -> String {
        guard let value else { return "—" }
        return value.formatted(.number.precision(.fractionLength(2))) + " 美元"
    }

    private func card<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(16)
            .frame(
                maxWidth: .infinity,
                alignment: .topLeading
            )
            .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 15, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 15, style: .continuous).stroke(Color.secondary.opacity(0.13)))
    }
}
