import Darwin
import Foundation

/// Receives approval-file changes without tying UI authorization prompts to
/// the five-minute connection health check or a high-frequency polling timer.
public final class BridgeApprovalChangeMonitor: @unchecked Sendable {
    private let directory: URL
    private let queue = DispatchQueue(
        label: "com.codexharbor.bridge.approval-change-monitor",
        qos: .utility
    )
    private var source: DispatchSourceFileSystemObject?
    private var pendingNotification: DispatchWorkItem?
    private var callback: (@Sendable () -> Void)?
    private var started = false

    public init(paths: BridgePaths) {
        directory = paths.root.appendingPathComponent("approvals", isDirectory: true)
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        // Arm the watcher before the caller loads the initial pending list,
        // so a request arriving during startup cannot be lost.
        queue.sync {
            callback = onChange
            guard !started else { return }
            started = true
            installWatcher()
        }
    }

    public func stop() {
        queue.sync {
            started = false
            callback = nil
            pendingNotification?.cancel()
            pendingNotification = nil
            source?.cancel()
            source = nil
        }
    }

    private func installWatcher() {
        guard started, source == nil else { return }
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true
        )
        let descriptor = open(directory.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let watcher = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .revoke],
            queue: queue
        )
        watcher.setEventHandler { [weak self, weak watcher] in
            guard let self, self.started else { return }
            let flags = watcher?.data ?? []
            if !flags.intersection([.rename, .delete, .revoke]).isEmpty {
                self.source?.cancel()
                self.source = nil
                self.installWatcher()
            }
            self.scheduleNotification()
        }
        watcher.setCancelHandler { close(descriptor) }
        source = watcher
        watcher.resume()
    }

    private func scheduleNotification() {
        pendingNotification?.cancel()
        let item = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }
            self.callback?()
        }
        pendingNotification = item
        queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: item)
    }
}
