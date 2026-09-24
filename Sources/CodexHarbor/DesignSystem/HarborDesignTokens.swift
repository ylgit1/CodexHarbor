import AppKit
import SwiftUI

enum HarborSpacing {
    static let xxs: CGFloat = 4
    static let xs: CGFloat = 6
    static let sm: CGFloat = 8
    static let md: CGFloat = 12
    static let lg: CGFloat = 16
    static let xl: CGFloat = 20
    static let xxl: CGFloat = 24
    static let xxxl: CGFloat = 32
}

enum HarborRadius {
    static let small: CGFloat = 8
    static let medium: CGFloat = 10
    static let card: CGFloat = 14
    static let large: CGFloat = 18
}

enum HarborColors {
    static let blue = Color(red: 0.105, green: 0.405, blue: 0.94)
    static let green = Color(red: 0.095, green: 0.69, blue: 0.36)
    static let purple = Color(red: 0.49, green: 0.29, blue: 0.90)
    static let orange = Color(red: 0.98, green: 0.49, blue: 0.16)
    static let red = Color(red: 0.93, green: 0.24, blue: 0.28)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBackground = Color(nsColor: .textBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.075)
}

struct HarborCard<Content: View>: View {
    var padding: CGFloat = HarborSpacing.lg
    var interactive: Bool = true
    @ViewBuilder var content: Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        content
            .padding(padding)
            .background(
                ZStack {
                    RoundedRectangle(cornerRadius: HarborRadius.card, style: .continuous)
                        .fill(HarborColors.cardBackground)
                    if interactive {
                        RoundedRectangle(cornerRadius: HarborRadius.card, style: .continuous)
                            .fill(
                                LinearGradient(
                                    colors: [
                                        HarborColors.blue.opacity(hovering ? 0.045 : 0),
                                        HarborColors.purple.opacity(hovering ? 0.018 : 0)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                )
                            )
                    }
                }
            )
            .overlay(
                RoundedRectangle(cornerRadius: HarborRadius.card, style: .continuous)
                    .stroke(
                        interactive && hovering
                            ? HarborColors.blue.opacity(0.18)
                            : HarborColors.cardBorder,
                        lineWidth: 1
                    )
            )
            .shadow(
                color: .black.opacity(interactive && hovering ? 0.075 : 0.025),
                radius: interactive && hovering ? 14 : 8,
                y: interactive && hovering ? 6 : 2
            )
            .offset(y: interactive && hovering && !reduceMotion ? -1.5 : 0)
            .scaleEffect(interactive && hovering && !reduceMotion ? 1.003 : 1)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.18),
                value: hovering
            )
            .onHover { hovering = interactive && $0 }
    }
}

struct HarborStatusBadge: View {
    let title: String
    let color: Color
    var pulses: Bool? = nil

    @State private var pulse = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var shouldPulse: Bool {
        if let pulses { return pulses }
        return title.contains("当前使用")
            || title == "已连接"
            || title == "运行中"
            || title == "连接中"
    }

