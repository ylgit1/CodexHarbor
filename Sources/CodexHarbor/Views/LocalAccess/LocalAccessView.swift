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
    @State private var operation: ConnectionOperationContext?
    @State private var testFeedback: ConnectionTestFeedback?
    @State private var showCloseConfirmation = false

    var body: some View {
        ZStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerSection
                    connectionOverview
                    actionBar
                    transportSection
                    allowedRootsSection
                }
                .frame(maxWidth: 1240, alignment: .topLeading)
                .padding(.horizontal, 28)
                .padding(.top, 25)
                .padding(.bottom, 32)
                .frame(maxWidth: .infinity, alignment: .top)
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
                        self.operation = nil
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

                    .zIndex(3)
            }
        }
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
                title: "关闭 ChatGPT 接入？",
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
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 5) {
                Text("ChatGPT 接入").font(.system(size: 23, weight: .semibold))
                Text("管理接入服务、连接方式与授权目录")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            HarborStatusBadge(
                title: bridge.agentRunning ? (bridge.overallReady ? "连接正常" : "等待连接") : "未启动",
                color: bridge.overallReady ? HarborColors.green : HarborColors.orange,
                pulses: false
            )
        }
        .frame(minHeight: 48)
    }

    private var connectionOverview: some View {
        let running = bridge.agentRunning || bridge.runtime.agent == .starting
        let ready = running && bridge.overallReady
        let locked = operation != nil || bridge.isWorking ||
            bridge.isSwitchingTransport || bridge.isDiagnosing

        return VStack(alignment: .leading, spacing: 17) {
            HStack(alignment: .center, spacing: 15) {
                Image(systemName: ready ? "checkmark.shield.fill" : "network")
                    .font(.system(size: 22, weight: .medium))
                    .foregroundStyle(ready ? HarborColors.green : HarborColors.blue)
                    .frame(width: 52, height: 52)
                    .background(
                        (ready ? HarborColors.green : HarborColors.blue).opacity(0.075),
                        in: RoundedRectangle(cornerRadius: 12)
                    )

                VStack(alignment: .leading, spacing: 5) {
                    Text(ready ? "服务已就绪" : (running ? "正在建立连接" : "服务尚未启动"))
                        .font(.system(size: 16, weight: .semibold))
                    Text(running
                        ? "正在使用 \(bridge.configuration.transportMode.displayName)"
                        : "选择连接方式并启动，向 ChatGPT 提供本地工具")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer(minLength: 12)

                // The existing configuration action lives here instead of
                // competing with routine controls in the toolbar.
                chatGPTSettingsButton(enabled: !locked)
            }

            Divider().opacity(0.48)

            HStack(spacing: 18) {
                overviewState(
                    "本地 Agent",
                    title: bridge.runtime.agent == .running ? "运行中" :
                        (bridge.runtime.agent == .starting ? "启动中" : "未运行"),
                    ready: bridge.runtime.agent == .running
                )
                overviewState(
                    "MCP 服务",
                    title: bridge.runtime.mcp == .ready ? "已就绪" :
                        (bridge.runtime.mcp == .starting ? "启动中" : "未就绪"),
                    ready: bridge.runtime.mcp == .ready
                )
                overviewState(
                    "连接通道",
                    title: bridge.runtime.tunnel == .connected ? "已连接" :
                        (bridge.runtime.tunnel == .connecting ? "连接中" : "未连接"),
                    ready: bridge.runtime.tunnel == .connected
                )

                Spacer(minLength: 0)

                overviewMetric("授权目录", "\(bridge.configuration.allowedRoots.count)")
                overviewMetric("工具数量", bridge.runtime.toolCatalogCount.map(String.init) ?? "—")
            }
        }
        .padding(19)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            HarborColors.cardBackground,
            in: RoundedRectangle(cornerRadius: 12)
        )
        .overlay(RoundedRectangle(cornerRadius: 12).stroke(HarborColors.cardBorder))
    }

    private func overviewState(_ label: String, title: String, ready: Bool) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            HStack(spacing: 6) {
                Circle()
                    .fill(ready ? HarborColors.green : HarborColors.orange)
                    .frame(width: 6, height: 6)
                Text(title)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
        }
        .frame(minWidth: 86, alignment: .leading)
    }

    private func overviewMetric(_ title: String, _ value: String) -> some View {
        VStack(alignment: .trailing, spacing: 5) {
            Text(value)
                .font(.system(size: 17, weight: .semibold, design: .rounded))
                .monospacedDigit()
            Text(title)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .frame(minWidth: 54, alignment: .trailing)
    }

    private var actionBar: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                Label("连接控制", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                headerControls
            }
            VStack(alignment: .leading, spacing: 12) {
                Label("连接控制", systemImage: "slider.horizontal.3")
                    .font(.system(size: 12, weight: .semibold))
                headerControls
            }
        }
        .padding(.horizontal, 17)
        .padding(.vertical, 13)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(HarborColors.cardBackground, in: RoundedRectangle(cornerRadius: 11))
        .overlay(RoundedRectangle(cornerRadius: 11).stroke(HarborColors.cardBorder))
    }

    private var headerControls: some View {
        let serviceRunning = bridge.agentRunning || bridge.runtime.agent == .starting
        let selectedIsActive = selectedMode == bridge.configuration.transportMode
        let selectedIsConfigured = isConfigured(selectedMode)
        let busy = operation != nil || bridge.isWorking || bridge.isSwitchingTransport || bridge.isDiagnosing
        let hasRoots = !bridge.configuration.allowedRoots.isEmpty
        let canDetect = selectedIsActive && serviceRunning && hasRoots
        let canReconnect = canDetect && selectedIsConfigured
        let canSwitch = serviceRunning && !selectedIsActive && selectedIsConfigured && hasRoots
        let canToggleService = serviceRunning || (selectedIsConfigured && hasRoots)
        let targetName = selectedMode == .secureTunnel ? "本地管道" : "公网 HTTPS"
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 7) {
                serviceToggleButton(serviceRunning: serviceRunning, enabled: canToggleService && !busy)
                detectButton(enabled: canDetect && !busy)
                reconnectButton(enabled: canReconnect && !busy)
                switchButton(targetName: targetName, enabled: canSwitch && !busy,
                             isCurrent: selectedIsActive, configured: selectedIsConfigured)
            }
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 7) {
                    serviceToggleButton(serviceRunning: serviceRunning, enabled: canToggleService && !busy)
                    detectButton(enabled: canDetect && !busy)
                    reconnectButton(enabled: canReconnect && !busy)
                }
                HStack(spacing: 7) {
                    switchButton(targetName: targetName, enabled: canSwitch && !busy,
                                 isCurrent: selectedIsActive, configured: selectedIsConfigured)
                    }
            }
        }
    }

    private var actionUnavailableHint: String {
        if operation != nil || bridge.isWorking || bridge.isSwitchingTransport || bridge.isDiagnosing {
            return "正在执行连接操作，请等待完成"
        }
        if bridge.configuration.allowedRoots.isEmpty {
            return "请先添加允许访问的目录"
        }
        if !isConfigured(selectedMode) {
            return "请先配置选中的接入方式"
        }
        if !bridge.agentRunning && bridge.runtime.agent != .starting {
            return "请先启动 ChatGPT 接入服务"
        }
        if selectedMode != bridge.configuration.transportMode {
            return "请先选择当前正在使用的连接方式"
        }
        return "该操作当前不可用，请检查连接状态"
    }

    private func serviceToggleButton(serviceRunning: Bool, enabled: Bool) -> some View {
        Button {
            if serviceRunning {
                showCloseConfirmation = true
            } else {
                beginStartOperation()
            }
        } label: {
            Label(serviceRunning ? "关闭服务" : "启动服务",
                  systemImage: serviceRunning ? "power" : "play.fill")
                .lineLimit(1)
                .frame(width: 76)
        }
        .buttonStyle(HarborActionButtonStyle(
            tint: serviceRunning ? HarborColors.red : HarborColors.blue,
            prominence: .secondary
        ))
        .disabled(!enabled)
        .help(enabled
              ? (serviceRunning ? "关闭 ChatGPT 接入（需确认）" : "启动当前选择的连接方式")
              : actionUnavailableHint)
    }

    private func detectButton(enabled: Bool) -> some View {
        Button(action: beginConnectionTest) {
            HStack(spacing: 6) {
                if bridge.isDiagnosing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: testFeedback?.state == .success
                          ? "checkmark" : "waveform.path.ecg")
                }
                Text(bridge.isDiagnosing ? "检测中…" : "检测")
                    .lineLimit(1)
            }
            .frame(width: 62)
        }
        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
        .disabled(!enabled)
        .help(enabled ? "检测当前连接" : actionUnavailableHint)
    }

    private func reconnectButton(enabled: Bool) -> some View {
        Button(action: beginReconnectOperation) {
            Label("重新连接", systemImage: "arrow.clockwise")
                .lineLimit(1)
                .frame(width: 80)
        }
        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
        .disabled(!enabled)
        .help(enabled ? "重新连接当前连接" : actionUnavailableHint)
    }

    private func switchButton(
        targetName: String, enabled: Bool, isCurrent: Bool, configured: Bool
    ) -> some View {
        Button(action: beginSwitchOperation) {
            Label(isCurrent ? "切换连接" : "切换至\(targetName)",
                  systemImage: "arrow.left.arrow.right")
                .lineLimit(1)
                .frame(width: 143)
        }
        .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .prominent))
        .disabled(!enabled)
        .help(enabled ? "切换到\(targetName)" :
              (isCurrent ? "当前已经使用该连接" : actionUnavailableHint))
    }

    private func chatGPTSettingsButton(enabled: Bool) -> some View {
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
        .disabled(!enabled)
        .help(enabled ? "打开 ChatGPT 的接入配置页面" : actionUnavailableHint)
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
                            Text("连接配置可以单独保存；启动 ChatGPT 接入前至少需要添加一个目录。")
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
            VStack(alignment: .leading, spacing: 3) {
                Text("连接方式")
                    .font(.system(size: 14, weight: .semibold))
                Text("选择连接方式；配置和删除操作位于对应卡片中。")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 14) {
                transportCard(.secureTunnel)
                transportCard(.httpsCompatibility)
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
                            ? "通过 OpenAI Tunnel 建立 ChatGPT 接入"
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
                    // The badge conveys runtime state; the outline conveys
                    // which mode is selected for the header actions.
                    Spacer(minLength: 0)

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

                if mode == .secureTunnel, configured {
                    HStack(spacing: 6) {
                        Image(systemName: bridge.runtime.proxyStatus?.selectedRoute == .systemProxy
                            ? "network"
                            : "arrow.right.circle")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text(secureTunnelProxySummary)
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                } else if mode == .httpsCompatibility, configured,
                          let hostname = bridge.configuration.httpsCompatibility?.hostname {
                    HStack(spacing: 6) {
                        Image(systemName: "globe")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                        Text("域名 · \(hostname)")
                            .font(.system(size: 9.5, weight: .medium))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .help(hostname)
                        Spacer(minLength: 0)
                    }
                }
            }
            // Reserve the same vertical space for both transport cards.
            // The tunnel card can display an extra proxy detail row.
            .frame(minHeight: 124, alignment: .topLeading)
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

    private func beginConnectionTest() {
        guard operation == nil, !bridge.isDiagnosing else { return }
        testFeedback = ConnectionTestFeedback(
            state: .testing,
            title: "正在检测连接",
            detail: "检查网络代理、MCP、Tunnel 与 OpenAI 入口"
        )

        Task { @MainActor in
            let startedAt = Date()
            await bridge.runPipelineDiagnostics()

            let duration = max(1, Int(Date().timeIntervalSince(startedAt) * 1_000))
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
                    detail: "网络代理、MCP、Tunnel、OpenAI 入口 · \(duration) ms"
                )
            }

            try? await Task.sleep(for: .seconds(2.2))
            testFeedback = nil
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
            footer: "正在启动 ChatGPT 接入，请稍候…"
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
            await finishOperation(footer: "ChatGPT 接入已启动")
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
            footer: "正在关闭 ChatGPT 接入，请稍候…"
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
            await finishOperation(footer: "ChatGPT 接入已关闭")
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
        operation = current
    }

    @MainActor
    private func failOperation(step: Int, message: String) {
        guard var current = operation, current.steps.indices.contains(step) else { return }
        current.state = .failed
        current.steps[step].state = .failed
        current.steps[step].detail = "失败"
        current.footer = message
        operation = current
    }

    @MainActor
    private func finishOperation(footer: String) async {
        guard var current = operation else { return }
        current.state = .success
        current.footer = footer
        operation = current
        try? await Task.sleep(for: .milliseconds(500))
        operation = nil
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

            let trusted = bridge.isTrustedDevelopmentRoot(root)
            Text(bridge.unrestrictedDevelopmentAccessEnabled
                 ? "完全授权" : (trusted ? "可信开发" : "安全模式"))
                .font(.system(size: 9.5, weight: .medium))
                .foregroundStyle(trusted || bridge.unrestrictedDevelopmentAccessEnabled
                                 ? HarborColors.orange : HarborColors.blue)
                .frame(minWidth: 48, alignment: .trailing)

            // Trust, open, remove: grouped controls with explicit tooltips.
            // Removal still invokes AppShellView's existing confirmation.
            HStack(spacing: 5) {
                Button {
                    Task { await bridge.setTrustedDevelopment(!trusted, root: root) }
                } label: {
                    Image(systemName: trusted ? "checkmark.shield.fill" : "checkmark.shield")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.orange, prominence: .secondary))
                .help(trusted ? "撤销该目录的可信开发授权" : "将该目录设为可信开发")
                .accessibilityLabel(trusted ? "撤销信任" : "信任目录")

                Rectangle()
                    .fill(Color.primary.opacity(0.10))
                    .frame(width: 1, height: 18)
                    .padding(.horizontal, 2)

                Button {
                    NSWorkspace.shared.open(URL(fileURLWithPath: root))
                } label: {
                    Image(systemName: "folder")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.blue, prominence: .secondary))
                .help("在 Finder 中打开目录")
                .accessibilityLabel("打开目录")

                Button(role: .destructive) {
                    onRemoveRoot(root)
                } label: {
                    Image(systemName: "trash")
                        .frame(width: 18, height: 18)
                }
                .buttonStyle(HarborActionButtonStyle(tint: HarborColors.red, prominence: .secondary))
                .help("移除目录授权（需确认）")
                .accessibilityLabel("移除目录")
            }
        }
        .padding(.horizontal, 15)
        .frame(height: 62)
    }

    private var secureTunnelProxySummary: String {
        let strategy = bridge.configuration.secureTunnel?.proxyStrategy ?? .automatic
        guard bridge.configuration.transportMode == .secureTunnel,
              let status = bridge.runtime.proxyStatus else {
            return "代理 · \(strategy.displayName)"
        }
        let proxy = status.systemProxyDescription.map { " · \($0)" } ?? ""
        return "代理 · \(strategy.displayName) · 当前\(status.selectedRoute.displayName)\(proxy)"
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
