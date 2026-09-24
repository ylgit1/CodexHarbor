import SwiftUI
import ChatGPTBridgeCore

struct HarborConnectionStage: View {
    let title: String
    let icon: String
    let detail: String
    let state: BridgeNodeState

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        state.harborColor
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            let time = timeline.date.timeIntervalSinceReferenceDate
            let wave = (sin(time * 2.6) + 1) * 0.5
            let shouldPulse = !reduceMotion && state != .waiting && state != .failed

            VStack(spacing: 6) {
                ZStack {
                    if shouldPulse {
                        Circle()
                            .stroke(color.opacity(0.20 + wave * 0.08), lineWidth: 1.2)
                            .frame(width: 49, height: 49)
                            .scaleEffect(1 + wave * 0.10)
                    }

                    Circle()
                        .fill(color.opacity(state == .failed ? 0.11 : 0.10))
                        .frame(width: 44, height: 44)
                        .overlay(
                            Circle()
                                .stroke(color.opacity(state == .waiting ? 0.10 : 0.24), lineWidth: 1)
                        )

                    Image(systemName: icon)
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(color)

                    if state == .failed {
                        Image(systemName: "exclamationmark.circle.fill")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(HarborColors.red)
                            .background(Circle().fill(HarborColors.cardBackground))
                            .offset(x: 16, y: -16)
                    }
                }
                .frame(width: 54, height: 54)

                Text(title)
                    .font(.system(size: 9.5, weight: .semibold))
                    .lineLimit(1)

                Text(detail)
                    .font(.system(size: 8.5, weight: .medium))
                    .foregroundStyle(color)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
        }
    }
}

extension BridgeNodeState {
    var harborColor: Color {
        switch self {
        case .ready: HarborColors.green
        case .connecting: HarborColors.blue
        case .recovering: HarborColors.orange
        case .waiting: .secondary
        case .failed: HarborColors.red
        }
    }

    var displayTitle: String {
        switch self {
        case .ready: "正常"
        case .connecting: "连接中"
        case .recovering: "正在恢复"
        case .waiting: "等待"
        case .failed: "失败"
        }
    }
}

struct HarborAnimatedFlowConnector: View {
    let ready: Bool
    let active: Bool
    let failed: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var color: Color {
        if failed { return HarborColors.red }
        if ready { return HarborColors.green }
        if active { return HarborColors.blue }
        return .secondary
    }

    private var isFlowing: Bool {
        (ready || active) && !failed
    }

    var body: some View {
        TimelineView(.animation) { timeline in
            Canvas { context, size in
                let time = timeline.date.timeIntervalSinceReferenceDate
                let speed = active && !ready ? 0.58 : 0.34
                let phase = reduceMotion
                    ? 0.42
                    : (time * speed).truncatingRemainder(dividingBy: 1)

                let path = flowPath(in: size)

                context.stroke(
                    path,
                    with: .color(color.opacity(ready || active || failed ? 0.22 : 0.10)),
                    style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
                )

                guard isFlowing else { return }

                let startX = size.width * (phase * 1.65 - 0.70)
                let endX = startX + size.width * 0.72
                let gradient = Gradient(stops: [
                    .init(color: .clear, location: 0),
                    .init(color: color.opacity(0.18), location: 0.22),
                    .init(color: color.opacity(0.95), location: 0.56),
                    .init(color: color.opacity(0.24), location: 0.78),
                    .init(color: .clear, location: 1)
                ])

                context.stroke(
                    path,
                    with: .linearGradient(
                        gradient,
                        startPoint: CGPoint(x: startX, y: size.height * 0.5),
                        endPoint: CGPoint(x: endX, y: size.height * 0.5)
                    ),
                    style: StrokeStyle(lineWidth: 2.15, lineCap: .round)
                )

                guard !reduceMotion else { return }

                for offset in [0.08, 0.56] {
                    let progress = (phase + offset).truncatingRemainder(dividingBy: 1)
                    let point = cubicPoint(progress, in: size)

                    let glowRect = CGRect(
                        x: point.x - 4.5,
                        y: point.y - 4.5,
                        width: 9,
                        height: 9
                    )
                    context.fill(
                        Path(ellipseIn: glowRect),
                        with: .color(color.opacity(0.10))
                    )

                    let particleRect = CGRect(
                        x: point.x - 2.1,
                        y: point.y - 2.1,
                        width: 4.2,
                        height: 4.2
                    )
                    context.fill(
                        Path(ellipseIn: particleRect),
                        with: .color(color.opacity(0.95))
                    )
                }
            }
        }
        .accessibilityHidden(true)
    }

    private func flowPath(in size: CGSize) -> Path {
        var path = Path()
        let y = size.height * 0.5
        path.move(to: CGPoint(x: 0, y: y))
        path.addCurve(
            to: CGPoint(x: size.width, y: y),
            control1: CGPoint(x: size.width * 0.30, y: y - 4),
            control2: CGPoint(x: size.width * 0.70, y: y + 4)
        )
        return path
    }

    private func cubicPoint(_ t: Double, in size: CGSize) -> CGPoint {
        let p0 = CGPoint(x: 0, y: size.height * 0.5)
        let p1 = CGPoint(x: size.width * 0.30, y: size.height * 0.5 - 4)
        let p2 = CGPoint(x: size.width * 0.70, y: size.height * 0.5 + 4)
        let p3 = CGPoint(x: size.width, y: size.height * 0.5)

        let mt = 1 - t
        let x = mt * mt * mt * p0.x
            + 3 * mt * mt * t * p1.x
            + 3 * mt * t * t * p2.x
            + t * t * t * p3.x
        let y = mt * mt * mt * p0.y
            + 3 * mt * mt * t * p1.y
            + 3 * mt * t * t * p2.y
            + t * t * t * p3.y

        return CGPoint(x: x, y: y)
    }
}
