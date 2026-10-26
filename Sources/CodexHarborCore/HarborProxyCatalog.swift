import Foundation

/// Presentation metadata inferred from the node label; never a GeoIP claim.
public enum HarborProxyRegion: String, CaseIterable, Sendable {
    case hongKong = "香港", unitedStates = "美国", japan = "日本", singapore = "新加坡"
    case taiwan = "台湾", germany = "德国", unitedKingdom = "英国", korea = "韩国", other = "其他"

    public var flagCode: String? {
        switch self {
        case .hongKong: "hk"
        case .unitedStates: "us"
        case .japan: "jp"
        case .singapore: "sg"
        case .taiwan: "tw"
        case .germany: "de"
        case .unitedKingdom: "gb"
        case .korea: "kr"
        case .other: nil
        }
    }

    public static func infer(from name: String) -> Self {
        let text = name.lowercased()
        let tokens = text.components(separatedBy: .alphanumerics.inverted)
        let aliases: [(Self, [String], [String])] = [
            (.hongKong, ["香港", "hong kong", "hongkong", "🇭🇰"], ["hk", "hkg"]),
            (.unitedStates, ["美国", "united states", "洛杉矶", "纽约", "🇺🇸"], ["us", "usa"]),
            (.japan, ["日本", "tokyo", "osaka", "东京", "大阪", "🇯🇵"], ["jp", "jpn"]),
            (.singapore, ["新加坡", "singapore", "🇸🇬"], ["sg", "sgp"]),
            (.taiwan, ["台湾", "台灣", "taiwan", "台北", "🇹🇼"], ["tw", "twn"]),
            (.germany, ["德国", "germany", "法兰克福", "🇩🇪"], ["de", "deu"]),
            (.unitedKingdom, ["英国", "united kingdom", "london", "伦敦", "🇬🇧"], ["uk", "gb"]),
            (.korea, ["韩国", "korea", "首尔", "🇰🇷"], ["kr", "kor"])
        ]
        return aliases.first { _, names, codes in
            names.contains(where: text.contains) || codes.contains(where: tokens.contains)
        }?.0 ?? .other
    }
}

/// Real-delay probes share one Xray batch, as in v2rayN.
public enum HarborProxyLatencyPolicy {
    public static let parallelCount = 4
    public static let realPingBatchSize = 1_000
    // v2rayN ConnectionHandler.GetRealPingTime uses Global.LocalFetch (5s)
    // for two requests to the configured SpeedPingTestUrl.
    public static let requestTimeoutSeconds = 5
    public static let realPingRequestCount = 2
    public static let realPingPauseMilliseconds = 100
    public static let listenerStartupTimeoutMilliseconds = 3_000
    public static let goodUpperBoundMilliseconds = 1_500
    public static let warningUpperBoundMilliseconds = 2_000
    public static let activeHealthCheckInterval: TimeInterval = 5 * 60
    public static let staleRealResultInterval: TimeInterval = 24 * 60 * 60
    public static let failedRetryIntervals: [TimeInterval] = [10 * 60, 60 * 60, 6 * 60 * 60, 24 * 60 * 60]
}

public enum HarborProxyGeoIPPolicy {
    public static let serverDNSCacheInterval: TimeInterval = 6 * 60 * 60
    public static let exitRefreshInterval: TimeInterval = 7 * 24 * 60 * 60
    public static let exitFailureRetryIntervals: [TimeInterval] = [
        10, 60, 10 * 60, 60 * 60
    ]

    public static func retryInterval(afterFailures failures: Int) -> TimeInterval {
        exitFailureRetryIntervals[min(max(1, failures) - 1, exitFailureRetryIntervals.count - 1)]
    }
    public static let countryCacheInterval: TimeInterval = 30 * 24 * 60 * 60
}

public enum HarborProxyMeasurementLabel {
    public static func measured(_ milliseconds: Int) -> String {
        "\(milliseconds) ms"
    }

    public static let explanation =
        "参照 v2rayN：通过独立 Xray 的 SOCKS5 代理请求同一测速地址两次，显示较低延迟；不等同于下载带宽"
}

public enum HarborProxyRealPingTarget {
    public static let defaultURL = URL(string: "https://www.google.com/generate_204")!

    /// v2rayN 7.17.0 stores the selected real-ping URL in guiNConfig.json.
    /// An absent or malformed local configuration uses its own default URL.
    public static func resolve(v2rayNConfigurationData data: Data?) -> URL {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let speedTest = root["SpeedTestItem"] as? [String: Any],
              let raw = speedTest["SpeedPingTestUrl"] as? String,
              raw.utf8.count <= 2_048,
              let url = URL(string: raw),
              let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return defaultURL }
        return url
    }
}

