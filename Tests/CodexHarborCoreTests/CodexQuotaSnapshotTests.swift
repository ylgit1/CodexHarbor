import Foundation
import Testing
@testable import CodexHarborCore

@Suite("Codex account quota parsing")
struct CodexQuotaSnapshotTests {
    @Test func parsesCodexWindowsByDuration() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": [
                "other": ["primary": ["windowDurationMins": 300, "usedPercent": 99]],
                "codex": [
                    "secondary": ["windowDurationMins": 300, "usedPercent": 14, "resetsAt": 1793880000],
                    "primary": ["windowDurationMins": 10080, "usedPercent": 22, "resetsAt": 1794100000]
                ]
            ]
        ]
        let snapshot = try #require(CodexQuotaSnapshot.parse(response))
        #expect(snapshot.fiveHours?.durationMinutes == 300)
        #expect(snapshot.weekly?.durationMinutes == 10080)
        #expect(snapshot.fiveHours?.remainingPercent == 86)
        #expect(snapshot.weekly?.remainingPercent == 78)
        #expect(snapshot.fiveHours?.resetDate == Date(timeIntervalSince1970: 1793880000))
    }

    @Test func parsesPlanAndOptionalResetCredits() throws {
        let response: [String: Any] = [
            "planType": "plus",
            "rateLimits": [
                "limitId": "codex",
                "primary": ["windowDurationMins": 300, "usedPercent": 19],
                "secondary": ["windowDurationMins": 10080, "usedPercent": 23]
            ],
            "rateLimitResetCredits": [
                "availableCount": 2,
                "credits": [
                    ["status": "available", "resetType": "codexRateLimits", "expiresAt": 1794000000],
                    ["status": "expired", "resetType": "codexRateLimits", "expiresAt": 1793000000]
                ]
            ]
        ]
        let snapshot = try #require(CodexQuotaSnapshot.parse(response))
        #expect(snapshot.planType == "plus")
        #expect(snapshot.resetCreditsAvailable == 2)
        #expect(snapshot.resetCreditsExpiry == Date(timeIntervalSince1970: 1794000000))
        #expect(snapshot.fiveHours?.remainingPercent == 81)
        #expect(snapshot.weekly?.remainingPercent == 77)
    }

    @Test func usesLegacyResponseWhenOtherLimitsExist() throws {
        let response: [String: Any] = [
            "rateLimitsByLimitId": ["spark": ["limitId": "spark"]],
            "rateLimits": ["limitId": "codex", "primary": [
                "windowDurationMins": 300, "usedPercent": 35.5
            ]]
        ]
        let snapshot = try #require(CodexQuotaSnapshot.parse(response))
        #expect(snapshot.fiveHours?.remainingPercent == 64.5)
        #expect(snapshot.weekly == nil)
    }

    @Test func rejectsUnrelatedOrCorruptPercentages() {
        #expect(CodexQuotaSnapshot.parse([
            "rateLimits": ["limitId": "other", "primary": [
                "windowDurationMins": 300,"usedPercent": 30
            ]]
        ]) == nil)
        #expect(CodexQuotaSnapshot.parse([
            "rateLimits": ["primary": ["windowDurationMins": 300,"usedPercent": 110]]
        ]) == nil)
        #expect(CodexQuotaSnapshot.parse([:]) == nil)
    }
}
