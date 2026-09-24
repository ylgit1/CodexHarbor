import SwiftUI
import AppKit
import ChatGPTBridgeCore

struct HarborLocalTransportConfigurationSheet: View {
    @ObservedObject var bridge: ChatGPTBridgeViewModel

    let mode: BridgeTransportMode
    @Binding var tunnelID: String
    @Binding var runtimeKey: String
    @Binding var hostnameSuffix: String
    @Binding var localPort: String

    let onClose: () -> Void

    @State private var cloudflareAPIToken = ""
    @State private var showingCloudflareZones = false

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            statusRow

            if active,
               let transportMessage = bridge.runtime.transportMessage,
               !transportMessage.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: transportMessage.contains("429") ? "exclamationmark.triangle.fill" : "info.circle.fill")
                        .foregroundStyle(transportMessage.contains("429") ? HarborColors.orange : HarborColors.blue)
                    Text(transportMessage)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(
                    (transportMessage.contains("429") ? HarborColors.orange : HarborColors.blue).opacity(0.055),
                    in: RoundedRectangle(cornerRadius: 9)
                )
            }

            if mode == .secureTunnel,
               let message = bridge.tunnelMigrationMessage,
               !message.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(HarborColors.orange)
                    Text(message)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(HarborColors.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 9))
            }

            if let message = bridge.statusMessage, !message.isEmpty {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: message.contains("完成") || message.contains("已保存") || message.contains("已启动")
                        ? "checkmark.circle.fill"
                        : "info.circle.fill")
                        .foregroundStyle(message.contains("完成") || message.contains("已保存") || message.contains("已启动")
                            ? HarborColors.green
                            : HarborColors.blue)
                    Text(message)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 9))
            }

            if mode == .secureTunnel {
                secureTunnelForm
            } else {
                httpsForm
            }

            Divider()
                .opacity(0.35)
                .padding(.top, 2)

            footer
        }
        .padding(20)
        .frame(width: 600)
        .task {
            // The AppShell runtime monitor owns periodic refreshes.
            // Configuration actions refresh explicitly after mutations.
            await bridge.refresh()
        }
        .onExitCommand(perform: onClose)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 12) {
            Text(mode == .secureTunnel ? "OpenAI 本地管道" : "公网 HTTPS")
                .font(.system(size: 20, weight: .bold, design: .rounded))
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .background(Color.primary.opacity(0.045), in: Circle())
            }
            .buttonStyle(HarborInteractivePlainButtonStyle(tint: Color.primary, cornerRadius: 9))
            .keyboardShortcut(.cancelAction)
        }
    }

    private var statusRow: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 7, height: 7)
            Text(statusTitle)
                .font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(statusColor)
            Spacer()
        }
    }

    private var secureTunnelForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            labeledField("Tunnel ID") {
                HStack(spacing: 8) {
                    textField("tunnel_…", text: $tunnelID)

                    Button("去复制") {
                        guard let url = URL(string: "https://platform.openai.com/settings/organization/tunnels") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .help("打开 OpenAI Tunnel 管理页面")
                }
            }

            labeledField("Runtime Key") {
                HStack(spacing: 8) {
                    SecureField(
                        bridge.hasTunnelRuntimeKey ? "已保存，留空保持不变" : "输入 Runtime Key",
                        text: $runtimeKey
                    )
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))

                    Button("去复制") {
                        guard let url = URL(string: "https://platform.openai.com/settings/organization/api-keys") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .help("打开 OpenAI API Key 管理页面")
                }
            }
        }
    }

    private var httpsForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Cloudflare")
                    .font(.callout.weight(.semibold))
                HarborStatusBadge(
                    title: bridge.cloudflareAuthorized ? "已授权" : "未授权",
                    color: bridge.cloudflareAuthorized ? HarborColors.green : .secondary
                )
                Spacer()
                Button(bridge.cloudflareAuthorized ? "重新授权" : "开始授权") {
                    Task {
                        let path = bridge.configuration.httpsCompatibility?.cloudflaredPath
                            ?? ""
                        await bridge.loginToCloudflare(cloudflaredPath: path)
                    }
                }
                .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))
                .disabled(bridge.isCloudflareAuthorizing || bridge.isWorking)
            }
            .padding(.horizontal, 12)
            .frame(height: 42)
            .background(Color.primary.opacity(0.025), in: RoundedRectangle(cornerRadius: 10))

            labeledField("Cloudflare Zone API Token") {
                HStack(spacing: 8) {
                    SecureField(
                        bridge.hasCloudflareZoneAPIToken ? "已安全保存，留空继续使用" : "仅需 Zone:Read 权限",
                        text: $cloudflareAPIToken
                    )
                    .textFieldStyle(.plain)
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))

                    Button("去创建") {
                        guard let url = URL(string: "https://dash.cloudflare.com/profile/api-tokens") else { return }
                        NSWorkspace.shared.open(url)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .help("创建仅包含 Zone:Read 权限的 Cloudflare API Token")
                }
            }

            labeledField("根域名") {
                HStack(spacing: 8) {
                    textField("例如 example.com", text: $hostnameSuffix)

                    Button(bridge.isFetchingCloudflareZones ? "获取中" : "从 Cloudflare 获取") {
                        Task {
                            await bridge.fetchCloudflareZones(apiToken: cloudflareAPIToken)
                            if !bridge.cloudflareZones.isEmpty {
                                showingCloudflareZones = true
                            }
                        }
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(bridge.isFetchingCloudflareZones)
                    .popover(isPresented: $showingCloudflareZones, arrowEdge: .top) {
                        VStack(alignment: .leading, spacing: 10) {
                            Text("选择根域名")
                                .font(.system(size: 14, weight: .semibold))

                            Text("来自当前 Cloudflare API Token 可访问的 Zone")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)

                            Divider().opacity(0.35)

                            ScrollView {
                                VStack(spacing: 6) {
                                    ForEach(bridge.cloudflareZones, id: \.self) { domain in
                                        Button {
                                            hostnameSuffix = domain
                                            showingCloudflareZones = false
                                        } label: {
                                            HStack {
                                                Image(systemName: "globe")
                                                    .foregroundStyle(HarborColors.blue)
                                                Text(domain)
                                                    .font(.system(size: 11.5, weight: .medium))
                                                Spacer()
                                                if hostnameSuffix == domain {
                                                    Image(systemName: "checkmark")
                                                        .foregroundStyle(HarborColors.green)
                                                }
                                            }
                                            .padding(.horizontal, 10)
                                            .frame(height: 38)
                                            .contentShape(Rectangle())
                                        }
                                        .buttonStyle(HarborInteractivePlainButtonStyle(tint: HarborColors.blue, cornerRadius: 8))
                                    }
                                }
                            }
                            .frame(maxHeight: 240)
                        }
                        .padding(14)
                        .frame(width: 320)
                        .background(HarborColors.cardBackground)
                    }
                }
            }

            labeledField("本地端口") {
                textField("19473", text: $localPort)
            }

        }
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Spacer()

            Button("取消", action: onClose)
                .keyboardShortcut(.cancelAction)
                .buttonStyle(HarborActionButtonStyle(tint: .secondary, prominence: .secondary))

            Button("保存配置") {
                save()
            }
            .keyboardShortcut(.defaultAction)
            .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .prominent))
            .disabled(bridge.isWorking || !inputValid)
        }
    }

    private func labeledField<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.callout.weight(.semibold))
            content()
        }
    }

    private func textField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .textFieldStyle(.plain)
            .font(.system(.body, design: .monospaced))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color.primary.opacity(0.12)))
    }

    private var configured: Bool {
        switch mode {
        case .secureTunnel:
            return bridge.configuration.secureTunnel != nil && bridge.hasTunnelRuntimeKey
        case .httpsCompatibility:
            return bridge.configuration.httpsCompatibility != nil && bridge.hasPublicHTTPSAccessToken
        }
    }

    private var active: Bool {
        (bridge.agentRunning || bridge.runtime.agent == .starting)
            && bridge.configuration.transportMode == mode
    }

    private var statusTitle: String {
        if active && bridge.overallReady { return "使用中" }
        if active { return "连接中" }
        return configured ? "待使用" : "未配置"
    }

    private var statusColor: Color {
        if active && bridge.overallReady { return HarborColors.green }
        if active { return HarborColors.blue }
        return configured ? HarborColors.orange : .secondary
    }

    private var inputValid: Bool {
        switch mode {
        case .secureTunnel:
            let id = tunnelID.trimmingCharacters(in: .whitespacesAndNewlines)
            let keyReady = bridge.hasTunnelRuntimeKey
                || !runtimeKey.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            return id.hasPrefix("tunnel_") && keyReady

        case .httpsCompatibility:
            let suffix = hostnameSuffix.trimmingCharacters(in: .whitespacesAndNewlines)
            return suffix.contains(".")
                && UInt16(localPort) != nil
        }
    }

    private func save() {
        Task {
            switch mode {
            case .secureTunnel:
                let submittedRuntimeKey = runtimeKey.trimmingCharacters(in: .whitespacesAndNewlines)
                await bridge.saveSecureTunnelConfiguration(
                    tunnelID: tunnelID,
                    runtimeAPIKey: submittedRuntimeKey,
                    executablePath: bridge.configuration.secureTunnel?.executablePath ?? "",
                    controlPlaneBaseURL: bridge.configuration.secureTunnel?.controlPlaneBaseURL ?? "https://api.openai.com"
                )
                if !submittedRuntimeKey.isEmpty && bridge.hasTunnelRuntimeKey {
                    runtimeKey = ""
                }

            case .httpsCompatibility:
                guard let port = UInt16(localPort) else { return }
                await bridge.savePublicHTTPSConfiguration(
                    cloudflaredPath: bridge.configuration.httpsCompatibility?.cloudflaredPath
                        ?? "",
                    hostnameSuffix: hostnameSuffix,
                    localPort: port
                )
            }

            await bridge.refresh()
        }
    }
}
