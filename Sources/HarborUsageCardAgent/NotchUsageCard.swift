import AppKit
import Foundation
import SwiftUI
import CodexHarborCore

/// The notch display uses only public macOS window and screen APIs.
/// It never reads or changes ChatGPT's renderer, debug port or application bundle.
@MainActor
final class NotchQuotaModel: ObservableObject {
    @Published var quota: CodexQuotaSnapshot?
    @Published var message = "正在读取额度"
    @Published var hasChatGPT = false
    @Published var lastReadFailed = false
    @Published var displayNow = Date()

    /// Keep the last verified snapshot during brief App Server outages.
    /// Old information is explicitly marked as delayed, never reported as live.
    var hasRecentQuota: Bool {
        guard let quota else { return false }
        return Date().timeIntervalSince(quota.capturedAt) < 900
    }

    var isDelayed: Bool {
        guard let quota else { return false }
        return lastReadFailed || Date().timeIntervalSince(quota.capturedAt) > 150
    }

    /// The hover panel is read-only and grows only when stale data needs an explanation.
    var detailHeight: CGFloat {
        return isDelayed ? 212 : 192
    }

    /// Update displayed reset countdown at low frequency. No animation or rapid timer is needed.
    func advanceDisplay(at now: Date = Date()) {
        if now.timeIntervalSince(displayNow) >= 30 {
            displayNow = now
        }
    }

    func countdown(_ window: CodexQuotaWindow?) -> String? {
        guard hasRecentQuota, let reset = window?.resetDate else { return nil }
        let seconds = max(0, Int(reset.timeIntervalSince(displayNow)))
        if seconds == 0 { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)时" : "\(days)天" }
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        return "\(max(1, (seconds + 59) / 60))m"
    }

    func fullCountdown(_ window: CodexQuotaWindow?) -> String {
        guard hasRecentQuota, let reset = window?.resetDate else { return "重置时间待确认" }
        let seconds = max(0, Int(reset.timeIntervalSince(displayNow)))
        if seconds == 0 { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)天\(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时\(minutes)分钟后重置" }
        return "\(max(1, (seconds + 59) / 60))分钟后重置"
    }

    func remaining(_ window: CodexQuotaWindow?) -> Double? {
        guard hasRecentQuota, let window else { return nil }
        return window.remainingPercent
    }

    func tint(_ window: CodexQuotaWindow?) -> Color {
        guard let remaining = remaining(window) else { return .gray }
        if remaining < 10 { return Color(red: 0.96, green: 0.35, blue: 0.32) }
        if remaining <= 50 { return Color(red: 1.0, green: 0.74, blue: 0.35) }
        return Color(red: 0.17, green: 0.92, blue: 0.66)
    }

    func text(_ window: CodexQuotaWindow?) -> String {
        guard let remaining = remaining(window) else {
            if quota != nil { return "—" }
            return lastReadFailed ? "重试中" : "读取中"
        }
        return "\(Int(remaining.rounded()))%"
    }
}

private struct NotchRingView: View {
    let percent: Double?
    let tint: Color

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.23), lineWidth: 2.6)
            Circle()
                .trim(from: 0, to: max(0, min(1, (percent ?? 0) / 100)))
                .stroke(tint, style: StrokeStyle(lineWidth: 2.6, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
        .frame(width: 16, height: 16)
        .accessibilityHidden(true)
    }
}

/// Small view isolated from window management to keep SwiftUI type checking fast.
private struct NotchWingMetrics: View {
    let title: String
    let percent: String
    let reset: String

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 2) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.67))
                Spacer(minLength: 1)
                Text(percent)
                    .font(.system(size: 10, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
            Text(reset)
                .font(.system(size: 8, weight: .medium, design: .rounded))
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .foregroundStyle(.white.opacity(0.79))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct NotchWingView: View {
    @ObservedObject var model: NotchQuotaModel
    let isFiveHour: Bool
    let hover: (Bool) -> Void

    private var window: CodexQuotaWindow? {
        isFiveHour ? model.quota?.fiveHours : model.quota?.weekly
    }

    private var accessibleText: String {
        let name = isFiveHour ? "5 小时" : "每周"
        return name + "额度，剩余 " + model.text(window) + "，" + model.fullCountdown(window)
    }

    private var ring: some View {
        NotchRingView(percent: model.remaining(window), tint: model.tint(window))
    }

    private var metrics: some View {
        let reset = model.countdown(window).map { "重置 " + $0 } ?? "重置待定"
        return NotchWingMetrics(
            title: isFiveHour ? "5小时" : "周额度",
            percent: model.text(window),
            reset: reset
        )
    }

    var body: some View {
        HStack(spacing: 3) {
            ring
            metrics
        }
        .padding(.horizontal, 3)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.black.opacity(0.95))
        )
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(.white.opacity(0.17), lineWidth: 0.6)
        }
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .accessibilityLabel(accessibleText)
    }
}

