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

/// Real-delay probes are bounded because every concurrent item owns one
/// isolated Xray process and an HTTPS request.
public enum HarborProxyLatencyPolicy {
    public static let parallelCount = 4
    public static let connectTimeoutSeconds = 2
    public static let requestTimeoutSeconds = 5
    public static let listenerStartupTimeoutMilliseconds = 3_000
    public static let goodUpperBoundMilliseconds = 1_500
    public static let warningUpperBoundMilliseconds = 2_000
}

public enum HarborProxyMeasurementLabel {
    public static func measured(_ milliseconds: Int) -> String {
        "\(milliseconds) ms"
    }

    public static let explanation =
        "通过独立 Xray 和节点代理完成 HTTPS 请求的真实延迟；它验证代理可用性，但不等同于下载带宽"
}

public struct HarborProxyProbeResult: Sendable, Equatable {
    public var milliseconds: Int?
    public var tcpMilliseconds: Int?
    public var checkedAt: Date
    /// A TCP-only probe must never mark HTTPS as failed (or vice versa).
    public var realTested: Bool
    public var tcpTested: Bool
    public var succeeded: Bool { milliseconds != nil }
    public init(milliseconds: Int?, tcpMilliseconds: Int? = nil, checkedAt: Date = .now,
                realTested: Bool? = nil, tcpTested: Bool? = nil) {
        self.milliseconds = milliseconds
        self.tcpMilliseconds = tcpMilliseconds
        self.checkedAt = checkedAt
        self.realTested = realTested ?? (milliseconds != nil)
        self.tcpTested = tcpTested ?? (tcpMilliseconds != nil)
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

    public var flag: String {
        guard countryCode.count == 2,
              countryCode.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }) else {
            return "🌐"
        }
        return String(String.UnicodeScalarView(countryCode.unicodeScalars.compactMap {
            UnicodeScalar(0x1F1E6 + $0.value - 65)
        }))
    }

    public func matches(_ resolvedIP: String) -> Bool {
        ip == resolvedIP && countryCode.count == 2
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
