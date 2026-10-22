import Foundation

public struct ConnectionActivityStore {
    /// Increase the bounded local history so active users do not silently
    /// lose most of their monthly statistics after 1,000 events.
    public static let maximumRetainedEvents = 5_000
    private let paths: CodexPaths
    private let fileManager: FileManager

    public init(
        paths: CodexPaths = .live(),
        fileManager: FileManager = .default
    ) {
        self.paths = paths
        self.fileManager = fileManager
    }

    public func load() throws -> [ConnectionActivityEvent] {
        guard fileManager.fileExists(atPath: paths.activityEventsURL.path) else { return [] }
        return try JSONDecoder().decode(
            [ConnectionActivityEvent].self,
            from: Data(contentsOf: paths.activityEventsURL)
        )
    }

    public func append(
        _ event: ConnectionActivityEvent,
        to existingEvents: [ConnectionActivityEvent],
        now: Date = Date()
    ) throws -> [ConnectionActivityEvent] {
        try append(contentsOf: [event], to: existingEvents, now: now)
    }

    public func append(
        contentsOf newEvents: [ConnectionActivityEvent],
        to existingEvents: [ConnectionActivityEvent],
        now: Date = Date()
    ) throws -> [ConnectionActivityEvent] {
        guard !newEvents.isEmpty else { return existingEvents }
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let trimmed = (existingEvents + newEvents)
            .filter { $0.timestamp >= cutoff }
            .suffix(Self.maximumRetainedEvents)
        let events = Array(trimmed)
        try persist(events)
        return events
    }

    public func persist(_ events: [ConnectionActivityEvent]) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        // Keep the rolling journal compact; it may be written after every
        // finished request, and pretty-printed JSON adds avoidable I/O.
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(events)
        try data.write(to: paths.activityEventsURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.activityEventsURL.path)
    }
}
