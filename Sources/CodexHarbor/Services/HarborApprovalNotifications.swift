import AppKit
import ChatGPTBridgeCore
import SwiftUI

/// One floating approval panel for every pending local tool call.
///
/// A single floating NSPanel acquires focus when user confirmation is
/// required, even if Codex Harbor is behind another application.
/// Approvals remain one-shot decisions in BridgeApprovalStore.
@MainActor
final class HarborApprovalPanelController {
    static let shared = HarborApprovalPanelController()

    private var paths: BridgePaths?
    private var monitor: BridgeApprovalChangeMonitor?
    private var panel: NSPanel?
    private var showingRequestID: String?
    private var expirationTask: Task<Void, Never>?
    private var fallbackTask: Task<Void, Never>?

    private init() {}

    func start() {
        guard paths == nil, let resolvedPaths = try? BridgePaths.live() else { return }
        paths = resolvedPaths

        let monitor = BridgeApprovalChangeMonitor(paths: resolvedPaths)
        self.monitor = monitor
        monitor.start { [weak self] in
            Task { @MainActor [weak self] in
                self?.refresh()
            }
        }
        refresh()
        // A rare missed filesystem event must not keep a 90-second approval
        // invisible. Only one low-frequency task runs for the app lifetime.
        // This also rechecks pending requests after display sleep/wake.
        if fallbackTask == nil {
            fallbackTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(2))
                    guard !Task.isCancelled, let self else { break }
                    self.refresh()
                }
            }
        }
    }

    private func refresh() {
        guard let paths else { return }
        let pending = BridgeApprovalStore(paths: paths).pendingRequests()
        // Serve oldest pending request first. There is never more than one
        // approval window, even when several MCP tool calls arrive together.
        guard let request = pending.last else {
            showingRequestID = nil
            expirationTask?.cancel()
            panel?.orderOut(nil)
            return
        }

        if showingRequestID != request.id {
            showingRequestID = request.id
            show(request)
        } else if panel?.isVisible != true {
            panel?.orderFrontRegardless()
        }
    }

    private func show(_ request: BridgeApprovalRequest) {
        let panel = makePanelIfNeeded()

        if let capability = HarborUIAuthorization.capability(forTool: request.tool) {
            let hosting = NSHostingView(rootView: HarborUIAppApprovalDialog(
                request: request, capability: capability,
                onDeny: { [weak self] in self?.decide(request.id, allow: false) },
                onAllow: { [weak self] in self?.approveUI(request) ?? false }
            ))
            fitPanel(panel, to: hosting, width: HarborUIAppApprovalDialog.panelSize.width)
        } else {
            let hosting = NSHostingView(rootView: HarborToolApprovalDialog(
                request: request,
                onDeny: { [weak self] in self?.decide(request.id, allow: false) },
                onAllow: { [weak self] in self?.decide(request.id, allow: true) },
                onRemember: { [weak self] in self?.decide(request.id, allow: true, remember: true) ?? false }
            ))
            fitPanel(panel, to: hosting, width: HarborToolApprovalDialog.panelSize.width)
        }
        panel.center()
        // Focus only this panel. Activating/unhiding NSApp also brings the
        // main workspace window forward, interrupting the user's other app.
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, request.deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
    }

    /// Never impose a constant panel height: both authorization dialogs have
    /// dynamic copy, so the window must hug the last row of buttons.
    private func fitPanel<Content: View>(
        _ panel: NSPanel, to hosting: NSHostingView<Content>, width: CGFloat
    ) {
        panel.contentView = hosting
        let naturalHeight = hosting.fittingSize.height
        // A detached hosting view can report a provisional zero size; never
        // collapse the panel in that case.
        panel.setContentSize(NSSize(
            width: width, height: naturalHeight > 120 ? ceil(naturalHeight) : 280
        ))
    }

    /// Only this local, human-clicked panel can persist a UI app grant.
    /// MCP approval does not itself confer permission: ToolRouter rechecks
    /// the capability and bundle ID after this decision is consumed.
    private func approveUI(_ request: BridgeApprovalRequest) -> Bool {
        guard let paths, request.id == showingRequestID,
              request.deadline > Date(),
              let bundleID = request.target,
              HarborUIAuthorization.isValidTarget(bundleID),
              let capability = HarborUIAuthorization.capability(forTool: request.tool),
              BridgeApprovalStore(paths: paths).pendingRequests().contains(where: { $0.id == request.id })
        else { return false }

        let store = HarborUIConsentStore(paths: paths)
        let previous = store.grants().first(where: { $0.bundleID == bundleID })
        do {
            try store.save(HarborUIAppGrant(
                bundleID: bundleID,
                canRead: true,
                canControl: (previous?.canControl == true) || capability == .control,
                canCapture: (previous?.canCapture == true) || capability == .capture
            ))
            let approved = BridgeApprovalStore(paths: paths).decide(id: request.id, allow: true)
            guard approved else {
                if let previous { try store.save(previous) }
                else { try store.revoke(bundleID: bundleID) }
                return false
            }
            refresh()
            return true
        } catch { return false }
    }

    @discardableResult
    private func decide(_ id: String, allow: Bool, remember: Bool = false) -> Bool {
        guard let paths, id == showingRequestID else { return false }
        let saved = BridgeApprovalStore(paths: paths).decide(id: id, allow: allow, remember: remember)
        // Immediately advance to the next queued request (if any).
        refresh()
        return saved
    }

    private func makePanelIfNeeded() -> NSPanel {
        if let panel { return panel }

        let panel = HarborApprovalPanel(
            contentRect: NSRect(origin: .zero, size: HarborToolApprovalDialog.panelSize),
            styleMask: [.titled, .fullSizeContentView, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.title = "本地操作授权"
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        self.panel = panel
        return panel
    }
}

private final class HarborApprovalPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
