import Testing
import HarborProxyTestSupport

@Suite("Fixed gateway integration", .serialized)
struct HarborGatewayIntegrationTests {
    @Test func switchesOneHundredTimesWithoutReplacingEntry() async throws {
        try await HarborGatewayChecks().switchesOneHundredTimesWithoutReplacingEntry()
    }

    @Test func udpAssociationAndRelease() async throws {
        try await HarborGatewayChecks().udpAssociationAndRelease()
    }

    @Test func httpAndSOCKSProtocols() async throws {
        try await HarborGatewayChecks().httpAndSOCKSProtocols()
    }

    @Test func oldFlowDrainsAndSuspendedGatewayNeverRoutes() async throws {
        try await HarborGatewayChecks().oldFlowDrainsAndSuspendedGatewayNeverRoutes()
    }
}
