import SwiftUI
import CodexHarborCore

enum ConnectionCatalogFilter: String, CaseIterable, Identifiable {
    case all = "全部"
    case account = "账户"
    case hosted = "托管密钥"
    case api = "自定义 API"

    var id: String { rawValue }
}


struct HarborConnectionCatalogRow: View {
    @ObservedObject var model: AppModel

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    let id: UUID
    let name: String
    let type: String
    let icon: String
    let providerIdentity: ProviderIdentity?
    let health: ConnectionHealth
    let active: Bool
    let show: () -> Void
    let activate: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Button(action: show) {
                HStack(spacing: 12) {
                    Group {
                        if let providerIdentity {
                            ProviderIconView(identity: providerIdentity, size: 39)
                        } else {
                            Image(systemName: icon)
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(HarborColors.blue)
                                .frame(width: 39, height: 39)
                                .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 11))
                        }
                    }

                    VStack(alignment: .leading, spacing: 3) {
                        Text(name)
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        Text(type)
                            .font(.system(size: 10.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer(minLength: 2)

                    HarborStatusBadge(
                        title: active ? "当前使用" : healthTitle(health),
                        color: active ? HarborColors.green : healthColor(health)
                    )
                }
                .padding(.leading, 16)
                .frame(height: 69)
                .contentShape(Rectangle())
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 10))
            .frame(maxWidth: .infinity)

            if !active {
                Button("切换", action: activate)
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))
                    .disabled(model.isBusy)
            }

            HStack(spacing: 5) {
                Button("重命名", action: rename)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))

                Button("删除", role: .destructive, action: delete)
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                    .disabled(active)
            }
        }
        .padding(.trailing, 14)
        .background(
            active
                ? HarborColors.blue.opacity(0.05)
                : (hovering ? HarborColors.blue.opacity(0.028) : Color.clear)
        )
        .overlay(alignment: .leading) {
            if active {
                Capsule()
                    .fill(HarborColors.blue)
                    .frame(width: 3, height: 34)
                    .padding(.leading, 2)
            }
        }
        .overlay(alignment: .bottom) {
            Divider().padding(.leading, 68)
        }
        .offset(y: hovering && !active && !reduceMotion ? -0.5 : 0)
        .animation(
            reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.16),
            value: hovering
        )
        .onHover { hovering = $0 }
        .accessibilityIdentifier("connection-\(id.uuidString)")
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
        case .available: HarborColors.green
        case .expired: HarborColors.orange
        case .unavailable: HarborColors.red
        case .checking: HarborColors.blue
        case .unchecked: .secondary
        }
    }

}
