import AppKit
import Foundation
import QuartzCore
import SwiftUI
import CodexHarborCore

/// A single nonactivating panel morphs from a compact, notch-connected status
/// bar into a detail island. It does not inspect or modify the ChatGPT UI.
@MainActor
final class NotchUsageCoordinator {
    private let model = NotchQuotaModel()
    private let compactHeight: CGFloat = 32
    private let expandedHeight: CGFloat = 256

    private var islandPanel: NSPanel?
    private var panelsVisible = false
    private var pollTimer: Timer?
    private var activationObserver: NSObjectProtocol?
    private var deactivationObserver: NSObjectProtocol?
    private var screenObserver: NSObjectProtocol?
    private var expandTask: Task<Void, Never>?
    private var dismissTask: Task<Void, Never>?
    private var refreshActive = false
    private var nextRefresh = Date.distantPast

    private var lastReportedState = ""
    private var lastReportedDetail = ""
    private var lastReportedSnapshot: CodexQuotaSnapshot?
    private var lastReportAt = Date.distantPast

    private let preview: Bool

    init(preview: Bool = false) {
        self.preview = preview
        if preview {
            // Synthetic values strictly for a short-lived local layout preview.
            let now = Date()
            model.quota = CodexQuotaSnapshot(
                fiveHours: CodexQuotaWindow(
                    durationMinutes: 300, usedPercent: 28,
                    resetDate: now.addingTimeInterval(2 * 3600 + 34 * 60)
                ),
                weekly: CodexQuotaWindow(
                    durationMinutes: 10_080, usedPercent: 31,
                    resetDate: now.addingTimeInterval(3 * 86_400 + 14 * 3600)
                ),
                capturedAt: now,
                planType: "plus",
                resetCreditsAvailable: 2
            )
        }
    }

    func run() {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)

        // Foreground notifications handle app switching immediately. This
        // low-frequency timer merely acts as a recovery path and counts down.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 4.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        if let pollTimer { RunLoop.main.add(pollTimer, forMode: .common) }