private struct NotchDetailWindow: View {
    @ObservedObject var model: NotchQuotaModel
    let hover: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.donut.fill")
                        .foregroundStyle(Color(red: 0.17, green: 0.92, blue: 0.66))
                    Text("Codex 用量")
                        .font(.system(size: 13, weight: .semibold))
                }
                Spacer()
                Text(model.quota?.planType?.uppercased() ?? "账户额度")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.white.opacity(0.55))
            }

            HStack(alignment: .top, spacing: 10) {
                detailColumn("5 小时限额", window: model.quota?.fiveHours)
                detailColumn("每周限额", window: model.quota?.weekly)
            }

            Rectangle().fill(.white.opacity(0.14)).frame(height: 0.6)
            HStack(spacing: 8) {
                if let quota = model.quota {
                    Label((model.isDelayed ? "上次同步 " : "更新 ") +
                          quota.capturedAt.formatted(date: .omitted, time: .shortened),
                          systemImage: model.isDelayed ? "clock.arrow.circlepath" : "arrow.clockwise")
                    if let available = quota.resetCreditsAvailable {
                        Spacer(minLength: 4)
                        Label("重置卡 \(available) 张", systemImage: "ticket")
                    }
                } else {
                    Label(model.message, systemImage: "exclamationmark.circle")
                }
            }
            .font(.system(size: 9))
            .foregroundStyle(.white.opacity(0.59))

            if model.isDelayed {
                Text(model.lastReadFailed ? model.message : "数据更新稍有延迟，正在同步")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange.opacity(0.86))
            }

        }
        .padding(.horizontal, 13)
        .padding(.vertical, 12)
        .frame(width: 300, height: model.detailHeight, alignment: .topLeading)
        .foregroundStyle(.white)
        .background {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(Color(red: 0.065, green: 0.082, blue: 0.082).opacity(0.98))
        }
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(.white.opacity(0.16), lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onHover(perform: hover)
        .accessibilityLabel("Codex 套餐额度详情")
    }

    private func detailColumn(_ label: String, window: CodexQuotaWindow?) -> some View {
        let remaining = model.remaining(window)
        let tint = model.tint(window)
        return VStack(alignment: .leading, spacing: 4) {
            Text(label)
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.65))
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(remaining.map { "\(Int($0.rounded()))%" } ?? "—")
                    .font(.system(size: 22, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(tint)
                Text("剩余")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.62))
            }
            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.13))
                    Capsule().fill(tint)
                        .frame(width: geometry.size.width * max(0, min(1, (remaining ?? 0) / 100)))
                }
            }
            .frame(height: 4)
            Text(window.map { "已用 \(Int($0.usedPercent.rounded()))% · 剩余 \(Int($0.remainingPercent.rounded()))%" } ?? "正在获取额度")
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.73))
            Text(model.fullCountdown(window))
                .font(.system(size: 10))
                .foregroundStyle(.white.opacity(0.73))
            Text(window?.resetDate.map {
                $0.formatted(date: .abbreviated, time: .shortened)
            } ?? "重置时间未提供")
                .font(.system(size: 9))
                .foregroundStyle(.white.opacity(0.58))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Accepts SwiftUI button clicks without activating CodexHarbor or stealing focus
/// from an open ChatGPT conversation.
private final class NotchDetailPanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

