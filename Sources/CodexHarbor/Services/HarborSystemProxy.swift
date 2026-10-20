import Foundation
import Security
import SystemConfiguration

/// Separate from the ChatGPT transport. Never edit a different application's
/// active proxy settings, even if an old Harbor recovery file is present.
enum HarborSystemProxy {
    private struct Snapshot: Codable {
        var serviceID: String
        var original: Data
        var managed: Data
    }
    enum Failure: LocalizedError {
        case unavailable, inUse, notOwned, authorization, changeFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: "未找到当前网络服务"
            case .inUse: "系统代理正被其他程序使用，请先在原程序中清除系统代理"
            case .notOwned: "系统代理已被其他程序更改，不能覆盖，请手动检查网络设置"
            case .authorization: "无法取得 macOS 系统代理修改权限"
            case .changeFailed: "系统代理应用或恢复失败"
            }
        }
    }

    private static let keys = ["HTTPEnable","HTTPProxy","HTTPPort",
                               "HTTPSEnable","HTTPSProxy","HTTPSPort",
                               "SOCKSEnable","SOCKSProxy","SOCKSPort",
                               "ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable","ExceptionsList"]
    private static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/NetworkProxy/system-recovery.json")
    }
    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    private static func decoded(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
    private static func encoded(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private static func load() -> Snapshot? {
        guard let bytes = try? Data(contentsOf: backupURL) else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: bytes)
    }
    private static func currentService(_ prefs: SCPreferences) -> (String, SCNetworkProtocol)? {
        guard let status = SCDynamicStoreCopyValue(nil, "State:/Network/Global/IPv4" as CFString) as? [String: Any],
              let id = status["PrimaryService"] as? String,
              let service = SCNetworkServiceCopy(prefs, id as CFString),
              let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
        else { return nil }
        return (id, proto)
    }
    private static func proxy(_ prefs: SCPreferences, serviceID: String) -> SCNetworkProtocol? {
        guard let service = SCNetworkServiceCopy(prefs, serviceID as CFString) else { return nil }
        return SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
    }
    private static func hasOther(_ value: [String: Any]) -> Bool {
        ["HTTPEnable","HTTPSEnable","SOCKSEnable","ProxyAutoConfigEnable","ProxyAutoDiscoveryEnable"]
            .contains { (value[$0] as? NSNumber)?.boolValue == true }
    }
    private static func equal(_ a: [String: Any], _ b: [String: Any]) -> Bool {
        keys.allSatisfy { key in
            let one = a[key] as? NSObject
            let two = b[key] as? NSObject
            return one == two
        }
    }

    static func isOwned() -> Bool {
        guard let backup = load(),
              let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let p = proxy(prefs, serviceID: backup.serviceID),
              let desired = decoded(backup.managed) else { return false }
        return equal(SCNetworkProtocolGetConfiguration(p) as? [String: Any] ?? [:], desired)
    }

    static func activeProxyDescription() -> String {
        guard let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] else { return "无法读取系统代理" }
        let labels = [
            ("HTTP","HTTPEnable","HTTPProxy","HTTPPort"),
            ("HTTPS","HTTPSEnable","HTTPSProxy","HTTPSPort"),
            ("SOCKS","SOCKSEnable","SOCKSProxy","SOCKSPort")
        ]
        let items = labels.compactMap { name, enabled, address, port -> String? in
            guard (settings[enabled] as? NSNumber)?.boolValue == true else { return nil }
            let host = settings[address] as? String ?? "?"
            let number = (settings[port] as? NSNumber)?.intValue ?? 0
            return "\(name) \(host):\(number)"
        }
        return items.isEmpty ? "未启用" : items.joined(separator: " · ")
    }

    private final class Authorized {
        let prefs: SCPreferences
        let auth: AuthorizationRef
        init(interactive: Bool) throws {
            var reference: AuthorizationRef?
            let flags: AuthorizationFlags = interactive ? [.interactionAllowed, .extendRights] : [.extendRights]
            guard AuthorizationCreate(nil, nil, flags, &reference) == errAuthorizationSuccess,
                  let reference else { throw Failure.authorization }
            guard let preferences = SCPreferencesCreateWithAuthorization(
                nil, "com.codexharbor.proxy.write" as CFString, nil, reference
            ) else {
                AuthorizationFree(reference, [])
                throw Failure.authorization
            }
            prefs = preferences; auth = reference
        }
        deinit { AuthorizationFree(auth, []) }
    }

    private static func apply(_ proto: SCNetworkProtocol, prefs: SCPreferences, values: [String: Any]) throws {
        guard SCNetworkProtocolSetConfiguration(proto, values as CFDictionary),
              SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs)
        else { throw Failure.changeFailed }
    }

    static func enable(port: Int) throws {
        guard (1024...65535).contains(port) else { throw Failure.unavailable }
        if hasBackup { throw Failure.notOwned }
        // Fail closed before requesting authorization. This prevents a subtle
        // overwrite when v2rayN still controls Wi-Fi's loopback proxy.
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let (id, active) = currentService(inspector) else { throw Failure.unavailable }
        let inspected = SCNetworkProtocolGetConfiguration(active) as? [String: Any] ?? [:]
        if hasOther(inspected) { throw Failure.inUse }
        let context = try Authorized(interactive: true)
        guard let target = proxy(context.prefs, serviceID: id) else { throw Failure.unavailable }
        let previous = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        if hasOther(previous) { throw Failure.inUse }
        var updated = previous
        updated["HTTPEnable"] = 1; updated["HTTPProxy"] = "127.0.0.1"; updated["HTTPPort"] = port
        updated["HTTPSEnable"] = 1; updated["HTTPSProxy"] = "127.0.0.1"; updated["HTTPSPort"] = port
        updated["SOCKSEnable"] = 1; updated["SOCKSProxy"] = "127.0.0.1"
        updated["SOCKSPort"] = port + 1; updated["ProxyAutoConfigEnable"] = 0
        updated["ProxyAutoDiscoveryEnable"] = 0
        var bypass = (updated["ExceptionsList"] as? [String]) ?? []
        for host in ["localhost", "127.0.0.0/8", "::1"] where !bypass.contains(host) { bypass.append(host) }
        updated["ExceptionsList"] = bypass
        let backup = Snapshot(serviceID: id, original: try encoded(previous), managed: try encoded(updated))
        let parent = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try JSONEncoder().encode(backup).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        do {
            try apply(target, prefs: context.prefs, values: updated)
            guard isOwned() else { throw Failure.changeFailed }
        } catch {
            try? apply(target, prefs: context.prefs, values: previous)
            if let restored = SCNetworkProtocolGetConfiguration(target) as? [String: Any],
               equal(restored, previous) { try? FileManager.default.removeItem(at: backupURL) }
            throw error
        }
    }

    @discardableResult
    static func restore(interactive: Bool) throws -> Bool {
        guard let snapshot = load(), let original = decoded(snapshot.original),
              let managed = decoded(snapshot.managed) else {
            if hasBackup { throw Failure.notOwned }
            return false
        }
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let target = proxy(inspector, serviceID: snapshot.serviceID) else { throw Failure.unavailable }
        let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        if equal(current, original) {
            try FileManager.default.removeItem(at: backupURL)
            return true
        }
        if !equal(current, managed) {
            // Another client has already taken over the system proxy.
            // Relinquish our recovery marker only if macOS no longer points
            // to Harbor's former local HTTP/HTTPS port.
            let harborPort = (managed["HTTPPort"] as? NSNumber)?.intValue ?? -1
            let stillUsesHarbor = ["HTTP", "HTTPS", "SOCKS"].contains { label in
                let enabled = (current[label + "Enable"] as? NSNumber)?.boolValue == true
                let host = current[label + "Proxy"] as? String
                let port = (current[label + "Port"] as? NSNumber)?.intValue ?? -1
                let targetPort = label == "SOCKS" ? harborPort + 1 : harborPort
                return enabled && host == "127.0.0.1" && port == targetPort
            }
            guard !stillUsesHarbor else { throw Failure.notOwned }
            try FileManager.default.removeItem(at: backupURL)
            return true
        }
        let context = try Authorized(interactive: interactive)
        guard let authorizedTarget = proxy(context.prefs, serviceID: snapshot.serviceID),
              equal(SCNetworkProtocolGetConfiguration(authorizedTarget) as? [String: Any] ?? [:], managed)
        else { throw Failure.notOwned }
        try apply(authorizedTarget, prefs: context.prefs, values: original)
        guard let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.verify" as CFString, nil),
              let verified = proxy(verifier, serviceID: snapshot.serviceID),
              equal(SCNetworkProtocolGetConfiguration(verified) as? [String: Any] ?? [:], original)
        else { throw Failure.changeFailed }
        try FileManager.default.removeItem(at: backupURL)
        return true
    }
}
