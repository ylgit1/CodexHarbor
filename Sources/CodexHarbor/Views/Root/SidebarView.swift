import SwiftUI
import AppKit

enum HarborMainPage: String, CaseIterable, Identifiable {
    case home
    case connections
    case analytics
    case localAccess
    case settings

    var id: String { rawValue }

    var title: String {
        switch self {
        case .home: "首页"
        case .connections: "连接管理"
        case .analytics: "使用统计"
        case .localAccess: "本地访问"
        case .settings: "设置"
        }
    }

    var icon: String {
        switch self {
        case .home: "house.fill"
        case .connections: "point.3.connected.trianglepath.dotted"
        case .analytics: "chart.xyaxis.line"
        case .localAccess: "display"
        case .settings: "gearshape"
        }
    }
}

struct HarborSidebarView: View {
    let selection: HarborMainPage
    let onSelect: (HarborMainPage) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 0) {
            brandHeader

            ScrollView {
                VStack(spacing: 3) {
                    row(.home)
                    row(.connections)
                    row(.analytics)
                    row(.localAccess)
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
        .background(HarborColors.sidebarBackground.opacity(0.58))
    }

    private var brandHeader: some View {
        HStack(spacing: 9) {
            Image(nsImage: NSApplication.shared.applicationIconImage)
                .resizable()
                .interpolation(.high)
                .antialiased(true)
                .frame(width: 27, height: 27)

            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Harbor")
                    .font(.system(size: 13, weight: .bold, design: .rounded))
                Text("连接更好的 AI")
                    .font(.system(size: 9, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 17)
        .padding(.top, 20)
        .frame(height: 75)
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
            .foregroundStyle(selected ? Color.blue : Color.primary.opacity(0.76))
            .padding(.horizontal, 10)
            .frame(height: 37)
            .background(
                selected ? Color.blue.opacity(0.095) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .overlay(alignment: .leading) {
                if selected {
                    Capsule()
                        .fill(Color.blue)
                        .frame(width: 3, height: 24)
                        .offset(x: -1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 9))
    }
}
