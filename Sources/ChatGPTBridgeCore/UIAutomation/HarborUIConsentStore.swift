import Foundation

/// Application UI authorization is separate from filesystem Allowed Roots.
/// Only an explicit local user action in Harbor's on-demand panel can persist a grant; MCP tools never mutate it.
public struct HarborUIAppGrant: Codable, Equatable, Sendable, Identifiable {
    public let bundleID: String
    public var canRead: Bool
    public var canControl: Bool
    public var canCapture: Bool
    public var id: String { bundleID }

    public init(bundleID: String, canRead: Bool = false, canControl: Bool = false, canCapture: Bool = false) {
        self.bundleID = bundleID
        self.canRead = canRead
        self.canControl = canControl
        self.canCapture = canCapture
    }
}

public struct HarborUIConsentStore: Sendable {
    public enum Capability: String, Sendable { case read, control, capture }

    private let location: URL
    public init(paths: BridgePaths) {
        location = paths.root.appendingPathComponent("ui-app-grants.json")
    }

    public static func isProtected(_ bundleID: String) -> Bool {
        let id = bundleID.lowercased()
        let protected: Set<String> = [
            "com.apple.loginwindow", "com.apple.systempreferences",
            "com.apple.securityagent", "com.apple.keychainaccess",
            "com.apple.passwords", "com.apple.notificationcenterui",
            "com.apple.controlcenter", "com.apple.screensaver.engine",
            "com.apple.authorizationhost", "com.apple.appstore"
        ]
        return protected.contains(id) ||
            id.contains("authenticationservices") ||
            id.contains("passwordmanager") ||
            id.hasPrefix("com.apple.security.")
    }

    public func grants() -> [HarborUIAppGrant] {
        guard let data = try? Data(contentsOf: location),
              let grants = try? JSONDecoder().decode([HarborUIAppGrant].self, from: data)
        else { return [] }
        return grants.filter { !Self.isProtected($0.bundleID) }
            .sorted { $0.bundleID < $1.bundleID }
    }

    public func allows(bundleID: String, capability: Capability) -> Bool {
        guard !Self.isProtected(bundleID),
              let grant = grants().first(where: { $0.bundleID == bundleID })
        else { return false }
        switch capability {
        case .read: return grant.canRead
        case .control: return grant.canControl && grant.canRead
        case .capture: return grant.canCapture && grant.canRead
        }
    }

    /// Call only after an explicit user click in Harbor's local approval panel.
    /// Control and screenshot access must never imply each other.
    public func save(_ grant: HarborUIAppGrant) throws {
        guard !Self.isProtected(grant.bundleID), Self.validBundleID(grant.bundleID) else {
            throw BridgeError.permissionDenied("此应用不允许通过界面自动化操作")
        }
        var current = grants().filter { $0.bundleID != grant.bundleID }
        current.append(grant)
        try persist(current)
    }

    public func revoke(bundleID: String) throws {
        try persist(grants().filter { $0.bundleID != bundleID })
    }

    private func persist(_ grants: [HarborUIAppGrant]) throws {
        try FileManager.default.createDirectory(
            at: location.deletingLastPathComponent(), withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(grants).write(to: location, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: location.path)
    }

    public static func validBundleID(_ id: String) -> Bool {
        id.count > 4 && id.count < 180 && id.contains(".") &&
        id.unicodeScalars.allSatisfy {
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-").contains($0)
        }
    }
}

/// Approval requests are created by the Agent when a specific UI tool actually
/// needs access. The MCP caller cannot grant permission; only the local panel
/// can save a per-app consent after the user clicks Allow.
public enum HarborUIAuthorization {
    public static func toolName(for capability: HarborUIConsentStore.Capability) -> String {
        switch capability {
        case .read: return "ui_authorize_read"
        case .control: return "ui_authorize_control"
        case .capture: return "ui_authorize_capture"
        }
    }

    public static func capability(forTool tool: String) -> HarborUIConsentStore.Capability? {
        switch tool {
        case "ui_authorize_read": return .read
        case "ui_authorize_control": return .control
        case "ui_authorize_capture": return .capture
        default: return nil
        }
    }

    public static func isValidTarget(_ bundleID: String) -> Bool {
        HarborUIConsentStore.validBundleID(bundleID) &&
            !HarborUIConsentStore.isProtected(bundleID)
    }
}

/// Never read input values or interact with security confirmation controls.
/// These checks are enforced again at the moment of every AX operation.
public enum HarborUISafety {
    public static func isSensitive(role: String, label: String) -> Bool {
        if role.caseInsensitiveCompare("AXSecureTextField") == .orderedSame { return true }
        let label = label.lowercased()
        return ["password", "passcode", "secret", "api key", "token", "private key",
                "one-time", "otp", "验证码", "密码", "密钥", "口令", "安全码"]
            .contains(where: label.contains)
    }

    public static func isRestrictedAction(role: String, label: String) -> Bool {
        if isSensitive(role: role, label: label) { return true }
        let l = label.lowercased()
        return ["allow", "approve", "grant", "authorize", "permission",
                "delete", "erase", "install", "submit", "purchase", "pay",
                "remove", "trash", "uninstall", "reset", "revoke", "git push",
                "允许", "批准", "授权", "同类不再询问", "拒绝访问",
                "永久删除", "清空", "安装", "付款", "购买", "提交", "推送",
                "删除", "卸载", "移入废纸篓", "移至废纸篓", "恢复出厂", "重置"]
            .contains(where: l.contains)
    }
}
