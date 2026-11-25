import Testing
@testable import CodexHarborCore

@Suite("Resident WARP discovery cooldown")
struct HarborWARPFormalDiscoveryPolicyTests {
    @Test func failureIsScopedAndExpires() {
        var policy = HarborWARPFormalDiscoveryPolicy()
        let key = HarborWARPFormalDiscoveryPolicy.Key(accountID: "a", nodeID: "n",
            endpointSignature: "v1", networkEpoch: 1)
        let otherNetwork = HarborWARPFormalDiscoveryPolicy.Key(accountID: "a", nodeID: "n",
            endpointSignature: "v1", networkEpoch: 2)
        let changedNode = HarborWARPFormalDiscoveryPolicy.Key(accountID: "a", nodeID: "n",
            endpointSignature: "v2", networkEpoch: 1)
        let now = ContinuousClock.now
        policy.recordFailure(key, now: now)
        #expect(!policy.canAttempt(key, now: now))
        #expect(policy.canAttempt(key, now: now + .seconds(15)))
        #expect(policy.canAttempt(otherNetwork, now: now))
        #expect(policy.canAttempt(changedNode, now: now))
        policy.recordFailure(key, now: now + .seconds(15))
        #expect(!policy.canAttempt(key, now: now + .seconds(44)))
        #expect(policy.canAttempt(key, now: now + .seconds(45)))
        policy.recordSuccess(key)
        #expect(policy.canAttempt(key, now: now))
    }
}
