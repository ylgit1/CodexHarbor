import SwiftUI
import CodexHarborCore

struct HarborConnectionManagementView: View {
    @ObservedObject var model: AppModel
    @Binding var filter: ConnectionCatalogFilter

    let effectiveConnectionKind: CodexConnectionKind?
    let onCreate: () -> Void
    let onOpenAccount: (CodexAccountProfile) -> Void
    let onOpenProfile: (HarborProfile) -> Void
    let onRenameAccount: (CodexAccountProfile) -> Void
    let onRenameProfile: (HarborProfile) -> Void
    let onDeleteAccount: (CodexAccountProfile) -> Void
    let onDeleteProfile: (HarborProfile) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var collapsedSections: Set<ConnectionCatalogFilter> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Text("连接管理")
                        .font(.system(size: 22, weight: .bold, design: .rounded))
                    Spacer()

                    Button {
                        Task { await model.refreshConnectionHealth() }
                    } label: {
                        if model.isCheckingConnectionHealth {
                            Label("测试中", systemImage: "arrow.triangle.2.circlepath")
                        } else {
                            Label("测试连接", systemImage: "checkmark.shield")
                        }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(model.isBusy || model.isCheckingConnectionHealth)

                    Button(action: onCreate) {
                        Label("新建连接", systemImage: "plus")
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                }

                HarborSegmentControl(
                    options: ConnectionCatalogFilter.allCases.map { ($0, $0.rawValue) },
                    selection: $filter
                )
                .frame(width: 360)

                catalog
            }
            .frame(maxWidth: 1220, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
            .padding(.horizontal, 26)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
        .scrollIndicators(.automatic)
    }

    private var catalog: some View {
        VStack(spacing: 0) {
            if isEmpty && filter != .all {
                VStack(spacing: 9) {
                    Image(systemName: "point.3.connected.trianglepath.dotted")
                        .font(.system(size: 24))
                        .foregroundStyle(HarborColors.blue)
                    Text("暂无\(filter.rawValue)连接")
                        .font(.callout.weight(.semibold))
                    Text("可使用右上角“新建连接”添加")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 154)
            }

            accountSection
            hostedSection
            apiSection
        }
        .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: HarborRadius.card))
        .overlay(RoundedRectangle(cornerRadius: HarborRadius.card).stroke(HarborColors.cardBorder))
    }

    private var isEmpty: Bool {
        let hasAccounts = (filter == .all || filter == .account) && !model.accountProfiles.isEmpty
        let hasHosted = (filter == .all || filter == .hosted) && model.profiles.contains { $0.kind == .harbor }
        let hasAPI = (filter == .all || filter == .api) && model.profiles.contains { $0.kind == .customResponses }
        return !(hasAccounts || hasHosted || hasAPI)
    }

    @ViewBuilder
    private var accountSection: some View {
        if filter == .all || filter == .account {
            let accounts = model.accountProfiles
            if !accounts.isEmpty {
                sectionHeader("账户", count: accounts.count, section: .account)
                if !collapsedSections.contains(.account) {
                    ForEach(accounts) { profile in
                        HarborConnectionCatalogRow(
                            model: model,
                            id: profile.id,
                            name: profile.name,
                            type: profile.method.title,
                            icon: "person.crop.circle.fill",
                            providerIdentity: nil,
                            health: model.accountProfileHealth[profile.id] ?? .unchecked,
                            active: effectiveConnectionKind == .account && model.selectedAccountProfileID == profile.id,
                            show: { onOpenAccount(profile) },
                            activate: { Task { await model.switchAccount(to: profile.id) } },
                            rename: { onRenameAccount(profile) },
                            delete: { onDeleteAccount(profile) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var hostedSection: some View {
        let profiles = model.profiles.filter { $0.kind == .harbor }
        if (filter == .all || filter == .hosted), !profiles.isEmpty {
            sectionHeader("托管密钥", count: profiles.count, section: .hosted)
            if !collapsedSections.contains(.hosted) {
                ForEach(profiles) { profile in
                    HarborConnectionCatalogRow(
                        model: model,
                        id: profile.id,
                        name: profile.name,
                        type: "托管密钥",
                        icon: "key.fill",
                        providerIdentity: nil,
                        health: model.apiProfileHealth[profile.id] ?? .unchecked,
                        active: effectiveConnectionKind == .harborKey && model.activeProfileID == profile.id,
                        show: { onOpenProfile(profile) },
                        activate: { Task { await model.switchProfile(to: profile.id) } },
                        rename: { onRenameProfile(profile) },
                        delete: { onDeleteProfile(profile) }
                    )
                }
            }
        }
    }

    @ViewBuilder
    private var apiSection: some View {
        let profiles = model.profiles.filter { $0.kind == .customResponses }
        if (filter == .all || filter == .api), !profiles.isEmpty {
            sectionHeader("自定义 API", count: profiles.count, section: .api)
            if !collapsedSections.contains(.api) {
                ForEach(profiles) { profile in
                    HarborConnectionCatalogRow(
                        model: model,
                        id: profile.id,
                        name: profile.name,
                        type: "\(profile.provider.title) · 自定义 API",
                        icon: "globe",
                        providerIdentity: ProviderCatalog.identity(for: profile.apiBaseURL),
                        health: model.apiProfileHealth[profile.id] ?? .unchecked,
                        active: effectiveConnectionKind == .apiKey && model.activeProfileID == profile.id,
                        show: { onOpenProfile(profile) },
                        activate: { Task { await model.switchProfile(to: profile.id) } },
                        rename: { onRenameProfile(profile) },
                        delete: { onDeleteProfile(profile) }
                    )
                }
            }
        }
    }

    private func sectionHeader(
        _ title: String,
        count: Int,
        section: ConnectionCatalogFilter
    ) -> some View {
        let collapsed = collapsedSections.contains(section)

        return Button {
            withAnimation(reduceMotion ? .linear(duration: 0.01) : .easeInOut(duration: 0.18)) {
                if collapsed {
                    collapsedSections.remove(section)
                } else {
                    collapsedSections.insert(section)
                }
            }
        } label: {
            HStack(spacing: 7) {
                Text(title)
                    .font(.system(size: 11.5, weight: .semibold))
                Text("(\(count))")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Spacer()
                Text(collapsed ? "展开" : "收起")
                    .font(.system(size: 9.5, weight: .medium))
                    .foregroundStyle(.secondary)
                Image(systemName: collapsed ? "chevron.down" : "chevron.up")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)
            .frame(height: 36)
            .background(Color.primary.opacity(0.018))
            .contentShape(Rectangle())
        }
        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
    }
}