@MainActor
final class NotchUsageCoordinator {
    private let model = NotchQuotaModel()
    private var leftPanel: NSPanel?
    private var rightPanel: NSPanel?
    private var detailPanel: NSPanel?
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var panelsVisible = false
    private var dismissTask: Task<Void, Never>?
    private var activeRefresh = false
    private var nextRefresh = Date.distantPast
    private var activeScreenID: String?
    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }

        // Use the same app identity as the macOS menu bar. Running in the
        // background is not sufficient: other apps must regain their full
        // left/right menu bar space immediately.
        let workspaceEvents = NSWorkspace.shared.notificationCenter
        activationObserver = workspaceEvents.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        deactivationObserver = workspaceEvents.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] notice in
            guard let app = notice.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                  Self.isChatGPTBundle(app.bundleIdentifier) else { return }
            Task { @MainActor in
                guard let self, !self.chatGPTIsFrontmost() else { return }
                self.closePanels()
            }
        }

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutPanels() }
        }

        poll()
        if preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
                app.stop(nil)
                // Stop's event is not always processed when no interactive event exists.
                app.terminate(nil)
            }
        }
        app.run()
    }

    nonisolated private static func isChatGPTBundle(_ identifier: String?) -> Bool {
        identifier == "com.openai.codex" || identifier == "com.openai.chatgpt"
    }

    private func chatGPTIsRunning() -> Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.codex").isEmpty ||
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.openai.chatgpt").isEmpty
    }

    private func chatGPTIsFrontmost() -> Bool {
        Self.isChatGPTBundle(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    private func poll() {
        if !preview {
            guard let config = UsageCardAgent.configuration(),
                  config.enabled, config.position == "notch" else {
                closePanels()
                NSApplication.shared.terminate(nil)
                return
            }
        }
        model.advanceDisplay()
        let running = chatGPTIsRunning()
        if running != model.hasChatGPT {
            model.hasChatGPT = running
            if !running {
                model.quota = nil
                model.lastReadFailed = false
                model.message = "正在读取额度"
                nextRefresh = .distantPast
                closePanels()
            }
        }
        guard running else {
            UsageCardAgent.report(state: "waiting-for-window",
                                  detail: "等待 ChatGPT 启动后显示刘海额度", snapshot: nil)
            return
        }

        // Do not show any notch panel while another app owns the menu bar.
        // Keep the most recent quota in memory for an instant return to ChatGPT.
        guard preview || chatGPTIsFrontmost() else {
            closePanels()
            UsageCardAgent.report(state: "hidden-in-background",
                                  detail: "ChatGPT 不是当前前台应用，刘海额度已隐藏",
                                  snapshot: model.quota)
            return
        }

        if leftPanel == nil || rightPanel == nil { createPanels() }
        if !panelsVisible {
            layoutPanels()
            leftPanel?.orderFrontRegardless()
            rightPanel?.orderFrontRegardless()
            panelsVisible = true
        }

        if Date() >= nextRefresh && !activeRefresh {
            nextRefresh = Date().addingTimeInterval(90)
            refresh()
        }

        UsageCardAgent.report(
            state: model.quota == nil
                ? (model.lastReadFailed ? "quota-unavailable" : "loading") : "visible",
            detail: model.quota == nil ? model.message
                : (model.isDelayed ? "使用最近一次有效额度，后台重试中" : "刘海左右两侧显示中"),
            snapshot: model.quota
        )
    }

    private func refresh() {
        activeRefresh = true
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try CodexQuotaReader.read(timeout: 25) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.activeRefresh = false
                guard self.model.hasChatGPT else { return }
                switch result {
                case .success(let quota):
                    self.model.quota = quota
                    self.model.lastReadFailed = false
                    self.model.message = "已更新"
                case .failure(let error):
                    fputs("Codex 额度读取失败：\(error.localizedDescription)\n", stderr)
                    self.model.lastReadFailed = true
                    if self.model.hasRecentQuota {
                        self.model.message = "读取暂时失败，显示最近一次有效额度并自动重试"
                    } else {
                        self.model.quota = nil
                        self.model.message = "暂时无法读取额度，正在自动重试"
                    }
                    self.nextRefresh = Date().addingTimeInterval(20)
                }
                self.layoutPanels()
            }
        }
    }

    private func createPanels() {
        let wingSize = NSSize(width: 96, height: 26)
        let left = createPanel(size: wingSize)
        let right = createPanel(size: wingSize)
        let detail = createPanel(size: NSSize(width: 300, height: model.detailHeight), interactive: true)
        left.contentView = NSHostingView(rootView: NotchWingView(model: model, isFiveHour: true) {
            [weak self] hover in self?.onHover(hover)
        })
        right.contentView = NSHostingView(rootView: NotchWingView(model: model, isFiveHour: false) {
            [weak self] hover in self?.onHover(hover)
        })
        detail.contentView = NSHostingView(rootView: NotchDetailWindow(
            model: model,
            hover: { [weak self] hovering in self?.onHover(hovering) }
        ))
        leftPanel = left
        rightPanel = right
        detailPanel = detail
        layoutPanels()
    }

    private func createPanel(size: NSSize, interactive: Bool = false) -> NSPanel {
        let rect = NSRect(origin: .zero, size: size)
        let panel: NSPanel = interactive
            ? NotchDetailPanel(
                contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            : NSPanel(
                contentRect: rect, styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    private func layoutPanels() {
        guard let leftPanel, let rightPanel, let detailPanel else { return }
        let screen = NSScreen.screens.first {
            $0.safeAreaInsets.top > 0 &&
            $0.auxiliaryTopLeftArea != nil &&
            $0.auxiliaryTopRightArea != nil
        } ?? NSScreen.main ?? NSScreen.screens.first
        guard let screen else { closePanels(); return }

        let gap: CGFloat = 7
        let wingWidth: CGFloat = 96
        let wingHeight: CGFloat = 26
        let topY = screen.frame.maxY - wingHeight - 3
        let notchPresent = screen.safeAreaInsets.top > 0 &&
            screen.auxiliaryTopLeftArea != nil && screen.auxiliaryTopRightArea != nil

        let leftX: CGFloat, rightX: CGFloat, wingY: CGFloat
        if notchPresent,
           let leftArea = screen.auxiliaryTopLeftArea,
           let rightArea = screen.auxiliaryTopRightArea,
           leftArea.width >= wingWidth + gap,
           rightArea.width >= wingWidth + gap {
            leftX = leftArea.maxX - wingWidth - gap
            rightX = rightArea.minX + gap
            wingY = leftArea.minY + (leftArea.height - wingHeight) / 2
        } else {
            // External monitors do not have a notch: remain unobtrusive below menu bar.
            leftX = screen.frame.midX - wingWidth - 8
            rightX = screen.frame.midX + 8
            wingY = screen.visibleFrame.maxY - wingHeight - 6
        }
        leftPanel.setFrameOrigin(NSPoint(x: leftX, y: wingY))
        rightPanel.setFrameOrigin(NSPoint(x: rightX, y: wingY))

        let desiredHeight = model.detailHeight
        if abs(detailPanel.frame.height - desiredHeight) > 1 {
            detailPanel.setContentSize(NSSize(width: 300, height: desiredHeight))
        }
        let detailWidth = detailPanel.frame.width
        let detailX = screen.frame.midX - detailWidth / 2
        let detailY = notchPresent ?
            screen.frame.maxY - screen.safeAreaInsets.top - detailPanel.frame.height - 8 :
            min(wingY, topY) - detailPanel.frame.height - 8
        detailPanel.setFrameOrigin(NSPoint(x: detailX, y: detailY))

        if preview {
            let leftFrame = leftPanel.frame, rightFrame = rightPanel.frame
            let signature = "\(Int(leftFrame.minX))|\(Int(rightFrame.minX))|\(Int(wingY))"
            if activeScreenID != signature {
                activeScreenID = signature
                print("notch-layout left=\(leftFrame), right=\(rightFrame), expanded=\(detailPanel.frame)")
                fflush(stdout)
            }
        }
    }

    private func onHover(_ hovering: Bool) {
        dismissTask?.cancel()
        if hovering {
            guard model.hasChatGPT, (preview || chatGPTIsFrontmost()) else { return }
            layoutPanels()
            detailPanel?.orderFrontRegardless()
        } else {
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(450))
                guard !Task.isCancelled, let self else { return }
                self.detailPanel?.orderOut(nil)
            }
        }
    }

    private func closePanels() {
        dismissTask?.cancel()
        guard panelsVisible || detailPanel?.isVisible == true else { return }
        leftPanel?.orderOut(nil)
        rightPanel?.orderOut(nil)
        detailPanel?.orderOut(nil)
        panelsVisible = false
    }
}