public struct HarborProxyProbeResult: Codable, Sendable, Equatable {
    public var milliseconds: Int?
    public var checkedAt: Date
    public var realTested: Bool
    public var realFailureReason: String?
    public var realCheckedAt: Date?
    public var consecutiveRealFailures: Int?
    public var succeeded: Bool { milliseconds != nil }
    /// A single transient failure remains visible and is eligible for retry.
    public var isConfirmedUnavailable: Bool {
        realTested && !succeeded && (consecutiveRealFailures ?? 1) >= 2
    }
    public var isAwaitingRetry: Bool {
        realTested && !succeeded && !isConfirmedUnavailable
    }

    public init(milliseconds: Int?, checkedAt: Date = .now,
                realTested: Bool? = nil, realFailureReason: String? = nil,
                realCheckedAt: Date? = nil, consecutiveRealFailures: Int? = nil) {
        self.milliseconds = milliseconds
        self.checkedAt = checkedAt
        self.realTested = realTested ?? (milliseconds != nil)
        self.realFailureReason = realFailureReason
        self.realCheckedAt = realCheckedAt ?? (self.realTested ? checkedAt : nil)
        self.consecutiveRealFailures = consecutiveRealFailures
    }

    public var effectiveRealCheckedAt: Date? {
        realCheckedAt ?? (realTested ? checkedAt : nil)
    }

    public func shouldRetryFailure(now: Date = .now) -> Bool {
        guard realTested, !succeeded, let checked = effectiveRealCheckedAt else { return false }
        let failures = max(1, consecutiveRealFailures ?? 1)
        let index = min(failures - 1, HarborProxyLatencyPolicy.failedRetryIntervals.count - 1)
        return now.timeIntervalSince(checked) >= HarborProxyLatencyPolicy.failedRetryIntervals[index]
    }

    public func isStale(now: Date = .now) -> Bool {
        guard let checked = effectiveRealCheckedAt else { return true }
        return now.timeIntervalSince(checked) >= HarborProxyLatencyPolicy.staleRealResultInterval
    }
}

/// Subscription refreshes keep the first successful latency order. Only a
/// genuinely new profile or a profile whose resolved server IP changed needs
/// another end-to-end probe.
public enum HarborProxySubscriptionRefreshPolicy {
    public static func nodesRequiringProbe(
        previousNodeIDs: Set<String>,
        refreshedNodes: [HarborProxyNode],
        previousResolvedIPs: [String: String],
        currentResolvedIPs: [String: String]
    ) -> Set<String> {
        Set(refreshedNodes.compactMap { node in
            if !previousNodeIDs.contains(node.id) { return node.id }
            let host = node.host.lowercased()
            guard let old = previousResolvedIPs[host],
                  let current = currentResolvedIPs[host], old != current else { return nil }
            return node.id
        })
    }

    public static func initialLatencyOrder(
        _ nodes: [HarborProxyNode],
        results: [String: HarborProxyProbeResult]
    ) -> [HarborProxyNode] {
        let original = Dictionary(uniqueKeysWithValues: nodes.enumerated().map { ($0.element.id, $0.offset) })
        return nodes.sorted { lhs, rhs in
            switch (results[lhs.id]?.milliseconds, results[rhs.id]?.milliseconds) {
            case let (left?, right?) where left != right: return left < right
            case (_?, nil): return true
            case (nil, _?): return false
            default: return (original[lhs.id] ?? 0) < (original[rhs.id] ?? 0)
            }
        }
    }
}

public enum HarborProxyAutomaticName {
    public static let unresolvedRegion = "待识别"

    public static func make(region: String, protocolName: String, sequence: Int) -> String {
        "\(region)-\(protocolName.uppercased())-\(String(format: "%03d", sequence))"
    }

    public static func sequence(from name: String?) -> Int? {
        guard let suffix = name?.split(separator: "-").last,
              suffix.count == 3, let value = Int(suffix), value > 0 else { return nil }
        return value
    }

