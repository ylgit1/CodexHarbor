import SwiftUI
import CodexHarborCore

struct HarborConnectionDetailHeader: View {
    let name: String
    let kind: String
    let icon: String
    let providerIdentity: ProviderIdentity?
    let status: String
    let active: Bool
    let modelName: String
    let latency: Int?
    let lastChecked: Date?
    let isBusy: Bool
    let isCheckingHealth: Bool
    let canDelete: Bool
    let activate: () -> Void
    let test: () -> Void
    let rename: () -> Void
    let delete: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            Group {
                if let providerIdentity {
                    ProviderIconView(identity: providerIdentity, size: 50)
                } else {
                    Image(systemName: icon)
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(HarborColors.blue)
                        .frame(width: 50, height: 50)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 14))
                }
            }

            VStack(alignment: .leading, spacing: 7) {
                HStack(spacing: 8) {
                    Text(name)
                        .font(.system(size: 19, weight: .bold, design: .rounded))
                        .lineLimit(1)

                    HarborStatusBadge(
                        title: active ? "当前使用" : status,
                        color: active ? HarborColors.green : .secondary
                    )
                }

                HStack(spacing: 14) {
                    Text(kind)
                    Label(modelName.isEmpty ? "—" : modelName, systemImage: "cube")
                    Label(latency.map { "\($0) ms" } ?? "—", systemImage: "bolt.fill")
                    Label(
                        lastChecked?.formatted(date: .omitted, time: .shortened) ?? "—",
                        systemImage: "clock"
                    )
                }
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            if !active {
                Button("切换连接", action: activate)
                    .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
                    .disabled(isBusy)
            }

            ViewThatFits(in: .horizontal) {
                HStack(spacing: 5) {
                    Button("测试", action: test)
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                        .disabled(isBusy || isCheckingHealth)

                    Button("重命名", action: rename)
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))

                    Button("删除", role: .destructive, action: delete)
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                        .disabled(!canDelete)
                }

                HStack(spacing: 2) {
                    Button(action: test) {
                        Image(systemName: "checkmark.shield")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
                    .foregroundStyle(HarborColors.blue)
                    .help("测试连接")
                    .disabled(isBusy || isCheckingHealth)

                    Button(action: rename) {
                        Image(systemName: "pencil")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
                    .foregroundStyle(HarborColors.blue)
                    .help("重命名")

                    Button(role: .destructive, action: delete) {
                        Image(systemName: "trash")
                            .frame(width: 28, height: 28)
                    }
                    .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
                    .foregroundStyle(canDelete ? HarborColors.red : Color.secondary.opacity(0.35))
                    .help(canDelete ? "删除连接" : "请先切换到其他连接")
                    .disabled(!canDelete)
                }
            }
        }
        .padding(.vertical, 4)
    }
}

struct HarborConnectionInfoGrid: View {
    let fields: [(String, String)]

    var body: some View {
        HarborCard(padding: 14) {
            LazyVGrid(
                columns: [
                    GridItem(.flexible(minimum: 220), spacing: 10),
                    GridItem(.flexible(minimum: 220), spacing: 10)
                ],
                alignment: .leading,
                spacing: 10
            ) {
                ForEach(fields.indices, id: \.self) { index in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(fields[index].0)
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(fields[index].1)
                            .font(.system(size: 11.5, weight: .medium))
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 11)
                    .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                    .background(Color.primary.opacity(0.022), in: RoundedRectangle(cornerRadius: 10))
                }
            }
        }
    }
}
