import CryptoKit
import Darwin
import Foundation

/// Watches Codex's auth.json without keeping a polling timer hot.
///
/// Codex writes auth.json atomically, so the monitor watches both the file and
/// its parent directory. Directory events let it re-arm the file descriptor
/// after a replace/rename, while a digest check filters unrelated .codex
/// changes before notifying the app.
public final class CodexAuthenticationChangeMonitor: @unchecked Sendable {
    private let authURL: URL
    private let directoryURL: URL
    private let queue = DispatchQueue(
        label: "com.codexharbor.authentication-change-monitor",
        qos: .utility
    )

    private var directorySource: DispatchSourceFileSystemObject?
    private var fileSource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var callback: (@Sendable () -> Void)?
    private var lastDigest: String?
    private var started = false

    public init(paths: CodexPaths = .live()) {
        authURL = paths.authURL
        directoryURL = paths.authURL.deletingLastPathComponent()
        lastDigest = Self.digest(of: paths.authURL)
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.callback = onChange
            guard !self.started else { return }
            self.started = true
            self.lastDigest = Self.digest(of: self.authURL)
            self.installDirectoryWatcher()
            self.installFileWatcher()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.callback = nil
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.directorySource?.cancel()
            self.directorySource = nil
            self.fileSource?.cancel()
            self.fileSource = nil
        }
    }

    private func installDirectoryWatcher() {
        guard started, directorySource == nil else { return }
        let descriptor = open(directoryURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .rename, .delete, .attrib],
            queue: queue
        )
        source.setEventHandler { [weak self, weak source] in
            guard let self else { return }
            let flags = source?.data ?? []
            self.scheduleEvaluation(rearmDirectory: flags.contains(.rename) || flags.contains(.delete))
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func installFileWatcher() {
        guard started else { return }

        fileSource?.cancel()
        fileSource = nil

        let descriptor = open(authURL.path, O_EVTONLY)
        guard descriptor >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: descriptor,
            eventMask: [.write, .extend, .attrib, .rename, .delete, .revoke],
            queue: queue
        )
        source.setEventHandler { [weak self] in
            self?.scheduleEvaluation(rearmDirectory: false)
        }
        source.setCancelHandler {
            close(descriptor)
        }
        fileSource = source
        source.resume()
    }

    private func scheduleEvaluation(rearmDirectory: Bool) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }

            let latestDigest = Self.digest(of: self.authURL)
            let changed = latestDigest != self.lastDigest
            self.lastDigest = latestDigest

            if rearmDirectory {
                self.directorySource?.cancel()
                self.directorySource = nil
                self.installDirectoryWatcher()
            }
            self.installFileWatcher()

            // Match the existing polling semantics: a missing auth.json is not
            // treated as a newly authenticated account. If it reappears with
            // different credentials, the new digest triggers immediately.
            if changed, latestDigest != nil {
                self.callback?()
            }
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: workItem)
    }

    private static func digest(of url: URL) -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return SHA256.hash(data: data)
            .map { String(format: "%02x", $0) }
            .joined()
    }
}
