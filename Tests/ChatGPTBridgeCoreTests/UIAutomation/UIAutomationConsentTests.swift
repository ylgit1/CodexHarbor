import Foundation
import Testing
@testable import ChatGPTBridgeCore

@Suite("macOS UI automation consent")
struct UIAutomationConsentTests {
    @Test("Absent app grant denies all UI actions")
    func defaultDeny() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-consent-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarborUIConsentStore(paths: BridgePaths(root: root))
        #expect(!store.allows(bundleID: "com.example.editor", capability: .read))
        #expect(!store.allows(bundleID: "com.example.editor", capability: .control))
        #expect(!store.allows(bundleID: "com.example.editor", capability: .capture))
    }

    @Test("Grant is per application and per capability")
    func scopedGrant() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-grants-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarborUIConsentStore(paths: BridgePaths(root: root))
        try store.save(HarborUIAppGrant(bundleID: "com.example.editor", canRead: true))
        #expect(store.allows(bundleID: "com.example.editor", capability: .read))
        #expect(!store.allows(bundleID: "com.example.editor", capability: .control))
        #expect(!store.allows(bundleID: "com.example.editor", capability: .capture))
        #expect(!store.allows(bundleID: "com.example.browser", capability: .read))
        try store.save(HarborUIAppGrant(bundleID: "com.example.editor",
                                        canRead: true, canControl: true))
        #expect(store.allows(bundleID: "com.example.editor", capability: .control))
        #expect(!store.allows(bundleID: "com.example.editor", capability: .capture))
        let reopened = HarborUIConsentStore(paths: BridgePaths(root: root))
        #expect(reopened.allows(bundleID: "com.example.editor", capability: .control))
        try reopened.revoke(bundleID: "com.example.editor")
        #expect(!store.allows(bundleID: "com.example.editor", capability: .read))
    }

    @Test("OS security windows and protected applications are always excluded")
    func protectedTargets() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ui-protected-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = HarborUIConsentStore(paths: BridgePaths(root: root))
        for name in ["com.apple.systempreferences", "com.apple.keychainaccess",
                     "com.apple.loginwindow", "com.apple.securityagent"] {
            #expect(HarborUIConsentStore.isProtected(name))
            #expect(throws: Error.self) {
                try store.save(HarborUIAppGrant(bundleID: name, canRead: true,
                                                canControl: true, canCapture: true))
            }
        }
    }

    @Test("On-demand authorization maps exact permission types without escalation")
    func authorizationMapping() {
        for capability in [HarborUIConsentStore.Capability.read, .control, .capture] {
            #expect(HarborUIAuthorization.capability(
                forTool: HarborUIAuthorization.toolName(for: capability)
            ) == capability)
        }
        #expect(HarborUIAuthorization.capability(forTool: "run_command") == nil)
        #expect(HarborUIAuthorization.capability(forTool: "ui_authorize_admin") == nil)
        #expect(HarborUIAuthorization.isValidTarget("com.example.editor"))
        #expect(!HarborUIAuthorization.isValidTarget("com.apple.keychainaccess"))
        #expect(!HarborUIAuthorization.isValidTarget("../invalid"))
    }

    @Test("Sensitive UI controls cannot expose or interact with credentials")
    func sensitiveElements() {
        #expect(HarborUISafety.isSensitive(role: "AXSecureTextField", label: ""))
        #expect(HarborUISafety.isSensitive(role: "AXTextField", label: "API Key"))
        #expect(HarborUISafety.isRestrictedAction(role: "AXButton", label: "允许一次"))
        #expect(HarborUISafety.isRestrictedAction(role: "AXButton", label: "Delete"))
        #expect(!HarborUISafety.isRestrictedAction(role: "AXButton", label: "刷新"))
    }
}
