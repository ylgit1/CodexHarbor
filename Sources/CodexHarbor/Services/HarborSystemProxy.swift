import CodexHarborCore
import Foundation
import SystemConfiguration

/// Separate from the ChatGPT transport. Never edit a different application's
/// active proxy settings, even if an old Harbor recovery file is present.
enum HarborSystemProxy {
    private struct Snapshot: Codable {
        var serviceID: String
        var original: Data
        var managed: Data
        var pending: Data?
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
    private static let queue = DispatchQueue(label: "com.codexharbor.proxy.system", qos: .utility)

    private static func transaction<Result: Sendable>(
        _ body: @escaping @Sendable () throws -> Result
    ) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Swift.Result { try body() }) }
        }
    }

    /// Recover the actual managed listener port if the app exited before
    /// restoring the previous macOS network settings.
    static var ownedHTTPPort: Int? {
        guard isOwned(), let snapshot = load(),
              let managed = decoded(snapshot.managed) else { return nil }
        guard let port = (managed["HTTPPort"] as? NSNumber)?.intValue,
              usesEffectiveListener(port, all: true) else { return nil }
        return port
    }

    private static func decoded(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
    private static func encoded(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private static func load() -> Snapshot? {
        guard let file = try? FileHandle(forReadingFrom: backupURL) else { return nil }
        defer { try? file.close() }
        guard let bytes = try? file.read(upToCount: 256 * 1024 + 1), bytes.count <= 256 * 1024 else { return nil }
        return try? JSONDecoder().decode(Snapshot.self, from: bytes)
    }
    private static func currentService(_ prefs: SCPreferences) -> (String, SCNetworkProtocol)? {
        let serviceIDs = ["IPv4", "IPv6"].compactMap { family -> String? in
            let status = SCDynamicStoreCopyValue(nil, "State:/Network/Global/\(family)" as CFString)
                as? [String: Any]
            return status?["PrimaryService"] as? String
        }
        for id in serviceIDs {
            if let target = proxy(prefs, serviceID: id) { return (id, target) }
        }
        return nil
    }

    /// Use only the primary interface and route, not proxy settings that Harbor
    /// itself writes. A missing route during wake-up is not a network change.
    static func currentNetworkFingerprintInput() -> String? {
        let routes = ["IPv4", "IPv6"].compactMap { family -> String? in
            let key = "State:/Network/Global/\(family)" as CFString
            guard let status = SCDynamicStoreCopyValue(nil, key) as? [String: Any],
                  let service = status["PrimaryService"] as? String else { return nil }
            let router = status["Router"] as? String ?? ""
            return "\(family):\(service):\(router)"
        }
        return routes.isEmpty ? nil : routes.joined(separator: "|")
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
        guard let snapshot = load(), let managed = decoded(snapshot.managed),
              let port = (managed["HTTPPort"] as? NSNumber)?.intValue,
              let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let (serviceID, target) = currentService(prefs), serviceID == snapshot.serviceID,
              usesEffectiveListener(port, all: true) else { return false }
        return HarborSystemProxyNetworkSetup.matches(
            SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:],
            managed, includeBypass: false
        )
    }

    private static func usesEffectiveListener(_ port: Int, all: Bool = false) -> Bool {
        let effective = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        return HarborSystemProxyNetworkSetup.usesLoopback(effective, httpPort: port, all: all)
    }

    /// True only while at least one active proxy entry still points to the
    /// listener recorded by Harbor. A complete takeover by another client is
    /// safe to relinquish and must not strand node switching in recovery mode.
    static var currentUsesManagedListener: Bool {
        guard let snapshot = load() else { return false }
        let current = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil)
            .flatMap { proxy($0, serviceID: snapshot.serviceID) }
            .flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] } ?? [:]
        return managedPorts(snapshot).contains { port in
            HarborSystemProxyNetworkSetup.usesLoopback(current, httpPort: port) || usesEffectiveListener(port)
        }
    }

    private static func managedPorts(_ snapshot: Snapshot) -> [Int] {
        [snapshot.managed, snapshot.pending].compactMap { data in
            guard let data, let values = decoded(data),
                  let port = (values["HTTPPort"] as? NSNumber)?.intValue,
                  (1024...65534).contains(port) else { return nil }
            return port
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
        var kinds = items
        if (settings["ProxyAutoConfigEnable"] as? NSNumber)?.boolValue == true {
            kinds.append("自动代理配置（PAC）")
        }
        if (settings["ProxyAutoDiscoveryEnable"] as? NSNumber)?.boolValue == true {
            kinds.append("自动发现代理")
        }
        return kinds.isEmpty ? "未启用" : kinds.joined(separator: " · ")
    }

    private static func apply(
        serviceID: String, values: [String: Any], expected: [String: Any], requireActive: Bool = false
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

        let deadline = ContinuousClock.now + .seconds(10)
        for command in commands {
            guard ContinuousClock.now < deadline else { throw Failure.changeFailed }
            guard let fresh = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
                  let destination = SCNetworkServiceCopy(fresh, serviceID as CFString),
                  SCNetworkServiceGetName(destination) as String? == name,
                  !requireActive || currentService(fresh)?.0 == serviceID else { throw Failure.notOwned }
            let result = try HarborProxyCommand.runBlocking(
                URL(fileURLWithPath: "/usr/sbin/networksetup"),
                arguments: [command[0], name] + Array(command.dropFirst()), timeout: 3, outputLimit: 0
            )
            guard result.status == 0 else { throw Failure.changeFailed }
        }
    }

    static func enable(port: Int, forcedProxyDomains: [String], automaticBypass: [String]) async throws {
        try await transaction {
            try enableBlocking(port: port, forcedProxyDomains: forcedProxyDomains, automaticBypass: automaticBypass)
        }
    }

    private static func save(_ snapshot: Snapshot) throws {
        let parent = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let staged = parent.appendingPathComponent(".proxy-recovery-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: staged) }
        guard FileManager.default.createFile(
            atPath: staged.path, contents: nil, attributes: [.posixPermissions: 0o600]
        ) else { throw Failure.changeFailed }
        try JSONEncoder().encode(snapshot).write(to: staged)
        guard Darwin.rename(staged.path, backupURL.path) == 0 else { throw Failure.changeFailed }
    }

    private static func enableBlocking(port: Int, forcedProxyDomains: [String],
                                       automaticBypass: [String]) throws {
        guard (1024...65534).contains(port) else { throw Failure.unavailable }
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let (id, active) = currentService(inspector) else { throw Failure.unavailable }
        let inspected = SCNetworkProtocolGetConfiguration(active) as? [String: Any] ?? [:]
        let previous = load()
        var original = inspected
        if hasBackup {
            guard let previous, previous.pending == nil, previous.serviceID == id,
                  let baseline = decoded(previous.original), let managed = decoded(previous.managed),
                  HarborSystemProxyNetworkSetup.matches(inspected, managed, includeBypass: false) else {
                throw Failure.notOwned
            }
            original = baseline
            original["ExceptionsList"] = HarborSystemProxyNetworkSetup.restoreBypass(
                current: inspected["ExceptionsList"] as? [String] ?? [],
                original: baseline["ExceptionsList"] as? [String] ?? [],
                managed: managed["ExceptionsList"] as? [String] ?? []
            )
        } else {
            let effective = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
            if hasOther(inspected) || hasOther(effective) { throw Failure.inUse }
        }
        var updated = inspected
        updated["HTTPEnable"] = 1; updated["HTTPProxy"] = "127.0.0.1"; updated["HTTPPort"] = port
        updated["HTTPSEnable"] = 1; updated["HTTPSProxy"] = "127.0.0.1"; updated["HTTPSPort"] = port
        updated["SOCKSEnable"] = 1; updated["SOCKSProxy"] = "127.0.0.1"
        updated["SOCKSPort"] = port + 1; updated["ProxyAutoConfigEnable"] = 0
        updated["ProxyAutoDiscoveryEnable"] = 0
        updated["ExceptionsList"] = HarborSystemProxyNetworkSetup.desiredBypass(
            original["ExceptionsList"] as? [String] ?? [],
            automatic: ["localhost", "127.0.0.0/8", "::1"] + automaticBypass,
            forced: try HarborProxyDomainRules.normalized(forcedProxyDomains)
        )
        let desired = try encoded(updated)
        var transition = Snapshot(serviceID: id, original: try encoded(original),
                                  managed: previous?.managed ?? desired)
        if previous != nil { transition.pending = desired }
        try save(transition)
        do {
            try apply(serviceID: id, values: updated, expected: inspected, requireActive: true)
            guard let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.verify" as CFString, nil),
                  let (effectiveService, target) = currentService(verifier), effectiveService == id,
                  equal(SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:], updated) else {
                throw Failure.changeFailed
            }
            try save(Snapshot(serviceID: id, original: transition.original, managed: desired))
        } catch {
            if let previous,
               let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.rollback" as CFString, nil),
               let target = proxy(verifier, serviceID: id) {
                let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
                if HarborSystemProxyNetworkSetup.recoverable(current, original: inspected, managed: updated),
                   (try? apply(serviceID: id, values: inspected, expected: current)) != nil {
                    try? save(previous)
                }
            } else if previous == nil {
                _ = try? restoreBlocking()
            }
            throw error
        }
    }

    @discardableResult
    static func restore() async throws -> Bool {
        try await transaction { try restoreBlocking() }
    }

    private static func restoreBlocking() throws -> Bool {
        guard let snapshot = load(), let original = decoded(snapshot.original),
              let managed = decoded(snapshot.managed) else {
            if hasBackup { throw Failure.notOwned }
            return false
        }
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil) else {
            throw Failure.unavailable
        }
        let ports = managedPorts(snapshot)
        func finishRestore() throws {
            if currentService(inspector)?.0 != snapshot.serviceID,
               ports.contains(where: { usesEffectiveListener($0) }) { throw Failure.notOwned }
            try FileManager.default.removeItem(at: backupURL)
        }
        guard let target = proxy(inspector, serviceID: snapshot.serviceID) else {
            guard SCNetworkServiceCopy(inspector, snapshot.serviceID as CFString) == nil else { throw Failure.unavailable }
            try finishRestore()
            return true
        }
        let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        if equal(current, original) {
            try finishRestore()
            return true
        }
        var desired = HarborSystemProxyNetworkSetup.restoreValues(
            current: current, original: original, managed: managed)
        if let pending = snapshot.pending.flatMap(decoded) {
            desired = HarborSystemProxyNetworkSetup.restoreValues(
                current: desired, original: original, managed: pending)
        }
        if equal(current, desired) {
            try finishRestore()
            return true
        }
        try apply(serviceID: snapshot.serviceID, values: desired, expected: current)
        guard let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.verify" as CFString, nil),
              let verified = proxy(verifier, serviceID: snapshot.serviceID),
              equal(SCNetworkProtocolGetConfiguration(verified) as? [String: Any] ?? [:], desired)
        else { throw Failure.changeFailed }
        try finishRestore()
        return true
    }
}
