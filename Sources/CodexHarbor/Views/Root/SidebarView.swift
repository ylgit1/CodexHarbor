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

    private static let appIcon: NSImage? = {
        guard let url = Bundle.main.url(forResource: "AppIcon", withExtension: "icns") else { return nil }
        return NSImage(contentsOf: url)
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 11) {
                if let icon = Self.appIcon {
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 32, height: 32)
                } else {
                    Image(systemName: "shippingbox.fill")
                        .foregroundStyle(HarborColors.blue)
                        .frame(width: 32, height: 32)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Codex Harbor")
                        .font(.system(size: 14, weight: .semibold))
                    Text("开发控制中心")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 18)
            .frame(height: 86)

            Text("工作空间")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 20)
                .padding(.bottom, 10)

            VStack(spacing: 4) {
                row(.home)
                row(.connections)
                row(.analytics)
                row(.localAccess)
                row(.networkProxy)
            }
            .padding(.horizontal, 10)

            Spacer(minLength: 12)
            Divider()
                .opacity(0.45)
                .padding(.horizontal, 16)
            row(.settings)
                .padding(.horizontal, 10)
                .padding(.vertical, 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(HarborColors.sidebarBackground)
    }

    private func row(_ page: HarborMainPage) -> some View {
        let selected = selection == page
        return Button {
            // Navigation changes immediately; no spring or cross-page animation.
            onSelect(page)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: page.icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(selected ? HarborColors.blue : Color.secondary)
                Text(page.title)
                    .font(.system(size: 12, weight: selected ? .semibold : .medium))
                    .foregroundStyle(.primary)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 13)
            .frame(height: 40)
            .background(
                selected ? HarborColors.blue.opacity(0.09) : Color.clear,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay(alignment: .leading) {
                if selected {
                    RoundedRectangle(cornerRadius: 2)
                        .fill(HarborColors.blue)
                        .frame(width: 3, height: 21)
                        .padding(.leading, 2)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
