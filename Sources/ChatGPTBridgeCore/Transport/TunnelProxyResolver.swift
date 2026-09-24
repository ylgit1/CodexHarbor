import Foundation
import SystemConfiguration

public struct TunnelProxyResolution: Sendable {
    public let environment: [String: String]
    public let status: TunnelProxyStatus

    public init(environment: [String: String], status: TunnelProxyStatus) {
        self.environment = environment
        self.status = status
    }
}

public struct TunnelProxyResolver: Sendable {
    public typealias ReachabilityProbe = @Sendable (URL, [String: String]) async -> Bool

    private static let proxyKeys = [
        "HTTPS_PROXY", "https_proxy",
        "HTTP_PROXY", "http_proxy",
        "ALL_PROXY", "all_proxy"
    ]

    private let probe: ReachabilityProbe

    public init(
        probe: @escaping ReachabilityProbe = TunnelProxyResolver.defaultReachabilityProbe
    ) {
        self.probe = probe
    }

    public func resolve(
        strategy: TunnelProxyStrategy,
        controlPlaneURL: URL,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> TunnelProxyResolution {
        let system = systemProxyEnvironment(baseEnvironment: baseEnvironment)
        let direct = directEnvironment(baseEnvironment: baseEnvironment)

        switch strategy {
        case .automatic:
            guard system.detected else {
                let reachable = await probe(controlPlaneURL, direct.environment)
                guard reachable else {
                    throw BridgeError.writeFailed(
                        "网络检测失败：未检测到系统代理，直连 OpenAI Control Plane 不可达；请检查网络、VPN/TUN 或路由设置"
                    )
                }
                return TunnelProxyResolution(
                    environment: direct.environment,
                    status: TunnelProxyStatus(
                        strategy: .automatic,
                        selectedRoute: .direct,
                        systemProxyDetected: false,
                        directReachable: true,
                        message: "未检测到系统代理，已使用直连"
                    )
                )
            }

            let proxyReachable = await probe(controlPlaneURL, system.environment)
            if proxyReachable {
                return TunnelProxyResolution(
                    environment: system.environment,
                    status: TunnelProxyStatus(
                        strategy: .automatic,
                        selectedRoute: .systemProxy,
                        systemProxyDetected: true,
                        systemProxyDescription: system.description,
                        proxyReachable: true,
                        message: "系统代理可用，已自动使用代理"
                    )
                )
            }

            let directReachable = await probe(controlPlaneURL, direct.environment)
            if directReachable {
                return TunnelProxyResolution(
                    environment: direct.environment,
                    status: TunnelProxyStatus(
                        strategy: .automatic,
                        selectedRoute: .direct,
                        systemProxyDetected: true,
                        systemProxyDescription: system.description,
                        proxyReachable: false,
                        directReachable: true,
                        message: "系统代理不可达，已自动切换为直连"
                    )
                )
            }

            throw BridgeError.writeFailed(
                "网络检测失败：系统代理与直连均无法访问 OpenAI Control Plane；可能受 VPN/TUN、路由或代理配置影响"
            )

        case .system:
            guard system.detected else {
                throw BridgeError.writeFailed("代理策略为“系统代理”，但当前 macOS 未检测到可用 HTTP/HTTPS/SOCKS 代理")
            }
            let reachable = await probe(controlPlaneURL, system.environment)
            guard reachable else {
                throw BridgeError.writeFailed(
                    "系统代理无法访问 OpenAI Control Plane；请检查代理进程、端口或切换为“自动/直连”"
                )
            }
            return TunnelProxyResolution(
                environment: system.environment,
                status: TunnelProxyStatus(
                    strategy: .system,
                    selectedRoute: .systemProxy,
                    systemProxyDetected: true,
                    systemProxyDescription: system.description,
                    proxyReachable: true,
                    message: "已按配置使用系统代理"
                )
            )

        case .direct:
            let reachable = await probe(controlPlaneURL, direct.environment)
            guard reachable else {
                throw BridgeError.writeFailed(
                    "直连 OpenAI Control Plane 不可达；请切换为“自动/系统代理”，或检查 VPN/TUN 与路由设置"
                )
            }
            return TunnelProxyResolution(
                environment: direct.environment,
                status: TunnelProxyStatus(
                    strategy: .direct,
                    selectedRoute: .direct,
                    systemProxyDetected: system.detected,
                    systemProxyDescription: system.description,
                    directReachable: true,
                    message: "已按配置忽略系统代理并使用直连"
                )
            )
        }
    }

    public func preferredEnvironment(
        strategy: TunnelProxyStrategy,
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) -> [String: String] {
        switch strategy {
        case .direct:
            directEnvironment(baseEnvironment: baseEnvironment).environment
        case .automatic, .system:
            systemProxyEnvironment(baseEnvironment: baseEnvironment).environment
        }
    }

    private func systemProxyEnvironment(
        baseEnvironment: [String: String]
    ) -> (environment: [String: String], detected: Bool, description: String?) {
        var environment = baseEnvironment
        let explicitValues = Self.proxyKeys.compactMap { key -> String? in
            guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !value.isEmpty else { return nil }
            return value
        }

        if explicitValues.isEmpty,
           let settings = SCDynamicStoreCopyProxies(nil) as? [String: Any] {
            Self.applySystemProxySettings(settings, to: &environment)
        }

        Self.ensureLoopbackBypass(in: &environment)
        let values = Self.proxyKeys.compactMap { environment[$0] }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let descriptions = Array(Set(values.compactMap(Self.sanitizedProxyDescription))).sorted()
        return (
            environment,
            !values.isEmpty,
            descriptions.isEmpty ? nil : descriptions.joined(separator: " · ")
        )
    }

    private func directEnvironment(
        baseEnvironment: [String: String]
    ) -> (environment: [String: String], detected: Bool, description: String?) {
        var environment = baseEnvironment
        for key in Self.proxyKeys {
            environment.removeValue(forKey: key)
        }
        Self.ensureLoopbackBypass(in: &environment)
        return (environment, false, nil)
    }

    private static func applySystemProxySettings(
        _ settings: [String: Any],
        to environment: inout [String: String]
    ) {
        func enabled(_ key: CFString) -> Bool {
            (settings[key as String] as? NSNumber)?.boolValue == true
        }

        func host(_ key: CFString) -> String? {
            guard let raw = settings[key as String] as? String else { return nil }
            let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            return value.isEmpty ? nil : value
        }

        func port(_ key: CFString) -> Int? {
            (settings[key as String] as? NSNumber)?.intValue
        }

        if enabled(kSCPropNetProxiesHTTPEnable),
           let proxyHost = host(kSCPropNetProxiesHTTPProxy),
           let proxyPort = port(kSCPropNetProxiesHTTPPort) {
            let proxy = "http://\(proxyHost):\(proxyPort)"
            environment["HTTP_PROXY"] = proxy
            environment["http_proxy"] = proxy
        }

        if enabled(kSCPropNetProxiesHTTPSEnable),
           let proxyHost = host(kSCPropNetProxiesHTTPSProxy),
           let proxyPort = port(kSCPropNetProxiesHTTPSPort) {
            let proxy = "http://\(proxyHost):\(proxyPort)"
            environment["HTTPS_PROXY"] = proxy
            environment["https_proxy"] = proxy
        }

        if enabled(kSCPropNetProxiesSOCKSEnable),
           let proxyHost = host(kSCPropNetProxiesSOCKSProxy),
           let proxyPort = port(kSCPropNetProxiesSOCKSPort) {
            let proxy = "socks5://\(proxyHost):\(proxyPort)"
            environment["ALL_PROXY"] = proxy
            environment["all_proxy"] = proxy
        }
    }

    private static func ensureLoopbackBypass(in environment: inout [String: String]) {
        let existing = environment["NO_PROXY"] ?? environment["no_proxy"] ?? ""
        let required = ["127.0.0.1", "localhost", "::1"]
        let merged = ([existing] + required)
            .flatMap { $0.split(separator: ",").map(String.init) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let value = Array(Set(merged)).sorted().joined(separator: ",")
        environment["NO_PROXY"] = value
        environment["no_proxy"] = value
    }

    private static func sanitizedProxyDescription(_ value: String) -> String? {
        guard let url = URL(string: value),
              let scheme = url.scheme,
              let host = url.host else {
            return nil
        }
        if let port = url.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public static func defaultReachabilityProbe(
        url: URL,
        environment: [String: String]
    ) async -> Bool {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
            process.arguments = [
                "-q",
                "-sS",
                "-o", "/dev/null",
                "--connect-timeout", "3",
                "--max-time", "5",
                url.absoluteString
            ]
            process.environment = environment
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { process in
                continuation.resume(returning: process.terminationStatus == 0)
            }
            do {
                try process.run()
            } catch {
                continuation.resume(returning: false)
            }
        }
    }
}
