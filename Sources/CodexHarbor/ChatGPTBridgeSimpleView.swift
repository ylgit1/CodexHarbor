import AppKit
import ChatGPTBridgeCore
import SwiftUI

struct ChatGPTBridgeView: View {
    @StateObject private var bridge = ChatGPTBridgeViewModel()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var tunnelID = ""
    @State private var runtimeKey = ""
    @State private var forceSetup = false
    @State private var showDiagnostics = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header

                Group {
                    if showsSetup {
                        setupExperience
                            .transition(.opacity.combined(with: .move(edge: .trailing)))
                    } else {
                        connectedExperience
                            .transition(.opacity.combined(with: .move(edge: .leading)))
                    }
                }
            }
            .padding(.horizontal, 26)
            .padding(.top, 28)
            .padding(.bottom, 24)
            .frame(maxWidth: 980, alignment: .topLeading)
            .frame(maxWidth: .infinity, alignment: .top)
        }
        .background(Color(nsColor: .textBackgroundColor))
        .animation(reduceMotion ? .linear(duration: 0.01) : .easeOut(duration: 0.22), value: showsSetup)
        .task {
            await bridge.reconcileRuntime()
            seedInputs()
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                guard !Task.isCancelled else { break }
                await bridge.refresh()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("ChatGPT 本地访问")
                    .font(.system(size: 22, weight: .semibold, design: .rounded))
                if bridge.overallReady {
                    Text("Harbor 已准备好本地开发环境")
                        .font(.system(size: 12.5, weight: .medium))
                        .foregroundStyle(Color.green)
                }
            }

            Spacer(minLength: 16)

            if !showsSetup {
                connectionBadge
                Button("打开 ChatGPT") { openChatGPT() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.regular)
            }
        }
    }

    private var setupExperience: some View {
        VStack(alignment: .leading, spacing: 22) {
            setupProgress
            setupContent
        }
        .padding(24)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.52), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color.primary.opacity(0.07)))
    }

    private var setupProgress: some View {
        HStack(spacing: 10) {
            setupStep(index: 1, title: "项目", icon: "folder.fill")
            stepLine(done: currentStep > 1)
            setupStep(index: 2, title: "安全连接", icon: "lock.shield.fill")
            stepLine(done: currentStep > 2)
            setupStep(index: 3, title: "ChatGPT", icon: "bubble.left.and.bubble.right.fill")
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var setupContent: some View {
        switch currentStep {
        case 1:
            VStack(alignment: .leading, spacing: 18) {
                Image(systemName: "folder.badge.plus")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.blue)

                Text("选择 ChatGPT 可以访问的项目目录")
                    .font(.system(size: 19, weight: .semibold, design: .rounded))

                Button("选择项目目录") { choosePrimaryDirectory() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
            .frame(maxWidth: .infinity, minHeight: 210, alignment: .center)

        case 2:
            VStack(alignment: .leading, spacing: 18) {
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("连接 OpenAI Secure Tunnel")
                            .font(.system(size: 19, weight: .semibold, design: .rounded))
                        Text(primaryRootName)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.blue)
                    }
                    Spacer(minLength: 12)
                    Button("更换目录") { choosePrimaryDirectory() }
                        .buttonStyle(.plain)
                        .foregroundStyle(.blue)
                }

                HStack(spacing: 10) {
                    Button {
                        openTunnelManagement()
                    } label: {
                        Label("新建 Tunnel ID", systemImage: "point.3.connected.trianglepath.dotted")
                    }
                    .buttonStyle(.bordered)

                    Button {
                        openRuntimeKeyManagement()
                    } label: {
                        Label("新建 Runtime API Key", systemImage: "key.fill")
                    }
                    .buttonStyle(.bordered)
                }

                VStack(spacing: 10) {
                    TextField("Tunnel ID", text: $tunnelID)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))

                    SecureField(bridge.hasTunnelRuntimeKey ? "Runtime API Key 已保存，留空即可" : "Runtime API Key", text: $runtimeKey)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 13))
                }
                .frame(maxWidth: 560)

                HStack(spacing: 12) {
                    Button {
                        Task {
                            await bridge.prepareInitialConnection(tunnelID: tunnelID, runtimeAPIKey: runtimeKey)
                            runtimeKey = ""
                        }
                    } label: {
                        if bridge.isWorking {
                            HStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                Text("正在准备…")
                            }
                        } else {
                            Text("自动准备并连接")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(bridge.isWorking || tunnelID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)

                    if let message = compactStatusMessage {
                        Text(message)
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(messageColor)
                    }
                }
            }
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)

        default:
            VStack(spacing: 18) {
                Image(systemName: bridge.runtime.tunnel == .connected ? "checkmark.circle.fill" : "arrow.triangle.2.circlepath.circle.fill")
                    .font(.system(size: 42, weight: .medium))
                    .foregroundStyle(bridge.runtime.tunnel == .connected ? Color.green : Color.blue)

                Text(bridge.runtime.tunnel == .connected ? "本地通道已就绪" : "正在建立安全通道")
                    .font(.system(size: 20, weight: .semibold, design: .rounded))

                if bridge.runtime.tunnel == .connected {
                    HStack(spacing: 10) {
                        Button("打开 ChatGPT 连接设置") { openChatGPTConnectorSettings() }
                            .buttonStyle(.borderedProminent)
                            .controlSize(.large)
                        Button("打开 ChatGPT") { openChatGPT() }
                            .buttonStyle(.bordered)
                            .controlSize(.large)
                    }
                } else {
                    ProgressView()
                        .controlSize(.regular)
                    Button("重新检查") {
                        Task { await bridge.refresh() }
                    }
                    .buttonStyle(.bordered)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 220, alignment: .center)
        }
    }

    private var connectedExperience: some View {
        VStack(alignment: .leading, spacing: 18) {
            connectionHero
            projectBar

            if !bridge.recentAuditEntries.isEmpty {
                recentActivity
            } else {
                firstUsePrompt
            }

            if showDiagnostics {
                diagnosticsPanel
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var connectionHero: some View {
        HStack(spacing: 18) {
            ZStack {
                Circle()
                    .fill(connectionColor.opacity(0.10))
                    .frame(width: 54, height: 54)
                Image(systemName: connectionIcon)
                    .font(.system(size: 23, weight: .semibold))
                    .foregroundStyle(connectionColor)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(connectionTitle)
                    .font(.system(size: 20, weight: .semibold, design: .rounded))
                Text(connectionDetail)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(connectionColor)
            }

            Spacer(minLength: 16)

            if !bridge.overallReady {
                Button("重新连接") {
                    Task { await bridge.setEnabled(true) }
                }
                .buttonStyle(.borderedProminent)
            }

            Menu {
                Button("重新配置连接") {
                    seedInputs()
                    withAnimation { forceSetup = true }
                }
                Button("更换项目目录") { choosePrimaryDirectory() }
                Button("检查连接") {
                    showDiagnostics = true
                    Task { await bridge.runDiagnostics() }
                }
                Divider()
                Button("停止本地访问", role: .destructive) {
                    Task { await bridge.setEnabled(false) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 17, weight: .semibold))
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(20)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.48), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(connectionColor.opacity(0.12)))
    }

    private var projectBar: some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .foregroundStyle(.blue)

            Text(primaryRootName)
                .font(.system(size: 13, weight: .semibold))

            Text(primaryRootPath)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 12)

            HStack(spacing: 6) {
                statusDot(active: bridge.agentRunning)
                Text("Agent")
                statusDot(active: bridge.mcpHealthy)
                Text("MCP")
                statusDot(active: bridge.runtime.tunnel == .connected)
                Text("Tunnel")
            }
            .font(.system(size: 11, weight: .semibold))

            Button("更换") { choosePrimaryDirectory() }
                .buttonStyle(.plain)
                .foregroundStyle(.blue)
        }
        .padding(.horizontal, 16)
        .frame(minHeight: 48)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.34), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    private var firstUsePrompt: some View {
        HStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(.blue)

            Text("在 ChatGPT 中选择 Codex Harbor Tunnel 后，就可以直接操作本地项目。")
                .font(.system(size: 13, weight: .semibold))

            Spacer(minLength: 12)

            Button("完成 ChatGPT 连接") { openChatGPTConnectorSettings() }
                .buttonStyle(.borderedProminent)
        }
        .padding(16)
        .background(Color.blue.opacity(0.055), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var recentActivity: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("最近活动")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                if chatGPTRecentlyActive {
                    HStack(spacing: 6) {
                        Circle().fill(Color.green).frame(width: 6, height: 6)
                        Text("ChatGPT 正在使用")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.green)
                    }
                }
            }
            .padding(.bottom, 10)

            ForEach(Array(bridge.recentAuditEntries.prefix(6).enumerated()), id: \.element.id) { index, entry in
                HStack(spacing: 10) {
                    Image(systemName: entry.status == .success ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(entry.status == .success ? Color.green : Color.red)
                        .font(.system(size: 12))

                    Text(entry.tool)
                        .font(.system(size: 12, weight: .semibold))
                        .frame(width: 72, alignment: .leading)

                    Text(entry.target ?? entry.summary)
                        .font(.system(size: 12))
                        .lineLimit(1)
                        .truncationMode(.middle)

                    Spacer(minLength: 8)

                    Text(entry.timestamp.formatted(date: .omitted, time: .shortened))
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .frame(minHeight: 34)

                if index < min(bridge.recentAuditEntries.count, 6) - 1 {
                    Divider().opacity(0.45)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.36), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var diagnosticsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("连接检查")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("关闭") {
                    withAnimation { showDiagnostics = false }
                }
                .buttonStyle(.plain)
            }

            if bridge.isDiagnosing {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在检查…")
                        .font(.system(size: 12, weight: .medium))
                }
            } else {
                ForEach(bridge.diagnosticResults) { result in
                    HStack(spacing: 10) {
                        Image(systemName: diagnosticIcon(result.status))
                            .foregroundStyle(diagnosticColor(result.status))
                            .frame(width: 18)
                        Text(result.title)
                            .font(.system(size: 12, weight: .semibold))
                        Spacer()
                        Text(result.status == .passed ? "正常" : result.status == .warning ? "注意" : "异常")
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(diagnosticColor(result.status))
                    }
                    .frame(minHeight: 30)
                }
            }
        }
        .padding(16)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.40), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var connectionBadge: some View {
        HStack(spacing: 7) {
            Circle()
                .fill(connectionColor)
                .frame(width: 7, height: 7)
            Text(connectionTitle)
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(connectionColor)
        }
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(connectionColor.opacity(0.08), in: Capsule())
    }

    private func setupStep(index: Int, title: String, icon: String) -> some View {
        let active = currentStep == index
        let done = currentStep > index
        let color: Color = done ? .green : (active ? .blue : .secondary)

        return HStack(spacing: 7) {
            ZStack {
                Circle()
                    .fill(color.opacity(active || done ? 0.12 : 0.06))
                    .frame(width: 30, height: 30)
                Image(systemName: done ? "checkmark" : icon)
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(color)
            }
            Text(title)
                .font(.system(size: 12, weight: active ? .semibold : .medium))
                .foregroundStyle(active || done ? Color.primary : Color.secondary)
        }
    }

    private func stepLine(done: Bool) -> some View {
        Capsule()
            .fill(done ? Color.green.opacity(0.5) : Color.primary.opacity(0.09))
            .frame(maxWidth: 82, minHeight: 2, maxHeight: 2)
    }

    private func statusDot(active: Bool) -> some View {
        Circle()
            .fill(active ? Color.green : Color.orange)
            .frame(width: 6, height: 6)
    }

    private var currentStep: Int {
        if bridge.configuration.allowedRoots.isEmpty { return 1 }
        if bridge.configuration.secureTunnel == nil || !bridge.hasTunnelRuntimeKey { return 2 }
        return 3
    }

    private var showsSetup: Bool {
        forceSetup
            || bridge.configuration.allowedRoots.isEmpty
            || bridge.configuration.secureTunnel == nil
            || !bridge.hasTunnelRuntimeKey
            || !bridge.localReady
    }

    private var primaryRootPath: String {
        bridge.configuration.allowedRoots.first ?? "未选择"
    }

    private var primaryRootName: String {
        guard let root = bridge.configuration.allowedRoots.first else { return "本地项目" }
        return URL(fileURLWithPath: root).lastPathComponent
    }

    private var chatGPTRecentlyActive: Bool {
        guard let latest = bridge.recentAuditEntries.first?.timestamp else { return false }
        return Date().timeIntervalSince(latest) < 60
    }

    private var connectionTitle: String {
        if chatGPTRecentlyActive { return "正在使用" }
        if bridge.overallReady { return "已连接" }
        if bridge.agentRunning { return "正在恢复" }
        return "未连接"
    }

    private var connectionDetail: String {
        if chatGPTRecentlyActive { return "ChatGPT 正在调用本地工具" }
        if bridge.overallReady { return "安全通道运行正常" }
        if bridge.agentRunning { return "本地服务已启动，正在恢复安全通道" }
        return "点击重新连接即可恢复"
    }

    private var connectionColor: Color {
        if chatGPTRecentlyActive || bridge.overallReady { return .green }
        if bridge.agentRunning { return .orange }
        return .red
    }

    private var connectionIcon: String {
        if chatGPTRecentlyActive { return "bolt.fill" }
        if bridge.overallReady { return "checkmark" }
        if bridge.agentRunning { return "arrow.triangle.2.circlepath" }
        return "exclamationmark"
    }

    private var compactStatusMessage: String? {
        guard let message = bridge.statusMessage, !message.isEmpty else { return nil }
        if message.contains("失败") || message.contains("无效") || message.contains("缺少") || message.contains("未找到") {
            return message
        }
        return nil
    }

    private var messageColor: Color {
        .red
    }

    private func seedInputs() {
        tunnelID = bridge.configuration.secureTunnel?.tunnelID ?? ""
    }

    private func choosePrimaryDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "选择"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            await bridge.setPrimaryAllowedRoot(url)
            withAnimation { forceSetup = false }
        }
    }

    private func openChatGPT() {
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.chat") {
            NSWorkspace.shared.openApplication(at: appURL, configuration: NSWorkspace.OpenConfiguration())
        } else if let url = URL(string: "https://chatgpt.com/") {
            NSWorkspace.shared.open(url)
        }
    }

    private func openChatGPTConnectorSettings() {
        guard let url = URL(string: "https://chatgpt.com/#settings/Connectors") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openTunnelManagement() {
        guard let url = URL(string: "https://platform.openai.com/settings/organization/tunnels") else { return }
        NSWorkspace.shared.open(url)
    }

    private func openRuntimeKeyManagement() {
        guard let url = URL(string: "https://platform.openai.com/settings/organization/api-keys") else { return }
        NSWorkspace.shared.open(url)
    }

    private func diagnosticIcon(_ status: BridgeDiagnosticStatus) -> String {
        switch status {
        case .passed: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .failed: return "xmark.circle.fill"
        }
    }

    private func diagnosticColor(_ status: BridgeDiagnosticStatus) -> Color {
        switch status {
        case .passed: return .green
        case .warning: return .orange
        case .failed: return .red
        }
    }
}
