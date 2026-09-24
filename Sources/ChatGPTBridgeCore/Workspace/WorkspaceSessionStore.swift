import Foundation

public struct WorkspaceSessionRecord: Codable, Equatable, Sendable {
    public let sessionID: String
    public let workspaceID: UUID
    public let rootPath: String
    public let updatedAt: Date

    public init(sessionID: String, workspace: BridgeWorkspace, updatedAt: Date = Date()) {
        self.sessionID = sessionID
        self.workspaceID = workspace.id
        self.rootPath = workspace.rootPath
        self.updatedAt = updatedAt
    }
}

private struct WorkspaceSessionSnapshot: Codable, Sendable {
    var sessions: [String: WorkspaceSessionRecord]
    var lastWorkspaceID: UUID?
}

public actor WorkspaceSessionStore {
    private let persistenceURL: URL?
    private var sessions: [String: WorkspaceSessionRecord]
    private var lastWorkspaceID: UUID?

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let persistenceURL,
           let data = try? Data(contentsOf: persistenceURL),
           let snapshot = try? decoder.decode(WorkspaceSessionSnapshot.self, from: data) {
            sessions = snapshot.sessions
            lastWorkspaceID = snapshot.lastWorkspaceID
        } else {
            sessions = [:]
            lastWorkspaceID = nil
        }
    }

    public func bind(sessionID: String?, workspace: BridgeWorkspace) {
        lastWorkspaceID = workspace.id
        if let sessionID = Self.normalized(sessionID) {
            sessions[sessionID] = WorkspaceSessionRecord(sessionID: sessionID, workspace: workspace)
        }
        persist()
    }

    public func resolve(sessionID: String?) -> UUID? {
        if let sessionID = Self.normalized(sessionID),
           let workspaceID = sessions[sessionID]?.workspaceID {
            return workspaceID
        }
        return lastWorkspaceID
    }

    public func invalidate(workspaceID: UUID) {
        sessions = sessions.filter { $0.value.workspaceID != workspaceID }
        if lastWorkspaceID == workspaceID { lastWorkspaceID = nil }
        persist()
    }

    public func records() -> [WorkspaceSessionRecord] {
        sessions.values.sorted { $0.updatedAt > $1.updatedAt }
    }

    private static func normalized(_ sessionID: String?) -> String? {
        guard let sessionID else { return nil }
        let value = sessionID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value.utf8.count <= 512 else { return nil }
        return value
    }

    private func persist() {
        guard let persistenceURL else { return }
        let snapshot = WorkspaceSessionSnapshot(sessions: sessions, lastWorkspaceID: lastWorkspaceID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try FileManager.default.createDirectory(
                at: persistenceURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try encoder.encode(snapshot).write(to: persistenceURL, options: .atomic)
        } catch {
            // Session persistence is best-effort; the active in-memory binding remains valid.
        }
    }
}
