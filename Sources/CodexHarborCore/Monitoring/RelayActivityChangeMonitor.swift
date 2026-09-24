import Darwin
import Foundation

/// Watches Relay's SQLite database for new activity without keeping a polling
/// timer hot. SQLite may write either the main database or its WAL sidecar, so
/// both files are observed and the parent directory is watched to re-arm file
/// descriptors when SQLite creates, checkpoints, or replaces sidecars.
public final class RelayActivityChangeMonitor: @unchecked Sendable {
    private struct FileSignature: Equatable {
        let size: UInt64
        let modificationTime: TimeInterval
    }

    private struct Fingerprint: Equatable {
        let database: FileSignature?
        let wal: FileSignature?
    }

    private let databaseURL: URL
    private let walURL: URL
    private let directoryURL: URL
    private let fileManager: FileManager
    private let queue = DispatchQueue(
        label: "com.codexharbor.relay-activity-change-monitor",
        qos: .utility
    )

    private var directorySource: DispatchSourceFileSystemObject?
    private var databaseSource: DispatchSourceFileSystemObject?
    private var walSource: DispatchSourceFileSystemObject?
    private var debounceWorkItem: DispatchWorkItem?
    private var callback: (@Sendable () -> Void)?
    private var lastFingerprint: Fingerprint
    private var started = false

    public init(
        paths: CodexPaths = .live(),
        fileManager: FileManager = .default
    ) {
        databaseURL = paths.relayEventsDatabaseURL
        walURL = URL(fileURLWithPath: paths.relayEventsDatabaseURL.path + "-wal")
        directoryURL = paths.relayEventsDatabaseURL.deletingLastPathComponent()
        self.fileManager = fileManager
        lastFingerprint = Self.fingerprint(
            databaseURL: paths.relayEventsDatabaseURL,
            walURL: URL(fileURLWithPath: paths.relayEventsDatabaseURL.path + "-wal"),
            fileManager: fileManager
        )
    }

    public func start(onChange: @escaping @Sendable () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            self.callback = onChange
            guard !self.started else { return }
            self.started = true
            try? self.fileManager.createDirectory(
                at: self.directoryURL,
                withIntermediateDirectories: true
            )
            self.lastFingerprint = Self.fingerprint(
                databaseURL: self.databaseURL,
                walURL: self.walURL,
                fileManager: self.fileManager
            )
            self.installDirectoryWatcher()
            self.installFileWatchers()
        }
    }

    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.started = false
            self.callback = nil
            self.debounceWorkItem?.cancel()
            self.debounceWorkItem = nil
            self.cancelFileWatchers()
            self.directorySource?.cancel()
            self.directorySource = nil
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
            self.scheduleEvaluation(
                rearmDirectory: flags.contains(.rename) || flags.contains(.delete)
            )
        }
        source.setCancelHandler {
            close(descriptor)
        }
        directorySource = source
        source.resume()
    }

    private func installFileWatchers() {
        guard started else { return }
        cancelFileWatchers()
        databaseSource = makeWatcher(for: databaseURL)
        walSource = makeWatcher(for: walURL)
    }

    private func makeWatcher(for url: URL) -> DispatchSourceFileSystemObject? {
        let descriptor = open(url.path, O_EVTONLY)
        guard descriptor >= 0 else { return nil }

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
        source.resume()
        return source
    }

    private func cancelFileWatchers() {
        databaseSource?.cancel()
        databaseSource = nil
        walSource?.cancel()
        walSource = nil
    }

    private func scheduleEvaluation(rearmDirectory: Bool) {
        debounceWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, self.started else { return }

            let latest = Self.fingerprint(
                databaseURL: self.databaseURL,
                walURL: self.walURL,
                fileManager: self.fileManager
            )
            let changed = latest != self.lastFingerprint
            self.lastFingerprint = latest

            if rearmDirectory {
                self.directorySource?.cancel()
                self.directorySource = nil
                self.installDirectoryWatcher()
            }
            self.installFileWatchers()

            if changed {
                self.callback?()
            }
        }
        debounceWorkItem = workItem
        queue.asyncAfter(deadline: .now() + .milliseconds(120), execute: workItem)
    }

    private static func fingerprint(
        databaseURL: URL,
        walURL: URL,
        fileManager: FileManager
    ) -> Fingerprint {
        Fingerprint(
            database: signature(of: databaseURL, fileManager: fileManager),
            wal: signature(of: walURL, fileManager: fileManager)
        )
    }

    private static func signature(
        of url: URL,
        fileManager: FileManager
    ) -> FileSignature? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value,
              let modificationDate = attributes[.modificationDate] as? Date else {
            return nil
        }
        return FileSignature(
            size: size,
            modificationTime: modificationDate.timeIntervalSinceReferenceDate
        )
    }
}
