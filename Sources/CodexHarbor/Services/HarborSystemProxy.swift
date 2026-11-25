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
        var transactionID: UUID?
        var managedAt: Date?
    }
    private struct Journal: Codable {
        var version: Int = 2
        var services: [String: Snapshot]
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
        ownedListenerPort()
    }

    private static func decoded(_ data: Data) -> [String: Any]? {
        try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
    }
    private static func encoded(_ value: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: value, format: .binary, options: 0)
    }
    private static func loadSnapshots() -> [String: Snapshot]? {
        guard hasBackup else { return [:] }
        guard let file = try? FileHandle(forReadingFrom: backupURL) else { return nil }
        defer { try? file.close() }
        let limit = 2 * 1024 * 1024
        guard let bytes = try? file.read(upToCount: limit + 1), bytes.count <= limit else { return nil }
        let decoder = JSONDecoder()
        if let journal = try? decoder.decode(Journal.self, from: bytes) {
            guard journal.version == 2, journal.services.count <= 64,
                  journal.services.allSatisfy({ $0.key == $0.value.serviceID }) else { return nil }
            return journal.services
        }
        // Existing v0.1.38 recovery files remain readable without migration.
        guard let legacy = try? decoder.decode(Snapshot.self, from: bytes) else { return nil }
        return [legacy.serviceID: legacy]
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

    static func isOwned() -> Bool { ownedListenerPort() != nil }

    private static func ownedListenerPort() -> Int? {
        guard let snapshots = loadSnapshots(),
              let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let (serviceID, target) = currentService(prefs),
              let snapshot = snapshots[serviceID] else { return nil }
        let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        // The app may have exited just after applying a pending transaction.
        // Accept it only if the complete actual listener matches the journal.
        for data in [snapshot.pending, snapshot.managed].compactMap({ $0 }) {
            guard let values = decoded(data), let port = (values["HTTPPort"] as? NSNumber)?.intValue,
                  usesEffectiveListener(port, all: true),
                  HarborSystemProxyNetworkSetup.matches(current, values, includeBypass: false) else { continue }
            return port
        }
        return nil
    }

    private static func usesEffectiveListener(_ port: Int, all: Bool = false) -> Bool {
        let effective = SCDynamicStoreCopyProxies(nil) as? [String: Any] ?? [:]
        return HarborSystemProxyNetworkSetup.usesLoopback(effective, httpPort: port, all: all)
    }

    /// True only while at least one active proxy entry still points to the
    /// listener recorded by Harbor. A complete takeover by another client is
    /// safe to relinquish and must not strand node switching in recovery mode.
    static var currentUsesManagedListener: Bool {
        guard let snapshots = loadSnapshots() else { return hasBackup }
        guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil) else {
            return !snapshots.isEmpty
        }
        return snapshots.values.contains { snapshot in
            let current = proxy(prefs, serviceID: snapshot.serviceID)
                .flatMap { SCNetworkProtocolGetConfiguration($0) as? [String: Any] } ?? [:]
            return managedPorts(snapshot).contains { port in
                HarborSystemProxyNetworkSetup.usesLoopback(current, httpPort: port) || usesEffectiveListener(port)
            }
        }
    }

    /// A configured inactive service can become active at any moment.
    /// Its reference must be treated like a live listener dependency.
    static func referencesListener(_ port: Int) -> Bool {
        // Check every configured service, not only services in our journal.
        // A manual edit or another app may still reference the old listener.
        if usesEffectiveListener(port) { return true }
        guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.references" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]
        else { return true }
        return services.contains { service in
            guard let target = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  let values = SCNetworkProtocolGetConfiguration(target) as? [String: Any] else { return false }
            return HarborSystemProxyNetworkSetup.usesLoopback(values, httpPort: port)
        }
    }

    static func otherServiceReferencesListener(_ port: Int) -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.references" as CFString, nil),
              let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService]
        else { return true }
        let activeID = currentService(prefs)?.0
        return services.contains { service in
            guard (SCNetworkServiceGetServiceID(service) as String?) != activeID,
                  let target = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  let values = SCNetworkProtocolGetConfiguration(target) as? [String: Any] else { return false }
            return HarborSystemProxyNetworkSetup.usesLoopback(values, httpPort: port)
        }
    }

    static var activeUsesManagedListener: Bool {
        guard let snapshots = loadSnapshots() else { return hasBackup }
        return snapshots.values.flatMap(managedPorts).contains { usesEffectiveListener($0) }
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
        if try applyWithPreferencesLock(serviceID: serviceID, values: values, expected: expected,
                                        requireActive: requireActive) { return }

        // Some accounts can use macOS's networksetup helper but cannot write
        // the preferences directly. Re-read and verify the exact transition
        // around every helper call, keeping the recovery snapshot on conflict.
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let service = SCNetworkServiceCopy(inspector, serviceID as CFString),
              let name = SCNetworkServiceGetName(service) as String? else { throw Failure.unavailable }
        let deadline = ContinuousClock.now + .seconds(10)
        func read() throws -> [String: Any] {
            guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
                  let service = SCNetworkServiceCopy(prefs, serviceID as CFString),
                  SCNetworkServiceGetName(service) as String? == name,
                  let allServices = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService],
                  allServices.filter({ (SCNetworkServiceGetName($0) as String?) == name }).count == 1,
                  let target = SCNetworkServiceCopyProtocol(service, kSCNetworkProtocolTypeProxies),
                  !requireActive || currentService(prefs)?.0 == serviceID else { throw Failure.notOwned }
            return SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        }
        do {
            try HarborSystemProxyNetworkSetup.applyGuarded(expected: expected, desired: values, read: read) { command in
                let remaining = ContinuousClock.now.duration(to: deadline).components
                let seconds = Double(remaining.seconds) + Double(remaining.attoseconds) / 1e18
                guard seconds > 0 else { throw Failure.changeFailed }
                let result = try HarborProxyCommand.runBlocking(
                    URL(fileURLWithPath: "/usr/sbin/networksetup"),
                    arguments: [command[0], name] + Array(command.dropFirst()), timeout: min(3, seconds), outputLimit: 0
                )
                guard result.status == 0 else { throw Failure.changeFailed }
            }
        } catch is HarborSystemProxyNetworkSetup.GuardedWriteFailure {
            throw Failure.notOwned
        }
    }

    /// Compare and commit with the OS lock held when the current account has
    /// direct write access. Do not wait on another writer or request more rights.
    private static func applyWithPreferencesLock(
        serviceID: String, values: [String: Any], expected: [String: Any], requireActive: Bool
    ) throws -> Bool {
        guard let prefs = SCPreferencesCreate(nil, "com.codexharbor.proxy.write" as CFString, nil) else {
            throw Failure.unavailable
        }
        guard SCPreferencesLock(prefs, false) else {
            let status = SCError()
            if status == kSCStatusAccessError { return false }
            if status == kSCStatusPrefsBusy || status == kSCStatusStale { throw Failure.notOwned }
            throw Failure.changeFailed
        }
        defer { SCPreferencesUnlock(prefs) }
        guard let target = proxy(prefs, serviceID: serviceID),
              !requireActive || currentService(prefs)?.0 == serviceID else { throw Failure.notOwned }
        let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        guard HarborSystemProxyNetworkSetup.unchangedForWrite(current, expected) else { throw Failure.notOwned }
        let updated = HarborSystemProxyNetworkSetup.mergingManagedValues(values, into: current)
        if HarborSystemProxyNetworkSetup.unchangedForWrite(current, updated) { return true }
        if !SCNetworkProtocolSetConfiguration(target, updated as CFDictionary) || !SCPreferencesCommitChanges(prefs) {
            if SCError() == kSCStatusAccessError { return false }
            throw Failure.changeFailed
        }
        guard SCPreferencesApplyChanges(prefs) else { throw Failure.changeFailed }
        return true
    }

    static func enable(port: Int, forcedProxyDomains: [String], automaticBypass: [String]) async throws {
        try await transaction {
            try enableBlocking(port: port, forcedProxyDomains: forcedProxyDomains, automaticBypass: automaticBypass)
        }
    }

    private static func save(_ snapshots: [String: Snapshot]) throws {
        if snapshots.isEmpty {
            if hasBackup { try FileManager.default.removeItem(at: backupURL) }
            return
        }
        guard snapshots.count <= 64 else { throw Failure.changeFailed }
        let parent = backupURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let encoder = JSONEncoder()
        // Preserve the old single-service file shape for straightforward
        // downgrade after a normal stop; multiple services need the v2 journal.
        let data = try snapshots.count == 1
            ? encoder.encode(snapshots.values.first!)
            : encoder.encode(Journal(services: snapshots))
        guard data.count <= 2 * 1024 * 1024 else { throw Failure.changeFailed }
        try HarborProbeFiles.replace(data, at: backupURL)
    }

    private static func enableBlocking(port: Int, forcedProxyDomains: [String],
                                       automaticBypass: [String]) throws {
        guard (1024...65534).contains(port) else { throw Failure.unavailable }
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil),
              let (id, active) = currentService(inspector) else { throw Failure.unavailable }
        let inspected = SCNetworkProtocolGetConfiguration(active) as? [String: Any] ?? [:]
        guard var snapshots = loadSnapshots() else { throw Failure.notOwned }
        var previous = snapshots[id]
        var original = inspected
        if var record = previous {
            if let pending = record.pending {
                // Finish an interrupted commit only when the entire pending
                // configuration actually took effect; otherwise require recovery.
                if let values = decoded(pending), equal(inspected, values), usesEffectiveListener(portOf(values) ?? 0, all: true) {
                    record.managed = pending
                    record.pending = nil
                    snapshots[id] = record
                    try save(snapshots)
                    previous = record
                } else {
                    throw Failure.notOwned
                }
            }
            guard let baseline = decoded(record.original), let managed = decoded(record.managed),
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
        let transition = Snapshot(serviceID: id, original: try encoded(original),
                                  managed: previous?.managed ?? desired, pending: desired,
                                  transactionID: UUID(), managedAt: .now)
        let priorSnapshots = snapshots
        snapshots[id] = transition
        try save(snapshots)
        do {
            try apply(serviceID: id, values: updated, expected: inspected, requireActive: true)
            guard let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.verify" as CFString, nil),
                  let (effectiveService, target) = currentService(verifier), effectiveService == id,
                  equal(SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:], updated) else {
                throw Failure.changeFailed
            }
            for _ in 0..<10 where !usesEffectiveListener(port, all: true) {
                Thread.sleep(forTimeInterval: 0.06)
            }
            guard usesEffectiveListener(port, all: true) else { throw Failure.changeFailed }
            snapshots[id] = Snapshot(serviceID: id, original: transition.original, managed: desired,
                                     transactionID: transition.transactionID, managedAt: transition.managedAt)
            try save(snapshots)
        } catch {
            if let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.rollback" as CFString, nil),
               let target = proxy(verifier, serviceID: id) {
                let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
                if HarborSystemProxyNetworkSetup.recoverable(current, original: inspected, managed: updated),
                   (try? apply(serviceID: id, values: inspected, expected: current)) != nil,
                   let checked = SCPreferencesCreate(nil, "com.codexharbor.proxy.rollback.verify" as CFString, nil),
                   let restored = proxy(checked, serviceID: id),
                   equal(SCNetworkProtocolGetConfiguration(restored) as? [String: Any] ?? [:], inspected) {
                    // Keep the prepared journal if the dynamic store has not
                    // caught up; the caller must preserve the affected listener.
                    if previous != nil || !usesEffectiveListener(port) {
                        try? save(priorSnapshots)
                    }
                }
            }
            throw error
        }
    }

    @discardableResult
    static func restore() async throws -> Bool {
        try await transaction { try restoreBlocking() }
    }

    private static func portOf(_ values: [String: Any]) -> Int? {
        guard let port = (values["HTTPPort"] as? NSNumber)?.intValue,
              (1024...65534).contains(port) else { return nil }
        return port
    }

    private static func restoreBlocking() throws -> Bool {
        guard var snapshots = loadSnapshots() else { throw Failure.notOwned }
        guard !snapshots.isEmpty else { return false }
        // Restore active service last, so inactive services cannot strand a
        // still-owned listener during a switch between Wi-Fi and a hotspot.
        let activeID = SCPreferencesCreate(nil, "com.codexharbor.proxy.restore.order" as CFString, nil)
            .flatMap { currentService($0)?.0 }
        let ids = snapshots.keys.sorted { a, b in
            if a == activeID { return false }
            if b == activeID { return true }
            return a < b
        }
        for id in ids {
            guard let snapshot = snapshots[id] else { continue }
            try restoreService(snapshot, remaining: snapshots.values.filter { $0.serviceID != id })
            snapshots.removeValue(forKey: id)
            try save(snapshots)
        }
        return true
    }

    private static func restoreService(_ snapshot: Snapshot, remaining: [Snapshot]) throws {
        guard let original = decoded(snapshot.original),
              let managed = decoded(snapshot.managed) else { throw Failure.notOwned }
        guard let inspector = SCPreferencesCreate(nil, "com.codexharbor.proxy.read" as CFString, nil) else {
            throw Failure.unavailable
        }
        let ports = managedPorts(snapshot)
        func finishRestore() throws {
            let activeID = SCPreferencesCreate(nil, "com.codexharbor.proxy.restore.verify" as CFString, nil)
                .flatMap { currentService($0)?.0 }
            let remainingPorts = remaining.filter { $0.serviceID == activeID }.flatMap(managedPorts)
            let portsToRelease = ports.filter { !remainingPorts.contains($0) }
            for _ in 0..<10 where portsToRelease.contains(where: { usesEffectiveListener($0) }) {
                Thread.sleep(forTimeInterval: 0.06)
            }
            guard !portsToRelease.contains(where: { usesEffectiveListener($0) }) else {
                throw Failure.notOwned
            }
        }
        guard let target = proxy(inspector, serviceID: snapshot.serviceID) else {
            guard SCNetworkServiceCopy(inspector, snapshot.serviceID as CFString) == nil else { throw Failure.unavailable }
            try finishRestore()
            return
        }
        let current = SCNetworkProtocolGetConfiguration(target) as? [String: Any] ?? [:]
        if equal(current, original) {
            try finishRestore()
            return
        }
        var desired = HarborSystemProxyNetworkSetup.restoreValues(
            current: current, original: original, managed: managed)
        if let pending = snapshot.pending.flatMap(decoded) {
            desired = HarborSystemProxyNetworkSetup.restoreValues(
                current: desired, original: original, managed: pending)
        }
        if equal(current, desired) {
            try finishRestore()
            return
        }
        try apply(serviceID: snapshot.serviceID, values: desired, expected: current)
        guard let verifier = SCPreferencesCreate(nil, "com.codexharbor.proxy.verify" as CFString, nil),
              let verified = proxy(verifier, serviceID: snapshot.serviceID),
              equal(SCNetworkProtocolGetConfiguration(verified) as? [String: Any] ?? [:], desired)
        else { throw Failure.changeFailed }
        try finishRestore()
    }
}
