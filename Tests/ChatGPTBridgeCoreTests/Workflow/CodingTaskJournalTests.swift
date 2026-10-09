import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Coding Task crash-safe journal")
struct CodingTaskJournalTests {
    @Test("Restart preserves task visibility but never replays interrupted work")
    func interruptedTask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CodingTaskJournal(directory: directory)
        let taskID = UUID()
        let workspaceID = UUID()
        let task = CodingTaskResponse(
            taskID: taskID,
            workspaceID: workspaceID,
            requirement: "Apply requested patch",
            state: .running,
            phase: .building,
            message: "Compiling",
            startedAt: Date(),
            finishedAt: nil,
            durationMilliseconds: 1000,
            repairAttempt: 0,
            maximumRepairAttempts: 2,
            appliedChanges: ["Sources/A.swift"],
            changedFiles: [],
            errors: [],
            currentCommandID: UUID(),
            steps: [],
            stdout: "private build output",
            stderr: "",
            stdoutOffset: 0,
            stderrOffset: 0,
            nextStdoutOffset: 0,
            nextStderrOffset: 0,
            stdoutHasMore: false,
            stderrHasMore: false
        )
        journal.save(task)
        let restored = try #require(CodingTaskJournal(directory: directory).restoredResponses().first)
        #expect(restored.taskID == taskID)
        #expect(restored.workspaceID == workspaceID)
        #expect(restored.state == .failed)
        #expect(restored.currentCommandID == nil)
        #expect(restored.stdout.isEmpty)
        #expect(restored.message.contains("nothing was automatically replayed"))
        let file = directory.appendingPathComponent(taskID.uuidString + ".json")
        let raw = try String(contentsOf: file, encoding: .utf8)
        #expect(!raw.contains("private build output"))
    }

    @Test("Successful tasks remain completed after restart")
    func completedTask() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("harbor-journal-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let journal = CodingTaskJournal(directory: directory)
        let date = Date()
        journal.save(CodingTaskResponse(
            taskID: UUID(),
            workspaceID: UUID(),
            requirement: "Test project",
            state: .completed,
            phase: .complete,
            message: "Passed",
            startedAt: date,
            finishedAt: date,
            durationMilliseconds: 0,
            repairAttempt: 0,
            maximumRepairAttempts: 1,
            appliedChanges: [],
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
        ))
        let restored = try #require(journal.restoredResponses().first)
        #expect(restored.state == .completed)
        #expect(restored.message == "Passed")
    }
}
