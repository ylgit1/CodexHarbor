import CodexHarborCore
import Foundation
import SystemConfiguration

/// Separate from the ChatGPT transport. Never edit a different application's
/// active proxy settings, even if an old Harbor recovery file is present.
@MainActor
enum HarborSystemProxy {
    private struct Snapshot: Codable {
        var serviceID: String
        var original: Data
        var managed: Data
    }
    enum Failure: LocalizedError {
        case unavailable, inUse, notOwned, changeFailed
        var errorDescription: String? {
            switch self {
            case .unavailable: "未找到当前网络服务"
            case .inUse: "系统代理正被其他程序使用，请先在原程序中清除系统代理"
            case .notOwned: "系统代理已被其他程序更改，不能覆盖，请手动检查网络设置"
            case .changeFailed: "系统代理应用或恢复失败"
            }
        }
    }

    private static var backupURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/CodexHarbor/NetworkProxy/system-recovery.json")
    }
    static var hasBackup: Bool { FileManager.default.fileExists(atPath: backupURL.path) }

    /// Recover the actual managed listener port if the app exited before
    /// restoring the previous macOS network settings.
    static var ownedHTTPPort: Int? {
        guard isOwned(), let snapshot = load(),
              let managed = decoded(snapshot.managed) else { return nil }
        return (managed["HTTPPort"] as? NSNumber)?.intValue
    }

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
        HarborSystemProxyNetworkSetup.matches(a, b)
    }

    static func isOwned() -> Bool {
        guard let backup = load(),
              let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let p = proxy(prefs, serviceID: backup.serviceID),
              let desired = decoded(backup.managed) else { return false }
        return equal(SCNetworkProtocolGetConfiguration(p) as? [String: Any] ?? [:], desired)
    }

    /// True only while at least one active proxy entry still points to the
    /// listener recorded by Harbor. A complete takeover by another client is
    /// safe to relinquish and must not strand node switching in recovery mode.
    static var currentUsesManagedListener: Bool {
        guard let snapshot = load(), let managed = decoded(snapshot.managed),
              let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let target = proxy(prefs, serviceID: snapshot.serviceID) else { return false }
        let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        let harborPort = (managed["HTTPPort"] as? NSNumber)?.intValue ?? -1
        return ["HTTP", "HTTPS", "SOCKS"].contains { label in
            let enabled = (current[label + "Enable"] as? NSNumber)?.boolValue == true
            let host = current[label + "Proxy"] as? String
            let port = (current[label + "Port"] as? NSNumber)?.intValue ?? -1
            let targetPort = label == "SOCKS" ? harborPort + 1 : harborPort
            return enabled && host == "127.0.0.1" && port == targetPort
        }
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

    private static func apply(
        serviceID: String, values: [String: Any], expected: [String: Any]
    ) throws {
        guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let service = SCNetworkServiceCopy(prefs, serviceID as CFString),
              let name = SCNetworkServiceGetName(service) as String?,
              let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService],
              allServices.filter({ (SCNetworkServiceGetName($0) as String?) == name }).count == 1,
              let proto = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies)
        else { throw Failure.unavailable }
        let current = SCNetworkProtocolGetConfiguration(proto) as? [String: Any] ?? [:]
        guard equal(current, expected),
              let commands = HarborSystemProxyNetworkSetup.commands(
                current: current, desired: values
              ) else { throw Failure.notOwned }

        // Apple's networksetup has the network-configuration entitlement. Do
        // not invoke a shell or fall back to interactive Authorization Services.
        for command in commands {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/sbin/networksetup")
            process.arguments = [command[0], name] + Array(command.dropFirst())
            process.standardOutput = Pipe()
            process.standardError = Pipe()
            do { try process.run() } catch { throw Failure.changeFailed }
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { throw Failure.changeFailed }
        }
    }

    static func enable(port: Int, forcedProxyDomains: [String] = HarborProxyDomainRules.defaults,
                       interactive: Bool = false) throws {
        // Retain the caller's API shape; this path never requests interactive authorization.
        guard (1024...65534).contains(port) else { throw Failure.unavailable }
        if hasBackup { throw Failure.notOwned }
        // Fail closed before changing the network service. This prevents a subtle
        // overwrite when v2rayN still controls Wi-Fi's loopback proxy.
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let (id, active) = currentService(inspector) else { throw Failure.unavailable }
        let inspected = SCNetworkProtocolGetConfiguration(active) as? [String: Any] ?? [:]
        if hasOther(inspected) { throw Failure.inUse }
        var updated = inspected
        updated["HTTPEnable"] = 1; updated["HTTPProxy"] = "127.0.0.1"; updated["HTTPPort"] = port
        updated["HTTPSEnable"] = 1; updated["HTTPSProxy"] = "127.0.0.1"; updated["HTTPSPort"] = port
        updated["SOCKSEnable"] = 1; updated["SOCKSProxy"] = "127.0.0.1"
        updated["SOCKSPort"] = port + 1; updated["ProxyAutoConfigEnable"] = 0
        updated["ProxyAutoDiscoveryEnable"] = 0
        var bypass = (updated["ExceptionsList"] as? [String]) ?? []
        // Restore these exclusions on disconnect via the existing snapshot.
        // While Harbor owns the proxy, a macOS bypass for a forced site
        // would prevent Xray from seeing the request at all.
        let forced = try HarborProxyDomainRules.normalized(forcedProxyDomains)
        bypass.removeAll { exception in
            var host = exception.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if host.hasPrefix("*.") { host.removeFirst(2) }
            else if host.hasPrefix(".") { host.removeFirst() }
            return forced.contains { domain in host == domain || host.hasSuffix("." + domain) }
        }
        for host in ["localhost", "127.0.0.0/8", "::1"] where !bypass.contains(host) { bypass.append(host) }
        updated["ExceptionsList"] = bypass
        let backup = Snapshot(serviceID: id, original: try encoded(inspected), managed: try encoded(updated))
        let parent = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        try JSONEncoder().encode(backup).write(to: backupURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: backupURL.path)
        do {
            try apply(serviceID: id, values: updated, expected: inspected)
            guard isOwned() else { throw Failure.changeFailed }
        } catch {
            _ = try? restore(interactive: false)
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
        if !equal(current, managed) && !HarborSystemProxyNetworkSetup.recoverable(
            current, original: original, managed: managed
        ) {
            // Another client has already taken over the system proxy.
            // Relinquish our recovery marker only if macOS no longer points
            // to Harbor's former local HTTP/HTTPS port.
            guard !currentUsesManagedListener else { throw Failure.notOwned }
            try FileManager.default.removeItem(at: backupURL)
            return true
        }
        try apply(serviceID: snapshot.serviceID, values: original, expected: current)
        guard let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.verify" as CFString, nil),
              let verified = proxy(verifier, serviceID: snapshot.serviceID),
              equal(SCNetworkProtocolGetConfiguration(verified) as? [String: Any] ?? [:], original)
        else { throw Failure.changeFailed }
        try FileManager.default.removeItem(at: backupURL)
        return true
    }
}
