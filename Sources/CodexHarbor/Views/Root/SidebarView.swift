import SwiftUI
import AppKit

enum HarborMainPage: String, CaseIterable, Identifiable {
    case home
    case connections
    case analytics
    case localAccess
    case networkProxy
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "工作台"
        case .connections: "Codex 连接"
        case .analytics: "使用统计"
        case .localAccess: "ChatGPT 接入"
        case .networkProxy: "网络代理"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .analytics: "chart.xyaxis.line"
        case .localAccess: "display"
        case .networkProxy: "network"
        case .settings: "gearshape"
        }
    }
}

struct HarborSidebarView: View {
    let selection: HarborMainPage
    let onSelect: (HarborMainPage) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            ScrollView {
                VStack(spacing: 3) {
                    row(.home)
                    row(.connections)
                    row(.analytics)
                    row(.localAccess)
                    row(.networkProxy)
                }
                .padding(.leading, 11)
                .padding(.trailing, 15)
                .padding(.top, 8)
            }
            .scrollIndicators(.automatic)

            Divider().opacity(0.42)

            VStack(spacing: 3) {
                row(.settings)
            }
            .padding(.leading, 11)
            .padding(.trailing, 15)
            .padding(.vertical, 10)
        }
        .frame(minHeight: 0, maxHeight: .infinity, alignment: .top)
        .background {
            ZStack(alignment: .topLeading) {
                (colorScheme == .dark
                    ? Color(red: 0.095, green: 0.11, blue: 0.17)
                    : Color(red: 0.945, green: 0.968, blue: 1.0))
                LinearGradient(
                    colors: colorScheme == .dark
                        ? [
                            HarborColors.blue.opacity(0.14),
                            HarborColors.purple.opacity(0.075),
                            Color.clear
                        ]
                        : [
                            Color.white.opacity(0.50),
                            HarborColors.blue.opacity(0.10),
                            HarborColors.purple.opacity(0.04)
                        ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                Circle()
                    .fill(HarborColors.blue.opacity(colorScheme == .dark ? 0.065 : 0.13))
                    .frame(width: 210, height: 210)
                    .blur(radius: 46)
                    .offset(x: -115, y: -90)
            }
            .ignoresSafeArea()
        }
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            brandIcon

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Harbor")
                    .font(.system(size: 15, weight: .bold, design: .rounded))
                Text("AI 开发控制中心")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .padding(.top, 20)
        .frame(height: 88)
    }

    @ViewBuilder
    private var brandIcon: some View {
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 34, height: 34)
        } else {
            Image(systemName: "shippingbox.fill")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 34, height: 34)
                .background(HarborColors.blue, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        }
    }

    private func row(_ page: HarborMainPage) -> some View {
        let selected = selection == page

        return Button {
            withAnimation(
                reduceMotion
                    ? .linear(duration: 0.01)
                    : .spring(response: 0.30, dampingFraction: 0.88)
            ) {
                onSelect(page)
            }
        } label: {
            HStack(spacing: 11) {
                Image(systemName: page.icon)
                    .font(.system(size: 14, weight: .medium))
                    .frame(width: 22)

                Text(page.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))

                Spacer(minLength: 0)
            }
            .foregroundStyle(selected ? Color.white :
                (colorScheme == .dark
                    ? Color(red: 0.78, green: 0.84, blue: 0.95)
                    : Color(red: 0.20, green: 0.31, blue: 0.45)))
            .padding(.horizontal, 12)
            .frame(height: 46)
            .background(
                LinearGradient(
                    colors: selected
                        ? [Color(red: 0.10, green: 0.51, blue: 0.98), Color(red: 0.10, green: 0.38, blue: 0.93)]
                        : [Color.clear, Color.clear],
                    startPoint: .leading,
                    endPoint: .trailing
                ),
                in: RoundedRectangle(cornerRadius: 11, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 11)
                    .stroke(selected ? Color.white.opacity(0.18) : .clear, lineWidth: 1)
            }
            .shadow(color: selected ? HarborColors.blue.opacity(0.24) : .clear, radius: 10, y: 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 10))
    }
}
