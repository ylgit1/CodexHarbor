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
    public static let connectTimeoutSeconds = 2
    // v2rayN ConnectionHandler.GetRealPingTime uses Global.LocalFetch (5s)
    // for two requests to the configured SpeedPingTestUrl.
    public static let requestTimeoutSeconds = 5
    public static let realPingRequestCount = 2
    public static let realPingPauseMilliseconds = 100
    public static let listenerStartupTimeoutMilliseconds = 3_000
    public static let goodUpperBoundMilliseconds = 1_500
    public static let warningUpperBoundMilliseconds = 2_000
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
    public var tcpMilliseconds: Int?
    public var checkedAt: Date
    /// A TCP-only probe must never mark HTTPS as failed (or vice versa).
    public var realTested: Bool
    public var tcpTested: Bool
    public var realFailureReason: String?
    public var succeeded: Bool { milliseconds != nil }
    public init(milliseconds: Int?, tcpMilliseconds: Int? = nil, checkedAt: Date = .now,
                realTested: Bool? = nil, tcpTested: Bool? = nil,
                realFailureReason: String? = nil) {
        self.milliseconds = milliseconds
        self.tcpMilliseconds = tcpMilliseconds
        self.checkedAt = checkedAt
        self.realTested = realTested ?? (milliseconds != nil)
        self.tcpTested = tcpTested ?? (tcpMilliseconds != nil)
        self.realFailureReason = realFailureReason
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

    public static func speedTier(milliseconds: Int) -> String {
        if milliseconds < HarborProxyLatencyPolicy.goodUpperBoundMilliseconds { return "高速" }
        if milliseconds < HarborProxyLatencyPolicy.warningUpperBoundMilliseconds { return "中速" }
        return "低速"
    }

    public static func make(region: String, milliseconds: Int, sequence: Int) -> String {
        "\(region)-\(speedTier(milliseconds: milliseconds))-可用-\(String(format: "%03d", sequence))"
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
        results: [String: HarborProxyProbeResult],
        locations: [String: HarborProxyIPLocation]
    ) -> [HarborProxyNode] {
        var sequences: [String: Int] = [:]
        return nodes.map { original in
            var node = original
            guard !node.subscriptionID.isEmpty,
                  let result = results[node.id], result.realTested else { return node }
            node.customName = nil
            guard let milliseconds = result.milliseconds else {
                node.automaticName = nil
                return node
            }
            let region = locations[node.host.lowercased()]?.displayRegion ?? unresolvedRegion
            let base = "\(region)-\(speedTier(milliseconds: milliseconds))-可用"
            let sequence = sequences[base, default: 0] + 1
            sequences[base] = sequence
            node.automaticName = make(
                region: region, milliseconds: milliseconds, sequence: sequence
            )
            return node
        }
    }
}

/// Cached geolocation describes the node SERVER address, never its egress IP.
public struct HarborProxyIPLocation: Codable, Equatable, Sendable {
    public var ip: String
    public var countryCode: String

    public init(ip: String, countryCode: String) {
        self.ip = ip
        self.countryCode = countryCode.uppercased()
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
