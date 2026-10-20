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

public struct HarborProxyProbeResult: Sendable, Equatable {
    public var milliseconds: Int?
    public var checkedAt: Date
    public var succeeded: Bool { milliseconds != nil }
    public init(milliseconds: Int?, checkedAt: Date = .now) {
        self.milliseconds = milliseconds
        self.checkedAt = checkedAt
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
