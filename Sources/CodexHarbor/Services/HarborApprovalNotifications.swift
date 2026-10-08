import AppKit
import ChatGPTBridgeCore
import SwiftUI

/// One floating approval panel for every pending local tool call.
///
/// A non-activating NSPanel remains in front of other applications without
/// requiring the user to bring Codex Harbor's main window to the foreground.
/// Approvals remain one-shot decisions in BridgeApprovalStore.
@MainActor
final class HarborApprovalPanelController {
    static let shared = HarborApprovalPanelController()

    private var paths: BridgePaths?
    private var monitor: BridgeApprovalChangeMonitor?
    private var panel: NSPanel?
    private var showingRequestID: String?
    private var expirationTask: Task<Void, Never>?

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

        panel.contentView = NSHostingView(
            rootView: HarborToolApprovalDialog(
                request: request,
                onDeny: { [weak self] in self?.decide(request.id, allow: false) },
                onAllow: { [weak self] in self?.decide(request.id, allow: true) },
                onRemember: { [weak self] in self?.decide(request.id, allow: true, remember: true) ?? false }
            )
        )
        panel.setContentSize(NSSize(width: 520, height: 340))
        panel.center()
        panel.orderFrontRegardless()
        panel.makeKey()
        expirationTask?.cancel()
        expirationTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(max(0, request.deadline.timeIntervalSinceNow)))
            guard !Task.isCancelled else { return }
            self?.refresh()
        }
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

        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 340),
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
        panel.hidesOnDeactivate = false
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.backgroundColor = .windowBackgroundColor
        self.panel = panel
        return panel
    }
}
