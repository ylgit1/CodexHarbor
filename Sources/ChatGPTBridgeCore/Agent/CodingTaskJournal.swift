import Foundation

/// Small durable metadata snapshots, intentionally excluding command output,
/// API credentials, arguments and patch contents. A crashed Agent must never
/// replay an unfinished write, build, or git action on its own.
public final class CodingTaskJournal: @unchecked Sendable {
    private struct Entry: Codable {
        var taskID: UUID
        var workspaceID: UUID
        var requirement: String
        var state: CodingTaskState
        var phase: CodingTaskPhase
        var message: String
        var startedAt: Date
        var finishedAt: Date?
        var repairAttempt: Int
        var maximumRepairAttempts: Int
        var appliedChanges: [String]
    }

    private let directory: URL
    private let lock = NSLock()

    public init(directory: URL) {
        self.directory = directory
        try? FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    public func save(_ response: CodingTaskResponse) {
        let record = Entry(
            taskID: response.taskID,
            workspaceID: response.workspaceID,
            requirement: response.requirement,
            state: response.state,
            phase: response.phase,
            message: response.message,
            startedAt: response.startedAt,
            finishedAt: response.finishedAt,
            repairAttempt: response.repairAttempt,
            maximumRepairAttempts: response.maximumRepairAttempts,
            appliedChanges: response.appliedChanges
        )
        lock.lock()
        defer { lock.unlock() }
        guard let data = try? JSONEncoder().encode(record) else { return }
        let url = directory.appendingPathComponent(record.taskID.uuidString + ".json")
        do {
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: url.path
            )
        } catch {
            NSLog("Harbor: failed to persist task state: %@", error.localizedDescription)
        }
    }

    public func restoredResponses() -> [CodingTaskResponse] {
        lock.lock()
        defer { lock.unlock() }
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return files.compactMap { url -> CodingTaskResponse? in
            guard let data = try? Data(contentsOf: url),
                  let entry = try? JSONDecoder().decode(Entry.self, from: data),
                  Date().timeIntervalSince(entry.startedAt) < 7 * 24 * 3600 else { return nil }
            let interrupted = [.planned, .running, .needsRepair].contains(entry.state)
            let state: CodingTaskState = interrupted ? .failed : entry.state
            let finishedAt = interrupted ? Date() : entry.finishedAt
            return CodingTaskResponse(
                taskID: entry.taskID,
                workspaceID: entry.workspaceID,
                requirement: entry.requirement,
                state: state,
                phase: interrupted ? .complete : entry.phase,
                message: interrupted
                    ? "Agent was restarted during this task. Inspect Git diff and start a new task; nothing was automatically replayed."
                    : entry.message,
                startedAt: entry.startedAt,
                finishedAt: finishedAt,
                durationMilliseconds: max(0, Int((finishedAt ?? Date()).timeIntervalSince(entry.startedAt) * 1000)),
                repairAttempt: entry.repairAttempt,
                maximumRepairAttempts: entry.maximumRepairAttempts,
                appliedChanges: entry.appliedChanges,
                changedFiles: [],
                errors: [],
                currentCommandID: nil,
                steps: [],
                stdout: "",
                stderr: "",
                stdoutOffset: 0,
                stderrOffset: 0,
                nextStdoutOffset: 0,
                nextStderrOffset: 0,
                stdoutHasMore: false,
                stderrHasMore: false
            )
        }
        .sorted { $0.startedAt > $1.startedAt }
        .prefix(20)
        .map { $0 }
    }
}
