import Testing
@testable import CodexHarborCore

@Suite("Connection coordinator")
@MainActor
struct HarborConnectionCoordinatorTests {
    @Test func stopInvalidatesAlreadyDequeuedRequest() throws {
        let coordinator = HarborConnectionCoordinator()
        #expect(coordinator.enqueue("a", restart: false, userInitiated: true))
        let old = try #require(coordinator.takeNext())
        #expect(coordinator.accepts(old))
        coordinator.beginStop()
        #expect(!coordinator.enqueue("b", restart: false, userInitiated: true))
        #expect(!coordinator.accepts(old))
        coordinator.endStop()
        #expect(!coordinator.accepts(old))
        #expect(coordinator.enqueue("b", restart: false, userInitiated: true))
        let next = try #require(coordinator.takeNext())
        coordinator.finishRequest(old)
        #expect(coordinator.accepts(next))
    }

    @Test func explicitIntentWinsWhileWaiting() throws {
        let coordinator = HarborConnectionCoordinator()
        #expect(coordinator.enqueue("a", restart: true, userInitiated: true))
        let old = try #require(coordinator.takeNext())
        #expect(!coordinator.enqueue("background", restart: true, userInitiated: false))
        #expect(coordinator.enqueue("b", restart: true, userInitiated: true))
        #expect(!coordinator.accepts(old))
        coordinator.finishRequest(old)
        let next = try #require(coordinator.takeNext())
        #expect(coordinator.accepts(next))
        let transaction = try #require(coordinator.begin(nodeID: "b", endpointSignature: "b1",
            timeout: .seconds(30), source: .user))
        #expect(coordinator.accepts(transaction, endpointSignature: "b1"))
        #expect(!coordinator.enqueue("background", restart: true, userInitiated: false))
        #expect(!coordinator.accepts(transaction, endpointSignature: "b2"))
        coordinator.networkChanged()
        #expect(!coordinator.accepts(transaction, endpointSignature: "b1"))
        #expect(!coordinator.accepts(next))
    }
}
