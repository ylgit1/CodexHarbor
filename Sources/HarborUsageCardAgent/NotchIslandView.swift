import AppKit
import SwiftUI
import CodexHarborCore

/// A single silhouette is rendered flush with the physical notch.
/// The top two corners are square against the display edge; only the bottom
/// corners round off, giving a seamless rather than floating-card appearance.
struct HarborIslandSilhouette: Shape {
    var bottomRadius: CGFloat

    var animatableData: CGFloat {
        get { bottomRadius }
        set { bottomRadius = newValue }
    }

    func path(in rect: CGRect) -> Path {
        let radius = min(bottomRadius, rect.width / 2, rect.height / 2)
        return Path { path in
            path.move(to: CGPoint(x: rect.minX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
            path.addQuadCurve(
                to: CGPoint(x: rect.maxX - radius, y: rect.maxY),
                control: CGPoint(x: rect.maxX, y: rect.maxY)
            )
            path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
            path.addQuadCurve(
                to: CGPoint(x: rect.minX, y: rect.maxY - radius),
                control: CGPoint(x: rect.minX, y: rect.maxY)
            )
            path.closeSubpath()
        }
    }
}

private struct IslandQuotaRing: View {
    let remaining: Double?
    let tint: Color

    var body: some View {
        ZStack {
            Circle()
                .stroke(tint.opacity(0.26), lineWidth: 2.5)
            Circle()
                .trim(from: 0, to: max(0, min(1, (remaining ?? 0) / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

private struct IslandCompactMetrics: View {
    let title: String
    let percent: String
    let countdown: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .medium))
                    .foregroundStyle(.white.opacity(0.69))
                Spacer(minLength: 1)
                Text(percent)
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            Text(countdown)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.75))
                .lineLimit(1)
                .minimumScaleFactor(0.76)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IslandCompactWing: View {
    @ObservedObject var model: NotchQuotaModel
    let isFiveHours: Bool

    private var window: CodexQuotaWindow? {
        isFiveHours ? model.quota?.fiveHours : model.quota?.weekly
    }

    var body: some View {
        HStack(spacing: 5) {
            IslandQuotaRing(remaining: model.remaining(window), tint: model.tint(window))
            IslandCompactMetrics(
                title: isFiveHours ? "5小时" : "周额度",
                percent: model.text(window),
                countdown: model.countdown(window).map { "重置 " + $0 } ?? "重置待定"
            )
        }
        .padding(.horizontal, 6)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
            (isFiveHours ? "5 小时" : "每周") + "额度，剩余 " +
            model.text(window) + "，" + model.fullCountdown(window)
        )
    }
}

private struct IslandQuotaDetailColumn: View {
    @ObservedObject var model: NotchQuotaModel
    let title: String
    let window: CodexQuotaWindow?

    private var tint: Color { model.tint(window) }
    private var remaining: Double? { model.remaining(window) }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.64))

            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 27, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text("剩余")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.59))
            }

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.15))
                    Capsule().fill(tint)
                        .frame(width: proxy.size.width *
                            max(0, min(1, (remaining ?? 0) / 100)))
                }
            }
            .frame(height: 4)

            Text(window.map {
                "已用 \(Int($0.usedPercent.rounded()))%  ·  剩余 \(Int($0.remainingPercent.rounded()))%"
            } ?? "正在读取额度")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.67))

            Text(model.fullCountdown(window))
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.88))

            Text(window?.resetDate.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "重置时间未提供")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.54))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct IslandExpandedDetails: View {
    @ObservedObject var model: NotchQuotaModel

    private var updateText: String {
        guard let snapshot = model.quota else { return model.message }
        let prefix = model.isDelayed ? "上次同步 " : "更新 "
        return prefix + snapshot.capturedAt.formatted(date: .omitted, time: .shortened)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 6) {
                Image(systemName: "circle.hexagongrid.fill")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(red: 0.21, green: 0.91, blue: 0.67))
                Text("Codex 额度")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Spacer()
                Text(model.quota?.planType?.uppercased() ?? "账户额度")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(alignment: .top, spacing: 20) {
                IslandQuotaDetailColumn(
                    model: model, title: "5 小时额度", window: model.quota?.fiveHours
                )
                IslandQuotaDetailColumn(
                    model: model, title: "每周额度", window: model.quota?.weekly
                )
            }

            Rectangle()
                .fill(Color.white.opacity(0.13))
                .frame(height: 1)

            HStack(spacing: 7) {
                Label(updateText, systemImage: model.isDelayed ?
                      "clock.arrow.circlepath" : "arrow.clockwise")
                Spacer(minLength: 5)
                if let available = model.quota?.resetCreditsAvailable {
                    Label("重置卡 \(available) 张", systemImage: "ticket")
                }
            }
            .font(.system(size: 10))
            .foregroundStyle(.white.opacity(0.63))
            .lineLimit(1)

            if model.isDelayed {
                Text(model.lastReadFailed ?
                     model.message : "额度数据更新稍有延迟")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.8))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, 19)
        .padding(.top, 14)
        .padding(.bottom, 13)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// One hosting view and one NSPanel for both compact and expanded states.
/// The hidden physical camera gap is exactly the center spacer width.
struct NotchIslandView: View {
    @ObservedObject var model: NotchQuotaModel
    let compactHeight: CGFloat
    let expandedHeight: CGFloat
    let hover: (Bool) -> Void

    private var wingWidth: CGFloat { model.wingWidth }
    private var notchWidth: CGFloat { model.notchWidth }
    private var islandWidth: CGFloat { notchWidth + 2 * wingWidth }

    var body: some View {
        // The view hierarchy and its content stay fixed at full height.
        // AppKit alone animates the window frame; the moving window bounds clip
        // the pre-laid-out detail section, preventing two layout animations
        // from fighting and moving the compact content under the pointer.
        GeometryReader { geometry in
            let height = max(compactHeight, geometry.size.height)
            let travel = max(1, expandedHeight - compactHeight)
            let progress = min(1, max(0, (height - compactHeight) / travel))
            let shape = HarborIslandSilhouette(bottomRadius: 12 + 11 * progress)

            VStack(spacing: 0) {
                HStack(spacing: 0) {
                    IslandCompactWing(model: model, isFiveHours: true)
                        .frame(width: wingWidth)
                    Color.clear
                        .frame(width: notchWidth)
                        .accessibilityHidden(true)
                    IslandCompactWing(model: model, isFiveHours: false)
                        .frame(width: wingWidth)
                }
                .frame(height: compactHeight)

                IslandExpandedDetails(model: model)
                    .frame(height: travel, alignment: .top)
                    .opacity(min(1, max(0, (progress - 0.1) / 0.55)))
            }
            .frame(width: islandWidth, height: expandedHeight, alignment: .top)
            .frame(width: islandWidth, height: height, alignment: .top)
            .background(shape.fill(Color.black))
            .overlay(shape.stroke(Color.white.opacity(progress * 0.12), lineWidth: 0.75))
            .clipShape(shape)
            .contentShape(shape)
            .onHover(perform: hover)
            .accessibilityLabel(
                model.expanded ? "Codex 套餐额度详情" : "Codex 刘海额度"
            )
        }
        .frame(width: islandWidth)
    }
}
