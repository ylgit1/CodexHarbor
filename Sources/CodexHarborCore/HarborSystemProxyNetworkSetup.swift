import Foundation

/// Plan the exact networksetup calls needed for Harbor's proxy snapshot.
/// The caller supplies a single, verified network service name to every call.
public enum HarborSystemProxyNetworkSetup {
    private static let protocols: [(name: String, set: String, state: String)] = [
        ("HTTP", "-setwebproxy", "-setwebproxystate"),
        ("HTTPS", "-setsecurewebproxy", "-setsecurewebproxystate"),
        ("SOCKS", "-setsocksfirewallproxy", "-setsocksfirewallproxystate")
    ]
    private static let flagKeys = ["HTTPEnable", "HTTPSEnable", "SOCKSEnable",
                                   "ProxyAutoConfigEnable", "ProxyAutoDiscoveryEnable"]
    private static let managedKeys = Set(flagKeys + protocols.flatMap { [$0.name + "Proxy", $0.name + "Port"] }
                                         + ["ExceptionsList"])

    public enum GuardedWriteFailure: Error {
        case changed, unsupported
    }

    private static func enabled(_ values: [String: Any], _ key: String) -> Bool {
        (values[key] as? NSNumber)?.boolValue == true
    }

    private static func port(_ values: [String: Any], _ key: String) -> Int? {
        (values[key] as? NSNumber)?.intValue
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        (lhs as? NSObject) == (rhs as? NSObject)
    }

    /// Stronger than the effective settings comparison. A dormant endpoint
    /// or PAC URL can have an owner even when its enable flag is off.
    public static func unchangedForWrite(_ current: [String: Any], _ expected: [String: Any]) -> Bool {
        Set(current.keys).union(expected.keys).allSatisfy { key in
            if flagKeys.contains(key) { return enabled(current, key) == enabled(expected, key) }
            if key == "ExceptionsList" {
                return (current[key] as? [String] ?? []) == (expected[key] as? [String] ?? [])
            }
            return same(current[key], expected[key])
        }
    }

    public static func mergingManagedValues(_ desired: [String: Any], into current: [String: Any]) -> [String: Any] {
        var result = current
        for key in managedKeys { result[key] = desired[key] }
        return result
    }

    /// Nonprivileged fallback. A third party's change ends the transaction
    /// before the next command, including changes to fields we never write.
    public static func applyGuarded(
        expected initial: [String: Any], desired: [String: Any],
        read: () throws -> [String: Any], run: ([String]) throws -> Void
    ) throws {
        guard let planned = commands(current: initial, desired: desired) else {
            throw GuardedWriteFailure.unsupported
        }
        var expected = initial
        for command in planned {
            guard unchangedForWrite(try read(), expected) else { throw GuardedWriteFailure.changed }
            try run(command)
            let observed = try read()
            guard statesAfter(command, before: expected).contains(where: { unchangedForWrite(observed, $0) }) else {
                throw GuardedWriteFailure.changed
            }
            expected = observed
        }
        guard unchangedForWrite(try read(), expected), matches(expected, desired) else {
            throw GuardedWriteFailure.changed
        }
    }

    private static func statesAfter(_ command: [String], before: [String: Any]) -> [[String: Any]] {
        guard let option = command.first else { return [] }
        var next = before
        if let item = protocols.first(where: { $0.set == option }), command.count == 3,
           let port = Int(command[2]) {
            next[item.name + "Proxy"] = command[1]
            next[item.name + "Port"] = port
            // Setters can enable an endpoint. The explicit following
            // state command resolves the difference when it matters.
            var enabled = next
            enabled[item.name + "Enable"] = 1
            return [next, enabled]
        }
        if let item = protocols.first(where: { $0.state == option }), command.count == 2 {
            next[item.name + "Enable"] = command[1] == "on" ? 1 : 0
        } else if option == "-setproxybypassdomains" {
            next["ExceptionsList"] = Array(command.dropFirst()) == ["Empty"] ? [] : Array(command.dropFirst())
        } else if option == "-setautoproxystate" {
            next["ProxyAutoConfigEnable"] = 0
        } else if option == "-setproxyautodiscovery" {
            next["ProxyAutoDiscoveryEnable"] = 0
        } else { return [] }
        return [next]
    }

    public static func matches(_ current: [String: Any], _ expected: [String: Any],
                               includeBypass: Bool = true) -> Bool {
        for item in protocols {
            let key = item.name
            guard enabled(current, key + "Enable") == enabled(expected, key + "Enable") else { return false }
            // networksetup can disable an unset proxy, but cannot remove dormant
            // host/port keys. Those keys have no effect while disabled.
            if enabled(expected, key + "Enable") || expected[key + "Proxy"] != nil || expected[key + "Port"] != nil {
                guard same(current[key + "Proxy"], expected[key + "Proxy"]),
                      same(current[key + "Port"], expected[key + "Port"]) else { return false }
            }
        }
        guard enabled(current, "ProxyAutoConfigEnable") == enabled(expected, "ProxyAutoConfigEnable"),
              enabled(current, "ProxyAutoDiscoveryEnable") == enabled(expected, "ProxyAutoDiscoveryEnable") else { return false }
        return !includeBypass || (current["ExceptionsList"] as? [String] ?? []) ==
            (expected["ExceptionsList"] as? [String] ?? [])
    }