    var body: some View {
        HStack(spacing: 5) {
            ZStack {
                if shouldPulse && !reduceMotion {
                    Circle()
                        .stroke(color.opacity(0.30), lineWidth: 1.5)
                        .frame(width: 10, height: 10)
                        .scaleEffect(pulse ? 1.7 : 0.7)
                        .opacity(pulse ? 0 : 0.7)
                }
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            .frame(width: 10, height: 10)

            Text(title)
        }
        .font(.system(size: 10, weight: .semibold))
        .foregroundStyle(color)
        .padding(.horizontal, 7)
        .frame(height: 21)
        .background(
            LinearGradient(
                colors: [color.opacity(0.12), color.opacity(0.065)],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            ),
            in: Capsule()
        )
        .overlay(Capsule().stroke(color.opacity(0.10)))
        .accessibilityElement(children: .combine)
        .onAppear {
            guard shouldPulse && !reduceMotion else { return }
            withAnimation(.easeOut(duration: 1.45).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

struct HarborActionButtonStyle: ButtonStyle {
    enum Prominence {
        case prominent
        case secondary
    }

    let tint: Color
    let prominence: Prominence

    func makeBody(configuration: Configuration) -> some View {
        HarborActionButtonBody(
            configuration: configuration,
            tint: tint,
            prominence: prominence
        )
    }
}

private struct HarborActionButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let prominence: HarborActionButtonStyle.Prominence

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: prominence == .prominent ? .semibold : .medium))
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, prominence == .prominent ? 13 : 11)
            .frame(minHeight: prominence == .prominent ? 34 : 32)
            .background(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .scaleEffect(
                reduceMotion || !enabled
                    ? 1
                    : (configuration.isPressed ? 0.982 : 1)
            )
            .opacity(enabled ? 1 : 0.62)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.14),
                value: hovering
            )
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.09),
                value: configuration.isPressed
            )
            .onHover { hovering = enabled && $0 }
    }

    private var backgroundColor: Color {
        guard enabled else { return tint.opacity(0.055) }
        if configuration.isPressed {
            return prominence == .prominent ? tint.opacity(0.84) : tint.opacity(0.15)
        }
        if hovering {
            return tint.opacity(0.16)
        }
        return .clear
    }

    private var borderColor: Color {
        guard enabled else { return tint.opacity(0.10) }
        if configuration.isPressed {
            return tint.opacity(prominence == .prominent ? 0.88 : 0.34)
        }
        if hovering {
            return tint.opacity(prominence == .prominent ? 0.72 : 0.26)
        }
        return prominence == .prominent
            ? tint.opacity(0.90)
            : tint.opacity(0.16)
    }

    private var foregroundColor: Color {
        guard enabled else { return tint.opacity(0.64) }
        return tint
    }
}

struct HarborInteractivePlainButtonStyle: ButtonStyle {
    var tint: Color = HarborColors.blue
    var cornerRadius: CGFloat = 10

    func makeBody(configuration: Configuration) -> some View {
        HarborInteractivePlainButtonBody(
            configuration: configuration,
            tint: tint,
            cornerRadius: cornerRadius
        )
    }
}

private struct HarborInteractivePlainButtonBody: View {
    let configuration: ButtonStyle.Configuration
    let tint: Color
    let cornerRadius: CGFloat

    @State private var hovering = false
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(
                        tint.opacity(
                            !enabled
                                ? 0
                                : (configuration.isPressed ? 0.10 : (hovering ? 0.055 : 0))
                        )
                    )
            )
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(
                        tint.opacity(hovering && enabled ? 0.16 : 0),
                        lineWidth: 1
                    )
            )
            .scaleEffect(
                reduceMotion || !enabled
                    ? 1
                    : (configuration.isPressed ? 0.988 : 1)
            )
            .opacity(enabled ? 1 : 0.40)
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.15),
                value: hovering
            )
            .animation(
                reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.10),
                value: configuration.isPressed
            )
            .onHover { hovering = enabled && $0 }
    }
}

struct HarborSegmentControl<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var namespace

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    withAnimation(reduceMotion ? .linear(duration: 0.01) : .spring(response: 0.25, dampingFraction: 0.86)) {
                        selection = option.0
                    }
                } label: {
                    Text(option.1)
                        .font(.system(size: 11, weight: selection == option.0 ? .semibold : .medium))
                        .foregroundStyle(selection == option.0 ? HarborColors.blue : Color.secondary)
                        .frame(minWidth: 48, maxWidth: .infinity, minHeight: 27)
                        .background {
                            if selection == option.0 {
                                RoundedRectangle(cornerRadius: 7, style: .continuous)
                                    .fill(HarborColors.cardBackground)
                                    .shadow(color: .black.opacity(0.055), radius: 2, y: 1)
                                    .matchedGeometryEffect(id: "segment", in: namespace)
                            }
                        }
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .frame(height: 32)
    }
}
