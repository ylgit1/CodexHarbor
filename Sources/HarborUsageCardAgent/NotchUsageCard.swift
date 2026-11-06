import AppKit
import Foundation
import SwiftUI
import CodexHarborCore

/// The notch display uses only public macOS window and screen APIs.
/// It never reads or changes ChatGPT's renderer, debug port or application bundle.
@MainActor
final class NotchQuotaModel: ObservableObject {
    @Published var quota: CodexQuotaSnapshot?
    @Published var message = "正在读取额度"
    @Published var hasChatGPT = false
    @Published var lastReadFailed = false
    @Published var displayNow = Date()
    @Published var expanded = false
    @Published var wingWidth: CGFloat = 104
    @Published var notchWidth: CGFloat = 185

    /// Keep the last verified snapshot during brief App Server outages.
    /// Old information is explicitly marked as delayed, never reported as live.
    var hasRecentQuota: Bool {
        guard let quota else { return false }
        return Date().timeIntervalSince(quota.capturedAt) < 900
    }

    var isDelayed: Bool {
        guard let quota else { return false }
        return lastReadFailed || Date().timeIntervalSince(quota.capturedAt) > 150
    }

    /// The hover panel is read-only and grows only when stale data needs an explanation.
    var detailHeight: CGFloat {
        return isDelayed ? 212 : 192
    }

    /// Update displayed reset countdown at low frequency. No animation or rapid timer is needed.
    func advanceDisplay(at now: Date = Date()) {
        if now.timeIntervalSince(displayNow) >= 30 {
            displayNow = now
        }
    }

    func countdown(_ window: CodexQuotaWindow?) -> String? {
        guard hasRecentQuota, let reset = window?.resetDate else { return nil }
        let seconds = max(0, Int(reset.timeIntervalSince(displayNow)))
        if seconds == 0 { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return hours > 0 ? "\(days)天\(hours)时" : "\(days)天" }
        if hours > 0 { return minutes > 0 ? "\(hours)h\(minutes)m" : "\(hours)h" }
        return "\(max(1, (seconds + 59) / 60))m"
    }

    func fullCountdown(_ window: CodexQuotaWindow?) -> String {
        guard hasRecentQuota, let reset = window?.resetDate else { return "重置时间待确认" }
        let seconds = max(0, Int(reset.timeIntervalSince(displayNow)))
        if seconds == 0 { return "即将重置" }
        let days = seconds / 86_400
        let hours = (seconds % 86_400) / 3600
        let minutes = (seconds % 3600) / 60
        if days > 0 { return "\(days)天\(hours)小时后重置" }
        if hours > 0 { return "\(hours)小时\(minutes)分钟后重置" }
        return "\(max(1, (seconds + 59) / 60))分钟后重置"
    }

    func remaining(_ window: CodexQuotaWindow?) -> Double? {
        guard hasRecentQuota, let window else { return nil }
        return window.remainingPercent
    }

    func tint(_ window: CodexQuotaWindow?) -> Color {
        guard let remaining = remaining(window) else { return .gray }
        if remaining < 10 { return Color(red: 0.96, green: 0.35, blue: 0.32) }
        if remaining <= 50 { return Color(red: 1.0, green: 0.74, blue: 0.35) }
        return Color(red: 0.17, green: 0.92, blue: 0.66)
    }

    func text(_ window: CodexQuotaWindow?) -> String {
        guard let remaining = remaining(window) else {
            if quota != nil { return "—" }
            return lastReadFailed ? "重试中" : "读取中"
        }
        return "\(Int(remaining.rounded()))%"
    }
}
