import Foundation

/// Plan the exact networksetup calls needed for Harbor's proxy snapshot.
/// The caller supplies a single, verified network service name to every call.
public enum HarborSystemProxyNetworkSetup {
    private static let protocols: [(name: String, set: String, state: String)] = [
        ("HTTP", "-setwebproxy", "-setwebproxystate"),
        ("HTTPS", "-setsecurewebproxy", "-setsecurewebproxystate"),
        ("SOCKS", "-setsocksfirewallproxy", "-setsocksfirewallproxystate")
    ]

    private static func enabled(_ values: [String: Any], _ key: String) -> Bool {
        (values[key] as? NSNumber)?.boolValue == true
    }

    private static func port(_ values: [String: Any], _ key: String) -> Int? {
        (values[key] as? NSNumber)?.intValue
    }

    private static func same(_ lhs: Any?, _ rhs: Any?) -> Bool {
        (lhs as? NSObject) == (rhs as? NSObject)
    }

    public static func matches(_ current: [String: Any], _ expected: [String: Any]) -> Bool {
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
        return (current["ExceptionsList"] as? [String] ?? []) ==
            (expected["ExceptionsList"] as? [String] ?? [])
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
