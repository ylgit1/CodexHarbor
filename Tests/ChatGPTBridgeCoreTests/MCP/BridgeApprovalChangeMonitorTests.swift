import Dispatch
import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("Bridge approval changes")
struct BridgeApprovalChangeMonitorTests {
    @Test("New authorization appears without waiting for health polling")
    func detectsPendingRequest() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborApprovals-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let paths = BridgePaths(root: root)
        let changed = DispatchSemaphore(value: 0)
        let monitor = BridgeApprovalChangeMonitor(paths: paths)
        monitor.start { changed.signal() }
        defer { monitor.stop() }

        let store = BridgeApprovalStore(paths: paths)
        store.request(
            id: "sample-request",
            tool: "run_command",
            summary: "Check local project"
        )
        #expect(changed.wait(timeout: .now() + .seconds(3)) == .success)
        #expect(store.pendingRequests().map(\.id) == ["sample-request"])
    }

    @Test("Timed-out operation clears its approval and cannot be allowed later")
    func timedOutRequestIsRemoved() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborTimedOutApproval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = BridgeApprovalStore(paths: BridgePaths(root: root))
        store.request(id: "timed-out", tool: "run_command", summary: "Command")
        let decision = await store.waitForDecision(id: "timed-out", timeout: 0.01)
        #expect(decision == nil)
        #expect(store.pendingRequests().isEmpty)
        store.decide(id: "timed-out", allow: true)
        #expect(store.consumeDecision(id: "timed-out") == nil)
    }

    @Test("An approval older than 90 seconds cannot be granted")
    func expiredRequestIsNotApprovable() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("HarborExpiredApproval-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = BridgePaths(root: root)
        let store = BridgeApprovalStore(paths: paths)
        store.request(id: "stale", tool: "run_command", summary: "Old command")
        let file = root.appendingPathComponent("approvals/stale.json")
        var request = try JSONDecoder.iso8601().decode(
            BridgeApprovalRequest.self, from: Data(contentsOf: file)
        )
        request = BridgeApprovalRequest(
            id: request.id,
            tool: request.tool,
            summary: request.summary,
            createdAt: Date().addingTimeInterval(-95)
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        try encoder.encode(request).write(to: file, options: .atomic)
        store.decide(id: "stale", allow: true)
        #expect(store.consumeDecision(id: "stale") == nil)
        #expect(store.pendingRequests().isEmpty)
    }
}

private extension JSONDecoder {
    static func iso8601() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