    /// The IP country shown in the table is also the country used in the
    /// automatic name. Never infer it from a provider's node remark.
    public static func refreshed(
        _ nodes: [HarborProxyNode],
        results _: [String: HarborProxyProbeResult],
        locations: [String: HarborProxyIPLocation],
        exitLocationsByNodeID: [String: HarborProxyIPLocation] = [:]
    ) -> [HarborProxyNode] {
        var usedSequences = Set<Int>()
        var sequencesByID: [String: Int] = [:]
        var nextSequence = (nodes.compactMap { sequence(from: $0.automaticName) }.max() ?? 0) + 1
        for node in nodes {
            guard let sequence = sequence(from: node.automaticName),
                  usedSequences.insert(sequence).inserted else { continue }
            sequencesByID[node.id] = sequence
        }
        for node in nodes where sequencesByID[node.id] == nil {
            while usedSequences.contains(nextSequence) { nextSequence += 1 }
            sequencesByID[node.id] = nextSequence
            usedSequences.insert(nextSequence)
            nextSequence += 1
        }
        return nodes.map { original in
            var node = original
            guard !node.subscriptionID.isEmpty else { return node }
            let region = (exitLocationsByNodeID[node.id]
                ?? locations[node.host.lowercased()])?.displayRegion ?? unresolvedRegion
            node.automaticName = make(
                region: region, protocolName: node.protocolName,
                sequence: sequencesByID[node.id] ?? nextSequence
            )
            return node
        }
    }
}

/// Observed through this node's isolated Xray SOCKS outbound, not by querying
/// the server IP or the user's system-wide proxy. Persist only nonsecret data.
public struct HarborProxyExitLocation: Codable, Equatable, Sendable {
    public let location: HarborProxyIPLocation
    public let endpointSignature: String
    public let observedAt: Date
    public let resolvedServerIP: String?

    public init(location: HarborProxyIPLocation, endpointSignature: String,
                observedAt: Date = .now, resolvedServerIP: String? = nil) {
        self.location = location
        self.endpointSignature = endpointSignature
        self.observedAt = observedAt
        self.resolvedServerIP = resolvedServerIP
    }

    public func verifiedLocation(for node: HarborProxyNode, resolvedServerIP currentIP: String? = nil,
                                 now: Date = .now)
        -> HarborProxyIPLocation? {
        guard !endpointSignature.isEmpty,
              endpointSignature == node.endpointSignature,
              location.verifiedCountryCode != nil else {
            return nil
        }
        if let resolvedServerIP, let currentIP,
           !HarborIPAddress.equivalent(resolvedServerIP, currentIP) { return nil }
        return location
    }

    public func needsRefresh(for node: HarborProxyNode, resolvedServerIP currentIP: String? = nil,
                             now: Date = .now) -> Bool {
        guard verifiedLocation(for: node, resolvedServerIP: currentIP, now: now) != nil else {
            return true
        }
        return resolvedServerIP == nil
            || now.timeIntervalSince(observedAt) >= HarborProxyGeoIPPolicy.exitRefreshInterval
    }
}

/// Cached geolocation describes the node SERVER address, never its egress IP.
public struct HarborProxyIPLocation: Codable, Equatable, Sendable {
    public var ip: String
    public var countryCode: String
    public var locatedAt: Date?

    public init(ip: String, countryCode: String, locatedAt: Date? = .now) {
        self.ip = ip
        self.countryCode = countryCode.uppercased()
        self.locatedAt = locatedAt
    }

    public var countryName: String {
        switch countryCode {
        case "HK": return "香港"
        case "TW": return "台湾"
        case "MO": return "澳门"
        default:
            return Locale(identifier: "zh_CN").localizedString(forRegionCode: countryCode) ?? "其他"
        }
    }

    /// Unknown lookup results must never be recycled as resolved GeoIP data.
    public var verifiedCountryCode: String? {
        countryCode == "ZZ" ? nil : countryCode
    }

    public var displayRegion: String {
        countryCode == "ZZ" ? HarborProxyAutomaticName.unresolvedRegion : countryName
    }

    public var flag: String {
        guard countryCode != "ZZ", countryCode.count == 2,
              countryCode.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return "🌐"
        }
        return String(String.UnicodeScalarView(countryCode.unicodeScalars.compactMap {
            UnicodeScalar(0x1F1E6 + $0.value - 65)
        }))
    }

    public func matches(_ resolvedIP: String) -> Bool {
        HarborIPAddress.equivalent(ip, resolvedIP) && countryCode.count == 2
    }

    public func countryIsFresh(now: Date = .now) -> Bool {
        guard verifiedCountryCode != nil, let locatedAt else { return false }
        return now.timeIntervalSince(locatedAt) < HarborProxyGeoIPPolicy.countryCacheInterval
    }
}

public enum HarborProxyCatalog {
    public static func pageChoices(current: Int, total: Int) -> [Int] {
        let total = max(1, total)
        if total <= 6 { return Array(1...total) }
        let current = min(max(1, current), total)
        if current <= 4 { return [1, 2, 3, 4, 5, 0, total] }
        if current >= total - 3 { return [1, 0] + Array((total - 4)...total) }
        return [1, 0, current - 1, current, current + 1, 0, total]
    }
}