    public static func usesLoopback(_ current: [String: Any], httpPort: Int, all: Bool = false) -> Bool {
        let checks = protocols.map { item in
            let key = item.name
            return enabled(current, key + "Enable")
                && current[key + "Proxy"] as? String == "127.0.0.1"
                && port(current, key + "Port") == httpPort + (key == "SOCKS" ? 1 : 0)
        }
        if !all { return checks.contains(true) }
        return !checks.contains(false) && !enabled(current, "ProxyAutoConfigEnable")
            && !enabled(current, "ProxyAutoDiscoveryEnable")
    }

    public static func desiredBypass(_ baseline: [String], automatic: [String], forced: [String]) -> [String] {
        var seen = Set<String>()
        return (baseline + automatic).filter { pattern in
            let normalized = pattern.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let domain = normalized.trimmingCharacters(in: CharacterSet(charactersIn: "*."))
            let wildcard = normalized.hasPrefix("*.") || normalized.hasPrefix(".")
            guard forced.isEmpty || normalized != "*" else { return false }
            return !forced.contains {
                domain == $0 || domain.hasSuffix("." + $0) || (wildcard && $0.hasSuffix("." + domain))
            } && seen.insert(normalized).inserted
        }
    }

    public static func restoreBypass(current: [String], original: [String], managed: [String]) -> [String] {
        let addedByHarbor = Set(managed).subtracting(original)
        let removedByHarbor = Set(original).subtracting(managed)
        if current == managed { return original }
        if current == original { return original }
        return current.filter { !addedByHarbor.contains($0) }
            + original.filter { removedByHarbor.contains($0) && !current.contains($0) }
    }

    public static func restoreValues(
        current: [String: Any], original: [String: Any], managed: [String: Any]
    ) -> [String: Any] {
        var result = current
        for item in protocols {
            let key = item.name
            if enabled(managed, key + "Enable"),
               let host = managed[key + "Proxy"] as? String,
               current[key + "Proxy"] as? String == host,
               let number = port(managed, key + "Port"), port(current, key + "Port") == number {
                result[key + "Proxy"] = original[key + "Proxy"]
                result[key + "Port"] = original[key + "Port"]
                if enabled(current, key + "Enable") == enabled(managed, key + "Enable") {
                    result[key + "Enable"] = original[key + "Enable"]
                }
            }
        }
        result["ExceptionsList"] = restoreBypass(
            current: current["ExceptionsList"] as? [String] ?? [],
            original: original["ExceptionsList"] as? [String] ?? [],
            managed: managed["ExceptionsList"] as? [String] ?? []
        )
        return result
    }

    /// A command failure can leave a mix of original and Harbor values. Permit
    /// recovery only when every tracked field still belongs to that transition.
    public static func recoverable(
        _ current: [String: Any], original: [String: Any], managed: [String: Any]
    ) -> Bool {
        let keys = ["HTTPEnable", "HTTPProxy", "HTTPPort", "HTTPSEnable", "HTTPSProxy", "HTTPSPort",
                    "SOCKSEnable", "SOCKSProxy", "SOCKSPort", "ProxyAutoConfigEnable",
                    "ProxyAutoDiscoveryEnable", "ExceptionsList"]
        return keys.allSatisfy { key in
            if key.hasSuffix("Enable") || key == "ProxyAutoDiscoveryEnable" {
                let value = enabled(current, key)
                return value == enabled(original, key) || value == enabled(managed, key)
            }
            if key == "ExceptionsList" {
                let value = current[key] as? [String] ?? []
                return value == (original[key] as? [String] ?? []) ||
                    value == (managed[key] as? [String] ?? [])
            }
            return same(current[key], original[key]) || same(current[key], managed[key])
        }
    }

    /// Arguments exclude the network-service name, inserted by the caller.
    /// nil means networksetup cannot represent the requested active settings.
    public static func commands(current: [String: Any], desired: [String: Any]) -> [[String]]? {
        var result: [[String]] = []
        for item in protocols {
            let key = item.name
            let shouldEnable = enabled(desired, key + "Enable")
            let host = desired[key + "Proxy"] as? String
            let desiredPort = port(desired, key + "Port")
            let addressChanged = !same(current[key + "Proxy"], desired[key + "Proxy"]) ||
                !same(current[key + "Port"], desired[key + "Port"])
            var setAddress = false
            if addressChanged, let host, !host.isEmpty,
               let desiredPort, (1...65535).contains(desiredPort) {
                result.append([item.set, host, String(desiredPort)])
                setAddress = true
            } else if shouldEnable && (host?.isEmpty != false ||
                                      !(1...65535).contains(desiredPort ?? 0)) {
                return nil
            }
            if (setAddress && !shouldEnable) || enabled(current, key + "Enable") != shouldEnable {
                result.append([item.state, shouldEnable ? "on" : "off"])
            }
        }
        let bypass = desired["ExceptionsList"] as? [String] ?? []
        if bypass != (current["ExceptionsList"] as? [String] ?? []) {
            result.append(["-setproxybypassdomains"] + (bypass.isEmpty ? ["Empty"] : bypass))
        }
        for (key, command) in [("ProxyAutoConfigEnable", "-setautoproxystate"),
                               ("ProxyAutoDiscoveryEnable", "-setproxyautodiscovery")] {
            if enabled(current, key) != enabled(desired, key) {
                guard !enabled(desired, key) else { return nil }
                result.append([command, "off"])
            }
        }
        return result
    }
}
