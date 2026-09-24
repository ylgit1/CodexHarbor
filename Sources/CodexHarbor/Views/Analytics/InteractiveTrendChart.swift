import Charts
import SwiftUI

struct HarborTrendSeriesData: Identifiable {
    let id: String
    let title: String
    let color: Color
    let values: [Int]
}

struct HarborInteractiveTrendChart: View {
    let title: String
    let labels: [String]
    let series: [HarborTrendSeriesData]
    var height: CGFloat = 240
    var compact: Bool = false

    @State private var selectedIndex: Int?
    @State private var hiddenSeries: Set<String> = []
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var visibleSeries: [HarborTrendSeriesData] {
        series.filter { !hiddenSeries.contains($0.id) }
    }

    private var axisIndices: [Int] {
        guard labels.count > 1 else { return [0] }
        if labels.count <= 8 { return Array(labels.indices) }

        let step = max(1, labels.count / 6)
        var result = Array(stride(from: 0, to: labels.count, by: step))
        if result.last != labels.count - 1 { result.append(labels.count - 1) }
        return result
    }

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 8 : 12) {
            HStack(spacing: 12) {
                Text(title)
                    .font(.system(size: compact ? 12.5 : 13.5, weight: .semibold))

                Spacer(minLength: 12)

                HStack(spacing: 8) {
                    ForEach(series) { item in
                        legendChip(item)
                    }
                }
            }

            Chart {
                ForEach(visibleSeries) { item in
                    ForEach(Array(item.values.enumerated()), id: \.offset) { index, value in
                        AreaMark(
                            x: .value("Index", index),
                            yStart: .value("Baseline", 0),
                            yEnd: .value("Value", value),
                            series: .value("Series", item.id)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [
                                    item.color.opacity(compact ? 0.075 : 0.11),
                                    item.color.opacity(0.006)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)

                        LineMark(
                            x: .value("Index", index),
                            y: .value("Value", value),
                            series: .value("Series", item.id)
                        )
                        .foregroundStyle(item.color)
                        .lineStyle(
                            StrokeStyle(
                                lineWidth: compact ? 2.0 : 2.25,
                                lineCap: .round,
                                lineJoin: .round
                            )
                        )
                        .interpolationMethod(.monotone)
                    }
                }
            }
            .chartLegend(.hidden)
            .chartXScale(domain: 0...max(labels.count - 1, 1))
            .chartXAxis {
                AxisMarks(values: axisIndices) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.06))
                    AxisValueLabel {
                        if let index = value.as(Int.self),
                           labels.indices.contains(index) {
                            Text(labels[index])
                                .font(.system(size: compact ? 8 : 8.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading) { value in
                    AxisGridLine()
                        .foregroundStyle(Color.secondary.opacity(0.10))
                    AxisValueLabel {
                        if let intValue = value.as(Int.self) {
                            Text(compactNumber(intValue))
                                .font(.system(size: 8.5))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
            }
            .chartPlotStyle { plot in
                plot.background(
                    LinearGradient(
                        colors: [HarborColors.blue.opacity(0.010), Color.clear],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                )
            }
            .chartOverlay { proxy in
                GeometryReader { geometry in
                    let plotFrame = proxy.plotFrame.map { geometry[$0] }

                    ZStack(alignment: .topLeading) {
                        Rectangle()
                            .fill(Color.clear)
                            .contentShape(Rectangle())
                            .onContinuousHover { phase in
                                guard let plotFrame else { return }
                                switch phase {
                                case let .active(location):
                                    updateSelection(locationX: location.x, plotFrame: plotFrame)
                                case .ended:
                                    selectedIndex = nil
                                }
                            }
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        guard let plotFrame else { return }
                                        updateSelection(locationX: value.location.x, plotFrame: plotFrame)
                                    }
                                    .onEnded { _ in
                                        selectedIndex = nil
                                    }
                            )

                        if let selectedIndex,
                           let plotFrame,
                           labels.indices.contains(selectedIndex) {
                            let x = selectionX(index: selectedIndex, plotFrame: plotFrame)

                            Rectangle()
                                .fill(HarborColors.blue.opacity(0.24))
                                .frame(width: 1, height: plotFrame.height)
                                .offset(x: x, y: plotFrame.minY)
                                .allowsHitTesting(false)

                            selectionDots(index: selectedIndex, proxy: proxy, plotFrame: plotFrame)
                                .allowsHitTesting(false)

                            tooltip(index: selectedIndex)
                                .fixedSize()
                                .offset(
                                    x: tooltipX(selectionX: x, plotFrame: plotFrame),
                                    y: plotFrame.minY + 8
                                )
                                .allowsHitTesting(false)
                        }
                    }
                }
            }
            .frame(height: height)
            .animation(
                reduceMotion ? nil : .easeOut(duration: 0.16),
                value: hiddenSeries
            )
        }
    }

    @ViewBuilder
    private func selectionDots(index: Int, proxy: ChartProxy, plotFrame: CGRect) -> some View {
        ForEach(visibleSeries) { item in
            if item.values.indices.contains(index),
               let yPosition = proxy.position(forY: item.values[index]) {
                Circle()
                    .fill(HarborColors.cardBackground)
                    .frame(width: compact ? 8 : 9, height: compact ? 8 : 9)
                    .overlay(
                        Circle()
                            .stroke(item.color, lineWidth: 2)
                    )
                    .offset(
                        x: selectionX(index: index, plotFrame: plotFrame) - (compact ? 4 : 4.5),
                        y: plotFrame.minY + yPosition - (compact ? 4 : 4.5)
                    )
            }
        }
    }

    private func legendChip(_ item: HarborTrendSeriesData) -> some View {
        let hidden = hiddenSeries.contains(item.id)

        return Button {
            withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) {
                if hidden {
                    hiddenSeries.remove(item.id)
                } else if visibleSeries.count > 1 {
                    hiddenSeries.insert(item.id)
                }
            }
        } label: {
            HStack(spacing: 5) {
                Circle()
                    .fill(item.color)
                    .frame(width: 7, height: 7)
                Text(item.title)
                    .font(.system(size: 9.5, weight: .semibold))
            }
            .foregroundStyle(hidden ? Color.secondary : item.color)
            .padding(.horizontal, 8)
            .frame(height: 23)
            .background(
                (hidden ? Color.secondary : item.color).opacity(hidden ? 0.045 : 0.075),
                in: Capsule()
            )
            .overlay(
                Capsule()
                    .stroke(
                        (hidden ? Color.secondary : item.color)
                            .opacity(hidden ? 0.09 : 0.18)
                    )
            )
            .opacity(hidden ? 0.50 : 1)
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
        .help(hidden ? "显示\(item.title)" : "隐藏\(item.title)")
    }

    private func tooltip(index: Int) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(labels[index])
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundStyle(.secondary)

            ForEach(visibleSeries) { item in
                HStack(spacing: 7) {
                    Circle()
                        .fill(item.color)
                        .frame(width: 6, height: 6)

                    Text(item.title)
                        .font(.system(size: 9.5, weight: .medium))

                    Spacer(minLength: 8)

                    Text(compactNumber(item.values.indices.contains(index) ? item.values[index] : 0))
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(minWidth: compact ? 138 : 160)
        .background(
            HarborColors.cardBackground,
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color.primary.opacity(0.08))
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 6)
    }

    private func updateSelection(locationX: CGFloat, plotFrame: CGRect) {
        guard !labels.isEmpty,
              locationX >= plotFrame.minX,
              locationX <= plotFrame.maxX else {
            return
        }

        let relativeX = locationX - plotFrame.minX
        let plotWidth = max(plotFrame.width, 1)
        let raw = Int(round((relativeX / plotWidth) * CGFloat(max(labels.count - 1, 0))))
        selectedIndex = min(max(raw, 0), labels.count - 1)
    }

    private func selectionX(index: Int, plotFrame: CGRect) -> CGFloat {
        guard labels.count > 1 else { return plotFrame.minX }
        return plotFrame.minX
            + plotFrame.width * CGFloat(index) / CGFloat(labels.count - 1)
    }

    private func tooltipX(selectionX: CGFloat, plotFrame: CGRect) -> CGFloat {
        let width: CGFloat = compact ? 148 : 170
        let preferred = selectionX + 10
        if preferred + width <= plotFrame.maxX {
            return preferred
        }
        return max(plotFrame.minX, selectionX - width - 10)
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
