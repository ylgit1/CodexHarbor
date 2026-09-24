import SwiftUI
import AppKit
import ChatGPTBridgeCore

struct HarborLocalAccessView: View {
    @ObservedObject var bridge: ChatGPTBridgeViewModel
    let onConfigure: (BridgeTransportMode) -> Void
    let onAddRoot: () -> Void
    let onRemoveRoot: (String) -> Void

    @State private var selectedMode: BridgeTransportMode = .secureTunnel
    @State private var deletionTarget: BridgeTransportMode?
    @State private var copiedHTTPSAddress = false
    @State private var lastManualCheckAt: Date?
    @State private var expandedDiagnosticID: String?
    @State private var operation: ConnectionOperationContext?
    @State private var testFeedback: ConnectionTestFeedback?
    @State private var showCloseConfirmation = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    headerSection
                    connectionPathCard
                    allowedRootsSection
                    transportSection

                    if !bridge.pendingApprovalRequests.isEmpty {
                        approvalCard
                    }
                }
                .frame(maxWidth: 1220)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 26)
                .padding(.top, 24)
                .padding(.bottom, 24)
            }
            .scrollIndicators(.automatic)

            if let operation {
                // 操作进行时只压暗主页面；弹窗作为独立前景层保持亮色，避免整页一起发灰。
                Color.black.opacity(0.20)
                    .ignoresSafeArea()
                    .transition(.opacity)
                    .zIndex(1)

                ConnectionOperationModal(
                    operation: operation,
                    onDismissFailure: {
                        withAnimation(.easeOut(duration: 0.16)) {
                            self.operation = nil
                        }
                    }
                )
                .zIndex(2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if let testFeedback {
                ConnectionTestToast(feedback: testFeedback)
                    .padding(.top, 78)
                    .padding(.trailing, 28)
                    .transition(.opacity.combined(with: .move(edge: .top)))
                    .zIndex(3)
            }
        }
        .animation(.easeOut(duration: 0.22), value: operation != nil)
        .animation(.easeOut(duration: 0.18), value: testFeedback)
        .onAppear {
            selectedMode = bridge.configuration.transportMode
        }
        .sheet(
            isPresented: Binding(
                get: { deletionTarget != nil },
                set: { if !$0 { deletionTarget = nil } }
            )
        ) {
            if let mode = deletionTarget {
                HarborDestructiveConfirmDialog(
                    title: "删除\(mode == .secureTunnel ? "OpenAI 本地管道" : "公网 HTTPS")配置？",
                    message: deletionMessage(for: mode),
                    confirmTitle: "删除配置",
                    onCancel: {
                        deletionTarget = nil
                    },
                    onConfirm: {
                        deletionTarget = nil
                        Task {
                            await bridge.deleteTransportConfiguration(mode)
                        }
                    }
                )
            }
        }
        .sheet(isPresented: $showCloseConfirmation) {
            HarborDestructiveConfirmDialog(
                title: "关闭本地访问？",
                message: "关闭后 ChatGPT 将无法访问本地 MCP 工具。",
                confirmTitle: "关闭服务",
                onCancel: { showCloseConfirmation = false },
                onConfirm: {
                    showCloseConfirmation = false
                    beginStopOperation()
                }
            )
        }
    }

    private var headerSection: some View {
        let serviceRunning = bridge.agentRunning || bridge.runtime.agent == .starting
        let statusTitle = serviceRunning
            ? (bridge.overallReady ? "服务运行中" : "服务连接中")
            : "启动服务"
        let statusColor = serviceRunning
            ? (bridge.overallReady ? HarborColors.green : HarborColors.orange)
            : Color.secondary
        let selectedIsActive = selectedMode == bridge.configuration.transportMode
        let selectedIsConfigured = isConfigured(selectedMode)
        let busy = operation != nil || bridge.isWorking || bridge.isSwitchingTransport || bridge.isDiagnosing
        let canDetect = selectedIsActive
            && serviceRunning
            && !bridge.configuration.allowedRoots.isEmpty
        let canReconnect = selectedIsActive
            && selectedIsConfigured
            && serviceRunning
            && !bridge.configuration.allowedRoots.isEmpty
        let canSwitch = serviceRunning
            && !selectedIsActive
            && selectedIsConfigured
            && !bridge.configuration.allowedRoots.isEmpty
        let canToggleService = serviceRunning
            || (selectedIsConfigured && !bridge.configuration.allowedRoots.isEmpty)

        return HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("本地访问")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                Text("查看真实链路状态，管理授权目录与连接方式。")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 14)

            Button {
                if serviceRunning {
                    showCloseConfirmation = true
                } else {
                    beginStartOperation()
                }
            } label: {
                HStack(spacing: 6) {
                    Circle()
                        .fill(statusColor)
                        .frame(width: 7, height: 7)
                    Text(statusTitle)
                        .lineLimit(1)
                }
                .frame(width: 92)
            }
            .buttonStyle(HarborActionButtonStyle(
                tint: serviceRunning ? statusColor : HarborColors.blue,
                prominence: .secondary
            ))
            .disabled(!canToggleService || busy)
            .help(
                serviceRunning
                    ? "关闭服务"
                    : (selectedIsConfigured ? "启动\(selectedMode.displayName)" : "请先完成连接配置")
            )

            Button(action: beginConnectionTest) {
                HStack(spacing: 6) {
                    if bridge.isDiagnosing {
                        ProgressView().controlSize(.mini)
                    } else {
                        Image(systemName: testFeedback?.state == .success ? "checkmark" : "waveform.path.ecg")
                    }
                    Text(bridge.isDiagnosing ? "检测中…" : "检测")
                        .lineLimit(1)
                }
                .frame(width: 66)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(!canDetect || busy)
            .help(canDetect ? "检测当前连接" : "请先选择当前正在使用的连接")

            Button(action: beginReconnectOperation) {
                Label("重新连接", systemImage: "arrow.clockwise")
                    .lineLimit(1)
                    .frame(width: 82)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(!canReconnect || busy)
            .help(canReconnect ? "重新连接当前连接" : "请先选择当前正在使用的连接")

            Button(action: beginSwitchOperation) {
                Label("切换连接", systemImage: "arrow.left.arrow.right")
                    .lineLimit(1)
                    .frame(width: 82)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
            .disabled(!canSwitch || busy)
            .help(
                canSwitch
                    ? "切换到\(selectedMode.displayName)"
                    : (selectedIsActive ? "当前已经使用该连接" : "请先完成\(selectedMode.displayName)配置")
            )

            Button {
                openChatGPTConfiguration(copyPublicAddress: true)
            } label: {
                Label(
                    copiedHTTPSAddress ? "已复制并打开" : "去 ChatGPT 配置",
                    systemImage: copiedHTTPSAddress ? "checkmark" : "arrow.up.right"
                )
                .lineLimit(1)
                .frame(width: 118)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
            .disabled(busy)
        }
        .frame(minHeight: 46)
    }

    private var allowedRootsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("允许访问的目录")
                        .font(.system(size: 14, weight: .semibold))
                    Text("两种连接方式共用这些目录；切换连接方式不会改变授权范围。")
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if !bridge.configuration.allowedRoots.isEmpty {
                    HarborStatusBadge(
                        title: "已授权 \(bridge.configuration.allowedRoots.count) 个目录",
                        color: HarborColors.green
                    )
                }

                Button(action: onAddRoot) {
                    Label("添加目录", systemImage: "plus")
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
            }

            HarborCard(padding: 0) {
                VStack(spacing: 0) {
                    if bridge.configuration.allowedRoots.isEmpty {
                        VStack(spacing: 9) {
                            Image(systemName: "folder.badge.plus")
                                .font(.system(size: 25, weight: .medium))
                                .foregroundStyle(HarborColors.blue)
                            Text("尚未添加允许访问目录")
                                .font(.system(size: 12, weight: .semibold))
                            Text("连接配置可以单独保存；启动本地访问前至少需要添加一个目录。")
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                            Button("添加目录", action: onAddRoot)
                                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                        }
                        .frame(maxWidth: .infinity, minHeight: 128)
                    } else {
                        ForEach(bridge.configuration.allowedRoots, id: \.self) { root in
                            rootRow(root)
                            if root != bridge.configuration.allowedRoots.last {
                                Divider().opacity(0.4).padding(.leading, 65)
                            }
                        }
                    }
                }
            }
        }
    }

    private var transportSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("连接方式")
                    .font(.system(size: 14, weight: .semibold))
                Text("点击卡片只选择要操作的方式；“配置”按钮才会打开对应配置弹窗。")
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 12) {
                transportCard(.secureTunnel)
                transportCard(.httpsCompatibility)
            }
        }
    }

    private var connectionPathCard: some View {
        let serviceRunning = bridge.agentRunning || bridge.runtime.agent == .starting
        let mode = serviceRunning
            ? bridge.configuration.transportMode
            : selectedMode
        let diagnostics = bridge.runtime.pipelineDiagnostics
        let nodes = diagnostics.nodes
        let failedNode = nodes.first { $0.state == .failed }
        let recoveryNode = nodes.first { $0.state == .recovering || $0.state == .connecting }
        let chatGPTNode = diagnostics.node("chatgpt-mcp")
        let endpointReady = diagnostics.node("openai-tunnel")?.state == .ready
        let chatGPTWaiting = serviceRunning && endpointReady && chatGPTNode?.state == .waiting

        return HarborCard(padding: 16) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text(mode == .secureTunnel ? "本地管道" : "公网 HTTPS")
                            .font(.system(size: 14, weight: .semibold))

                        Text(
                            serviceRunning
                                ? "按本机服务到 ChatGPT 的真实连接顺序展示。"
                                : "启动后将在这里显示实时连接过程。"
                        )
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                    }

                    Spacer()

                    if let lastManualCheckAt {
                        Text("最近检测 \(lastManualCheckAt, style: .relative)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                }

                Divider().opacity(0.32)

                if nodes.isEmpty {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(serviceRunning ? "正在读取链路诊断…" : "启动服务后显示真实链路诊断")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, minHeight: 88)
                } else {
                    HStack(spacing: 0) {
                        ForEach(Array(nodes.enumerated()), id: \.element.id) { index, node in
                            stage(node, icon: icon(for: node.id))

                            if index < nodes.count - 1 {
                                flowConnector(state: nodes[index + 1].state)
                            }
                        }
                    }
                    .frame(minHeight: 88)
                }

                if let expandedDiagnosticID,
                   let node = diagnostics.node(expandedDiagnosticID) {
                    diagnosticDetails(node)
                        .transition(.opacity.combined(with: .move(edge: .top)))
                }

                chainSummary(
                    serviceRunning: serviceRunning,
                    failedNode: failedNode,
                    recoveryNode: recoveryNode,
                    chatGPTWaiting: chatGPTWaiting
                )
            }
            .animation(.easeOut(duration: 0.24), value: bridge.overallReady)
            .animation(.easeOut(duration: 0.24), value: bridge.runtime.tunnel.rawValue)
        }
    }

    private func chainNotice(icon: String, color: Color, text: String) -> some View {
        HStack(alignment: .top, spacing: 7) {
            Image(systemName: icon)
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.72))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(color.opacity(0.065), in: RoundedRectangle(cornerRadius: 9, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .stroke(color.opacity(0.14), lineWidth: 1)
        )
        .frame(height: 40)
    }

    @ViewBuilder
    private func chainSummary(
        serviceRunning: Bool,
        failedNode: BridgeNodeDiagnostic?,
        recoveryNode: BridgeNodeDiagnostic?,
        chatGPTWaiting: Bool
    ) -> some View {
        if let failedNode {
            chainNotice(
                icon: "exclamationmark.triangle.fill",
                color: HarborColors.red,
                text: "\(failedNode.title)：\(failedNode.message)"
            )
        } else if let recoveryNode {
            chainNotice(
                icon: "arrow.triangle.2.circlepath",
                color: HarborColors.blue,
                text: "\(recoveryNode.title)：\(recoveryNode.message)"
            )
        } else if chatGPTWaiting {
            chainNotice(
                icon: "clock.badge.questionmark",
                color: HarborColors.orange,
                text: "链路已经就绪，等待 ChatGPT MCP 首次调用。"
            )
        } else if serviceRunning {
            chainNotice(
                icon: "checkmark.circle.fill",
                color: HarborColors.green,
                text: "本地链路健康，所有可检测节点均已就绪。"
            )
        } else {
            chainNotice(
                icon: "pause.circle.fill",
                color: .secondary,
                text: "本地访问当前已关闭。"
            )
        }
    }

    private var approvalCard: some View {
        HarborCard(padding: 14) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Label("待确认操作", systemImage: "hand.raised.fill")
                        .font(.system(size: 12.5, weight: .semibold))
                        .foregroundStyle(HarborColors.orange)
                    Spacer()
                    HarborStatusBadge(
                        title: "\(bridge.pendingApprovalRequests.count) 项",
                        color: HarborColors.orange
                    )
                }

                ForEach(bridge.pendingApprovalRequests.prefix(3)) { request in
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(request.tool)
                                .font(.system(size: 10.5, weight: .semibold, design: .monospaced))
                            Text(request.summary)
                                .font(.system(size: 9.5))
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }

                        Spacer()

                        Button("拒绝") {
                            Task { await bridge.decideApproval(request, allow: false) }
                        }
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))

                        Button("允许一次") {
                            Task { await bridge.decideApproval(request, allow: true) }
                        }
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
                    }
                    .padding(.vertical, 3)
                }
            }
        }
    }

    private func transportCard(_ mode: BridgeTransportMode) -> some View {
        let configured = isConfigured(mode)
        let current = bridge.configuration.transportMode == mode
        let active = (bridge.agentRunning || bridge.runtime.agent == .starting)
            && current
        let ready = active && bridge.overallReady
        let selected = selectedMode == mode
        let interactionLocked = operation != nil
            || bridge.isWorking
            || bridge.isSwitchingTransport
            || bridge.isDiagnosing
        let status = transportStatus(configured: configured, active: active, ready: ready)

        return HarborCard(padding: 16) {
            VStack(alignment: .leading, spacing: 13) {
                HStack(spacing: 12) {
                    Image(systemName: mode == .secureTunnel
                        ? "point.3.connected.trianglepath.dotted"
                        : "icloud.fill")
                        .font(.system(size: 19, weight: .semibold))
                        .foregroundStyle(HarborColors.blue)
                        .frame(width: 42, height: 42)
                        .background(Color.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                    VStack(alignment: .leading, spacing: 4) {
                        Text(mode == .secureTunnel ? "OpenAI 本地管道" : "公网 HTTPS")
                            .font(.system(size: 14, weight: .semibold))

                        Text(mode == .secureTunnel
                            ? "通过 OpenAI Tunnel 建立本地访问"
                            : "通过 Cloudflare 提供公网 HTTPS 访问")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    Spacer()

                    HarborStatusBadge(
                        title: status.title,
                        color: status.color,
                        pulses: ready || active
                    )
                }

                HStack(spacing: 8) {
                    if selected && current {
                        Label("当前连接", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(HarborColors.green)
                    } else if current {
                        Label("当前使用", systemImage: "circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(HarborColors.green)
                    } else if selected {
                        Label("已选择", systemImage: "checkmark.circle.fill")
                            .font(.system(size: 9.5, weight: .semibold))
                            .foregroundStyle(HarborColors.blue)
                    } else {
                        Text("点击卡片选择")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                    }

                    Spacer()

                    Button {
                        onConfigure(mode)
                    } label: {
                        Image(systemName: "gearshape")
                            .frame(width: 18, height: 18)
                    }
                    .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                    .disabled(interactionLocked)
                    .help(configured ? "配置" : "开始配置")

                    if configured {
                        Button {
                            deletionTarget = mode
                        } label: {
                            Image(systemName: "trash")
                                .frame(width: 18, height: 18)
                        }
                        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                        .disabled(interactionLocked)
                        .help("删除配置")
                    }
                }
            }
        }
        .overlay(
            RoundedRectangle(cornerRadius: HarborRadius.card, style: .continuous)
                .stroke(
                    selected ? HarborColors.blue.opacity(0.75) : Color.clear,
                    lineWidth: selected ? 1.4 : 0
                )
        )
        .contentShape(Rectangle())
        .onTapGesture {
            guard !interactionLocked else { return }
            selectedMode = mode
        }
        .frame(maxWidth: .infinity)
    }

    private func stage(
        _ node: BridgeNodeDiagnostic,
        icon: String
    ) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.2)) {
                expandedDiagnosticID = expandedDiagnosticID == node.id ? nil : node.id
            }
        } label: {
            HarborConnectionStage(
                title: node.title,
                icon: icon,
                detail: node.message,
                state: node.state
            )
        }
        .buttonStyle(.plain)
        .help("点击查看 \(node.title) 诊断详情")
    }

    private func flowConnector(state: BridgeNodeState) -> some View {
        HarborAnimatedFlowConnector(
            ready: state == .ready,
            active: state == .connecting || state == .recovering,
            failed: state == .failed
        )
        .frame(width: 52, height: 30)
        .offset(y: -10)
    }

    private func icon(for id: String) -> String {
        switch id {
        case "agent": "cube.fill"
        case "mcp": "desktopcomputer"
        case "tunnel-client": "link"
        case "openai-tunnel": "icloud.fill"
        case "chatgpt-mcp": "circle.hexagongrid.fill"
        default: "circle"
        }
    }

    private func diagnosticDetails(_ node: BridgeNodeDiagnostic) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon(for: node.id))
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(node.state.harborColor)
                .frame(width: 28, height: 28)
                .background(node.state.harborColor.opacity(0.09), in: Circle())

            VStack(alignment: .leading, spacing: 3) {
                Text("\(node.title) · \(node.state.displayTitle)")
                    .font(.system(size: 10.5, weight: .semibold))
                Text(node.details.isEmpty ? node.message : node.details.joined(separator: "  ·  "))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }

            Spacer(minLength: 8)

            if let latency = node.latency {
                Text("\(latency) ms")
                    .font(.system(size: 9, weight: .medium).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            if let date = node.lastCheckAt {
                Text(date, style: .relative)
                    .font(.system(size: 9))
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(node.state.harborColor.opacity(0.045), in: RoundedRectangle(cornerRadius: 9))
    }

    private func beginConnectionTest() {
        guard operation == nil, !bridge.isDiagnosing else { return }
        testFeedback = ConnectionTestFeedback(
            state: .testing,
            title: "正在检测连接",
            detail: "检查 MCP、Tunnel 与 OpenAI 入口"
        )

        Task { @MainActor in
            let startedAt = Date()
            await bridge.runPipelineDiagnostics()
            lastManualCheckAt = Date()

            let duration = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
            // 检测期间链路图保持冻结；这里只使用检测完成后的最终完整结果。
            let failures = bridge.diagnosticResults.filter { $0.status == .failed }
            let warnings = bridge.diagnosticResults.filter { $0.status == .warning }
            if let failure = failures.first {
                testFeedback = ConnectionTestFeedback(
                    state: .failed,
                    title: "连接异常",
                    detail: failure.message
                )
            } else if let warning = warnings.first {
                testFeedback = ConnectionTestFeedback(
                    state: .success,
                    title: "连接可用",
                    detail: warning.message
                )
            } else {
                testFeedback = ConnectionTestFeedback(
                    state: .success,
                    title: "连接正常",
                    detail: "MCP、Tunnel、OpenAI 入口 · \(duration) ms"
                )
            }

            try? await Task.sleep(for: .seconds(2.2))
            withAnimation(.easeOut(duration: 0.18)) {
                testFeedback = nil
            }
        }
    }

    private func beginStartOperation() {
        guard operation == nil else { return }
        let mode = selectedMode
        guard isConfigured(mode), !bridge.configuration.allowedRoots.isEmpty else { return }

        operation = ConnectionOperationContext(
            kind: .starting,
            subtitle: mode.displayName,
            state: .preparing,
            steps: [
                ConnectionOperationStep(id: "prepare", title: "准备连接", state: .running, detail: "执行中"),
                ConnectionOperationStep(id: "start", title: "启动本地服务"),
                ConnectionOperationStep(id: "health", title: "健康检查"),
                ConnectionOperationStep(id: "status", title: "更新状态")
            ],
            footer: "正在启动本地访问，请稍候…"
        )

        Task { @MainActor in
            updateOperationStep(0, state: .completed, detail: "已完成")
            updateOperationStep(1, state: .running, detail: "执行中", operationState: .running)
            await bridge.startTransportMode(mode)
            guard bridge.configuration.transportMode == mode, bridge.agentRunning else {
                failOperation(step: 1, message: bridge.statusMessage ?? "本地服务未能启动")
                return
            }

            updateOperationStep(1, state: .completed, detail: "已完成")
            updateOperationStep(2, state: .running, detail: "检查中", operationState: .checking)
            guard await waitForConnectionReady() else {
                let failure = bridge.runtime.pipelineDiagnostics.nodes.first { $0.state == .failed }
                failOperation(step: 2, message: failure?.message ?? "服务已启动，远端连接仍在恢复")
                return
            }

            updateOperationStep(2, state: .completed, detail: "已完成")
            updateOperationStep(3, state: .running, detail: "执行中", operationState: .running)
            await bridge.refresh()
            selectedMode = bridge.configuration.transportMode
            updateOperationStep(3, state: .completed, detail: "已完成")
            await finishOperation(footer: "本地访问已启动")
        }
    }

    private func beginSwitchOperation() {
        guard operation == nil else { return }
        let source = bridge.configuration.transportMode
        let target = selectedMode
        guard source != target, isConfigured(target) else { return }

        operation = ConnectionOperationContext(
            kind: .switching,
            subtitle: "\(source.displayName) → \(target.displayName)",
            state: .preparing,
            steps: [
                ConnectionOperationStep(id: "stop", title: "停止旧连接", state: .running, detail: "执行中"),
                ConnectionOperationStep(id: "start", title: "启动新连接"),
                ConnectionOperationStep(id: "health", title: "健康检查"),
                ConnectionOperationStep(id: "status", title: "更新状态")
            ],
            footer: "正在安全切换连接，请稍候…"
        )

        Task { @MainActor in
            // 运行中的模式切换必须走生命周期事务：失败时恢复旧配置和旧连接。
            await bridge.selectTransportMode(target)
            guard bridge.configuration.transportMode == target, bridge.agentRunning else {
                failOperation(step: 1, message: bridge.statusMessage ?? "新连接未能启动，已恢复原连接")
                return
            }

            updateOperationStep(0, state: .completed, detail: "已完成")
            updateOperationStep(1, state: .completed, detail: "已完成")
            updateOperationStep(2, state: .running, detail: "检查中", operationState: .checking)

            guard await waitForConnectionReady() else {
                let failure = bridge.runtime.pipelineDiagnostics.nodes.first { $0.state == .failed }
                failOperation(step: 2, message: failure?.message ?? "健康检查超时")
                return
            }

            updateOperationStep(2, state: .completed, detail: "已完成")
            updateOperationStep(3, state: .running, detail: "执行中", operationState: .running)
            await bridge.refresh()
            selectedMode = bridge.configuration.transportMode
            updateOperationStep(3, state: .completed, detail: "已完成")
            await finishOperation(footer: "连接状态已更新")
        }
    }

    private func beginReconnectOperation() {
        guard operation == nil else { return }
        let mode = bridge.configuration.transportMode
        guard isConfigured(mode) else { return }

        operation = ConnectionOperationContext(
            kind: .reconnecting,
            subtitle: mode.displayName,
            state: .preparing,
            steps: [
                ConnectionOperationStep(id: "inspect", title: "检查当前服务", state: .running, detail: "检查中"),
                ConnectionOperationStep(id: "reconnect", title: "重新建立连接"),
                ConnectionOperationStep(id: "health", title: "健康检查"),
                ConnectionOperationStep(id: "status", title: "更新状态")
            ],
            footer: "正在重新建立连接，请稍候…"
        )

        Task { @MainActor in
            await bridge.refresh()
            updateOperationStep(0, state: .completed, detail: "已完成")
            updateOperationStep(1, state: .running, detail: "执行中", operationState: .running)
            await bridge.startTransportMode(mode)
            guard bridge.agentRunning else {
                failOperation(step: 1, message: bridge.statusMessage ?? "服务未能重新启动")
                return
            }

            updateOperationStep(1, state: .completed, detail: "已完成")
            updateOperationStep(2, state: .running, detail: "检查中", operationState: .checking)
            guard await waitForConnectionReady() else {
                let failure = bridge.runtime.pipelineDiagnostics.nodes.first { $0.state == .failed }
                failOperation(step: 2, message: failure?.message ?? "健康检查超时")
                return
            }

            updateOperationStep(2, state: .completed, detail: "已完成")
            updateOperationStep(3, state: .running, detail: "执行中", operationState: .running)
            await bridge.refresh()
            selectedMode = bridge.configuration.transportMode
            updateOperationStep(3, state: .completed, detail: "已完成")
            await finishOperation(footer: "连接状态已更新")
        }
    }

    private func beginStopOperation() {
        guard operation == nil else { return }
        operation = ConnectionOperationContext(
            kind: .stopping,
            subtitle: bridge.configuration.transportMode.displayName,
            state: .preparing,
            steps: [
                ConnectionOperationStep(id: "stop", title: "停止连接", state: .running, detail: "执行中"),
                ConnectionOperationStep(id: "cleanup", title: "清理资源"),
                ConnectionOperationStep(id: "status", title: "更新状态")
            ],
            footer: "正在关闭本地访问，请稍候…"
        )

        Task { @MainActor in
            await bridge.setEnabled(false)
            guard !bridge.agentRunning else {
                failOperation(step: 0, message: "本地服务仍在运行")
                return
            }

            updateOperationStep(0, state: .completed, detail: "已完成")
            updateOperationStep(1, state: .completed, detail: "已完成")
            updateOperationStep(2, state: .running, detail: "执行中", operationState: .running)
            await bridge.refresh()
            selectedMode = bridge.configuration.transportMode
            updateOperationStep(2, state: .completed, detail: "已完成")
            await finishOperation(footer: "本地访问已关闭")
        }
    }

    @MainActor
    private func waitForConnectionReady() async -> Bool {
        for _ in 0..<30 {
            await bridge.refresh()
            if bridge.overallReady { return true }

            let terminalFailure = bridge.runtime.pipelineDiagnostics.nodes.contains { node in
                node.state == .failed && ["agent", "mcp", "tunnel-client"].contains(node.id)
            }
            if terminalFailure { return false }
            try? await Task.sleep(for: .milliseconds(500))
        }
        await bridge.runPipelineDiagnostics()
        return bridge.overallReady
    }

    @MainActor
    private func updateOperationStep(
        _ index: Int,
        state: ConnectionOperationStepState,
        detail: String,
        operationState: ConnectionOperationState? = nil
    ) {
        guard var current = operation, current.steps.indices.contains(index) else { return }
        current.steps[index].state = state
        current.steps[index].detail = detail
        if let operationState {
            current.state = operationState
        }
        withAnimation(.easeOut(duration: 0.18)) {
            operation = current
        }
    }

    @MainActor
    private func failOperation(step: Int, message: String) {
        guard var current = operation, current.steps.indices.contains(step) else { return }
        current.state = .failed
        current.steps[step].state = .failed
        current.steps[step].detail = "失败"
        current.footer = message
        withAnimation(.easeOut(duration: 0.18)) {
            operation = current
        }
    }

    @MainActor
    private func finishOperation(footer: String) async {
        guard var current = operation else { return }
        current.state = .success
        current.footer = footer
        withAnimation(.easeOut(duration: 0.18)) {
            operation = current
        }
        try? await Task.sleep(for: .milliseconds(500))
        withAnimation(.easeOut(duration: 0.18)) {
            operation = nil
        }
    }

    private func copyHTTPSAddress(_ url: URL) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.absoluteString, forType: .string)
        copiedHTTPSAddress = true

        Task { @MainActor in
            try? await Task.sleep(for: .seconds(1.5))
            copiedHTTPSAddress = false
        }
    }

    private var activeDisplayMode: BridgeTransportMode {
        (bridge.agentRunning || bridge.runtime.agent == .starting)
            ? bridge.configuration.transportMode
            : selectedMode
    }

    private func openChatGPTConfiguration(copyPublicAddress: Bool = false) {
        if copyPublicAddress,
           activeDisplayMode == .httpsCompatibility,
           let url = bridge.publicHTTPSMCPURL {
            copyHTTPSAddress(url)
        }
        guard let settingsURL = URL(string: "https://chatgpt.com/#settings/Connectors") else { return }
        NSWorkspace.shared.open(settingsURL)
    }

    private func rootRow(_ root: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "folder.fill")
                .font(.system(size: 17))
                .foregroundStyle(.orange)
                .frame(width: 38, height: 38)
                .background(Color.orange.opacity(0.08), in: RoundedRectangle(cornerRadius: 10))

            VStack(alignment: .leading, spacing: 3) {
                Text(URL(fileURLWithPath: root).lastPathComponent)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Text(root)
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            Text(bridge.unrestrictedDevelopmentAccessEnabled ? "开发模式" : "安全模式")
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(bridge.unrestrictedDevelopmentAccessEnabled
                    ? HarborColors.orange
                    : HarborColors.blue)

            Button("打开") {
                NSWorkspace.shared.open(URL(fileURLWithPath: root))
            }
            .buttonStyle(HarborActionButtonStyle(tint: .blue, prominence: .secondary))

            Button("删除", role: .destructive) {
                onRemoveRoot(root)
            }
            .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
        }
        .padding(.horizontal, 15)
        .frame(height: 62)
    }

    private func transportStatus(
        configured: Bool,
        active: Bool,
        ready: Bool
    ) -> (title: String, color: Color) {
        if ready {
            return ("使用中", HarborColors.green)
        }
        if active {
            return ("连接中", HarborColors.blue)
        }
        if configured {
            return ("已配置", HarborColors.orange)
        }
        return ("未配置", .secondary)
    }

    private func deletionMessage(for mode: BridgeTransportMode) -> String {
        switch mode {
        case .secureTunnel:
            return "将删除 Tunnel ID、Runtime Key、Harbor 自动下载的 tunnel-client、安装包与本地运行文件。下次配置会重新下载；OpenAI 平台上的 Tunnel 不会被删除。"
        case .httpsCompatibility:
            return "将删除公网 HTTPS 配置、访问令牌、Cloudflare 本地授权、当前 Tunnel 本地凭据，以及 Harbor 自动下载的 cloudflared 与安装包。下次配置必须重新下载并授权；Cloudflare 账号中的域名和 Tunnel 不会被删除。"
        }
    }

    private func isConfigured(_ mode: BridgeTransportMode) -> Bool {
        switch mode {
        case .secureTunnel:
            return bridge.configuration.secureTunnel != nil && bridge.hasTunnelRuntimeKey
        case .httpsCompatibility:
            return bridge.configuration.httpsCompatibility != nil && bridge.hasPublicHTTPSAccessToken
        }
    }
}