        let center = NSWorkspace.shared.notificationCenter
        activationObserver = center.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
        deactivationObserver = center.addObserver(
            forName: NSWorkspace.didDeactivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notice in
            guard let application = notice.userInfo?[NSWorkspace.applicationUserInfoKey]
                    as? NSRunningApplication,
                  Self.isChatGPTBundle(application.bundleIdentifier) else { return }
            Task { @MainActor in
                guard let self, !self.chatGPTIsFrontmost() else { return }
                self.closePanel()
            }
        }
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.layoutPanel(animated: false) }
        }

        poll()

        if preview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                self?.setExpanded(true, animated: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.5) { [weak self] in
                self?.setExpanded(false, animated: true)
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 9) {
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
                  config.enabled,
                  config.position == "notch" else {
                closePanel()
                NSApplication.shared.terminate(nil)
                return
            }
        }

        model.advanceDisplay()
        let running = preview || chatGPTIsRunning()
        if running != model.hasChatGPT {
            model.hasChatGPT = running
            if !running {
                model.quota = nil
                model.message = "正在读取额度"
                model.lastReadFailed = false
                nextRefresh = .distantPast
                closePanel()
            }
        }

        guard running else {
            report("waiting-for-window", "等待 ChatGPT 启动后显示刘海额度", nil)
            return
        }
        guard preview || chatGPTIsFrontmost() else {
            closePanel()
            report("hidden-in-background", "切回 ChatGPT 后恢复刘海额度显示", model.quota)
            return
        }

        if islandPanel == nil { createPanel() }
        if !panelsVisible {
            layoutPanel(animated: false)
            islandPanel?.orderFrontRegardless()
            panelsVisible = true
        }

        if !preview && Date() >= nextRefresh && !refreshActive {
            nextRefresh = Date().addingTimeInterval(90)
            refresh()
        }

        if !preview {
            let state = model.quota == nil
                ? (model.lastReadFailed ? "quota-unavailable" : "loading") : "visible"
            let detail = model.quota == nil ? model.message :
                (model.isDelayed ? "显示最近一次有效额度，后台重试中" : "刘海灵动岛显示中")
            report(state, detail, model.quota)
        }
    }

    private func report(
        _ state: String, _ detail: String, _ snapshot: CodexQuotaSnapshot?
    ) {
        guard !preview else { return }
        let now = Date()
        guard state != lastReportedState ||
              detail != lastReportedDetail ||
              snapshot != lastReportedSnapshot ||
              now.timeIntervalSince(lastReportAt) >= 30 else { return }

        UsageCardAgent.report(state: state, detail: detail, snapshot: snapshot)
        lastReportedState = state
        lastReportedDetail = detail
        lastReportedSnapshot = snapshot
        lastReportAt = now
    }

    private func refresh() {
        refreshActive = true
        Task.detached(priority: .utility) { [weak self] in
            let result = Result { try CodexQuotaReader.read(timeout: 25) }
            await MainActor.run { [weak self] in
                guard let self else { return }
                self.refreshActive = false
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
                        self.model.message = "读取暂时失败，显示最近一次额度并自动重试"
                    } else {
                        self.model.quota = nil
                        self.model.message = "暂时无法读取额度，正在重试"
                    }
                    self.nextRefresh = Date().addingTimeInterval(20)
                }
            }
        }
    }

    private func createPanel() {
        let initialFrame = NSRect(
            x: 0, y: 0,
            width: model.notchWidth + 2 * model.wingWidth,
            height: compactHeight
        )
        let panel = NSPanel(
            contentRect: initialFrame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.level = .statusBar
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        let hostingView = NSHostingView(
            rootView: NotchIslandView(
                model: model,
                compactHeight: compactHeight,
                expandedHeight: expandedHeight,
                hover: { [weak self] hovered in self?.onHover(hovered) }
            )
        )
        // Window geometry is owned solely by AppKit. Prevent SwiftUI's
        // intrinsic height from forcing a second resize during expansion.
        hostingView.sizingOptions = []
        hostingView.autoresizingMask = [.width, .height]
        panel.contentView = hostingView
        islandPanel = panel
        layoutPanel(animated: false)
    }

    /// Locate the actual physical camera gap rather than assuming a pixel
    /// position. The left/right wing borders touch its respective edges.
    private func layoutPanel(animated: Bool) {
        guard let panel = islandPanel else { return }
        let notchedScreen = NSScreen.screens.first {
            $0.safeAreaInsets.top > 0 &&
            $0.auxiliaryTopLeftArea != nil &&
            $0.auxiliaryTopRightArea != nil
        }
        guard let screen = notchedScreen ?? NSScreen.main ?? NSScreen.screens.first else {
            closePanel()
            return
        }

        let x: CGFloat
        let topY: CGFloat
        let wingWidth: CGFloat
        let gapWidth: CGFloat

        if let leftArea = notchedScreen?.auxiliaryTopLeftArea,
           let rightArea = notchedScreen?.auxiliaryTopRightArea,
           rightArea.minX > leftArea.maxX {
            gapWidth = rightArea.minX - leftArea.maxX
            wingWidth = min(104, max(70, min(leftArea.width, rightArea.width) - 12))
            x = leftArea.maxX - wingWidth
            topY = screen.frame.maxY
        } else {
            // Without a physical notch, use a centered compact island below
            // the menu bar instead of covering other applications' menus.
            gapWidth = 42
            wingWidth = 104
            x = screen.frame.midX - (gapWidth + wingWidth * 2) / 2
            topY = screen.visibleFrame.maxY
        }

        if model.wingWidth != wingWidth { model.wingWidth = wingWidth }
        if model.notchWidth != gapWidth { model.notchWidth = gapWidth }

        let height = model.expanded ? expandedHeight : compactHeight
        let target = NSRect(
            x: x,
            y: topY - height,
            width: 2 * wingWidth + gapWidth,
            height: height
        )
        guard panel.frame != target else { return }

        if animated && panelsVisible {
            // A single AppKit animation changes window height while keeping
            // its top edge fixed. SwiftUI only clips pre-laid-out contents.
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.26
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(target, display: true)
            }
        } else {
            panel.setFrame(target, display: true)
        }

        if preview {
            print(
                "notch-island \(model.expanded ? "expanded" : "compact") " +
                "frame=\(target), physicalGap=\(gapWidth), wing=\(wingWidth)"
            )
            fflush(stdout)
        }
    }

    private func setExpanded(_ expanded: Bool, animated: Bool) {
        guard islandPanel != nil, panelsVisible || preview else { return }
        guard model.expanded != expanded else { return }
        // Never animate the same transition twice (AppKit and SwiftUI).
        // Only AppKit interpolates height and origin; the SwiftUI hierarchy
        // remains in place to avoid layout hops and flicker.
        model.expanded = expanded
        layoutPanel(animated: animated)
    }

    /// The cursor is evaluated in screen coordinates, not a SwiftUI hover
    /// event emitted while the island's frame is being animated. Checking
    /// the actual panel frame avoids repeated open/close cycles.
    private func pointerInsidePanel() -> Bool {
        guard let panel = islandPanel, panel.isVisible else { return false }
        return panel.frame.insetBy(dx: -3, dy: -3).contains(NSEvent.mouseLocation)
    }

    private func onHover(_ hovered: Bool) {
        expandTask?.cancel()
        dismissTask?.cancel()
        guard preview || (model.hasChatGPT && chatGPTIsFrontmost()) else {
            closePanel()
            return
        }

        if hovered {
            guard !model.expanded else { return }
            expandTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(115))
                guard !Task.isCancelled, let self,
                      self.preview || self.chatGPTIsFrontmost(),
                      self.pointerInsidePanel() else { return }
                self.setExpanded(true, animated: true)
            }
        } else {
            guard model.expanded else { return }
            dismissTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(380))
                guard !Task.isCancelled, let self,
                      !self.pointerInsidePanel() else { return }
                self.setExpanded(false, animated: true)
            }
        }
    }

    private func closePanel() {
        expandTask?.cancel()
        dismissTask?.cancel()
        guard panelsVisible || islandPanel?.isVisible == true else { return }
        islandPanel?.orderOut(nil)
        panelsVisible = false
        model.expanded = false
        layoutPanel(animated: false)
    }
}
