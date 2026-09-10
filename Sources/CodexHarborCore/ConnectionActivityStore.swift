import Foundation

public struct ConnectionActivityStore {
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
        let cutoff = now.addingTimeInterval(-30 * 24 * 60 * 60)
        let trimmed = (existingEvents + [event])
            .filter { $0.timestamp >= cutoff }
            .suffix(1000)
        let events = Array(trimmed)
        try persist(events)
        return events
    }

    public func persist(_ events: [ConnectionActivityEvent]) throws {
        try fileManager.createDirectory(at: paths.appSupport, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(events)
        try data.write(to: paths.activityEventsURL, options: .atomic)
        try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: paths.activityEventsURL.path)
    }
}
