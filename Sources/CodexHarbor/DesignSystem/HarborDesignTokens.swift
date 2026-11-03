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
    static let blue = Color.accentColor
    static let green = Color(nsColor: .systemGreen)
    static let purple = Color(nsColor: .systemPurple)
    static let orange = Color(nsColor: .systemOrange)
    static let red = Color(nsColor: .systemRed)
    static let background = Color(nsColor: .windowBackgroundColor)
    static let sidebarBackground = Color(nsColor: .controlBackgroundColor)
    static let cardBackground = Color(nsColor: .textBackgroundColor)
    static let cardBorder = Color.primary.opacity(0.085)
}

/// Unified flat container. It never repaints for hover or starts animations.
struct HarborCard<Content: View>: View {
    var padding: CGFloat = HarborSpacing.lg
    var interactive: Bool = true
    @ViewBuilder var content: Content

    var body: some View {
        content
            .padding(padding)
            .background(
                HarborColors.cardBackground,
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11, style: .continuous)
                    .stroke(HarborColors.cardBorder, lineWidth: 1)
            }
    }
}

/// Statuses are static. Live values still update when their model changes.
struct HarborStatusBadge: View {
    let title: String
    let color: Color
    var pulses: Bool? = nil

    var body: some View {
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(title).lineLimit(1)
        }
        .font(.system(size: 10, weight: .medium))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 9)
        .frame(height: 25)
        .background(Color.primary.opacity(0.035), in: Capsule())
        .accessibilityElement(children: .combine)
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
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(prominence == .prominent ? Color.white : tint)
            .padding(.horizontal, 12)
            .frame(minHeight: 32)
            .background(
                prominence == .prominent ? tint : Color.primary.opacity(0.035),
                in: RoundedRectangle(cornerRadius: 8)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(
                        prominence == .prominent ? Color.clear : HarborColors.cardBorder,
                        lineWidth: 1
                    )
            }
            .opacity(enabled ? (configuration.isPressed ? 0.76 : 1) : 0.42)
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
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        configuration.label
            .background(
                configuration.isPressed ? tint.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: cornerRadius)
            )
            .opacity(enabled ? 1 : 0.42)
    }
}

struct HarborSegmentControl<Value: Hashable>: View {
    let options: [(Value, String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options.indices, id: \.self) { index in
                let option = options[index]
                Button {
                    selection = option.0
                } label: {
                    Text(option.1)
                        .font(.system(size: 11, weight: selection == option.0 ? .semibold : .medium))
                        .foregroundStyle(selection == option.0 ? Color.primary : Color.secondary)
                        .frame(minWidth: 48, maxWidth: .infinity, minHeight: 28)
                        .background(
                            selection == option.0 ? HarborColors.cardBackground : Color.clear,
                            in: RoundedRectangle(cornerRadius: 7)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == option.0 ? .isSelected : [])
            }
        }
        .padding(3)
        .background(Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
        .frame(height: 34)
    }
}
