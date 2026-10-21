import Testing
@testable import CodexHarborCore

@Suite("System proxy recovery state")
struct HarborProxyRecoveryPolicyTests {
    @Test("Active owned proxy must not be labeled as pending recovery")
    func runningOwnedProxy() {
        #expect(!HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: true, isRunning: true,
            isSystemManaged: true, ownsSystemProxy: true))
    }

    @Test("A saved backup without a live owned connection requires recovery")
    func staleSnapshots() {
        #expect(HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: true, isRunning: false,
            isSystemManaged: true, ownsSystemProxy: true))
        #expect(HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: true, isRunning: true,
            isSystemManaged: false, ownsSystemProxy: true))
        #expect(HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: true, isRunning: true,
            isSystemManaged: true, ownsSystemProxy: false))
    }

    @Test("A missing snapshot never triggers a recovery warning")
    func noBackup() {
        #expect(!HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: false, isRunning: false,
            isSystemManaged: false, ownsSystemProxy: false))
    }

    @Test("A complete takeover by another proxy client is safe to relinquish")
    func externalTakeover() {
        #expect(!HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: true, isRunning: true,
            isSystemManaged: true, ownsSystemProxy: false,
            currentUsesManagedListener: false))
        #expect(HarborProxyRecoveryPolicy.requiresRecovery(
            hasBackup: true, isRunning: true,
            isSystemManaged: true, ownsSystemProxy: false,
            currentUsesManagedListener: true))
    }

    @Test("Stop must restore even when the system proxy is working")
    func stopGuard() {
        #expect(HarborProxyRecoveryPolicy.mustRestoreBeforeStop(hasBackup: true))
        #expect(!HarborProxyRecoveryPolicy.mustRestoreBeforeStop(hasBackup: false))
    }
}
