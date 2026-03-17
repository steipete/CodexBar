import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct UsagePaceTextTests {
    @Test
    func `weekly pace detail provides left right labels`() throws {
        try AppStrings.withTestingLanguage(.english) {
            let now = Date(timeIntervalSince1970: 0)
            let window = RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil)
            let pace = try #require(UsagePace.weekly(window: window, now: now))

            let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

            #expect(detail.leftLabel == "7% in deficit")
            #expect(detail.rightLabel == "Runs out in 3d")
        }
    }

    @Test
    func `weekly pace detail reports lasts until reset`() throws {
        try AppStrings.withTestingLanguage(.english) {
            let now = Date(timeIntervalSince1970: 0)
            let window = RateWindow(
                usedPercent: 10,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil)
            let pace = try #require(UsagePace.weekly(window: window, now: now))

            let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

            #expect(detail.leftLabel == "33% in reserve")
            #expect(detail.rightLabel == "Lasts until reset")
        }
    }

    @Test
    func `weekly pace summary formats single line text`() throws {
        try AppStrings.withTestingLanguage(.english) {
            let now = Date(timeIntervalSince1970: 0)
            let window = RateWindow(
                usedPercent: 50,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil)
            let pace = try #require(UsagePace.weekly(window: window, now: now))

            let summary = UsagePaceText.weeklySummary(pace: pace, now: now)

            #expect(summary == "Pace: 7% in deficit · Runs out in 3d")
        }
    }

    @Test
    func `weekly pace detail formats rounded risk when available`() {
        AppStrings.withTestingLanguage(.english) {
            let now = Date(timeIntervalSince1970: 0)
            let pace = UsagePace(
                stage: .ahead,
                deltaPercent: 8,
                expectedUsedPercent: 42,
                actualUsedPercent: 50,
                etaSeconds: 2 * 24 * 3600,
                willLastToReset: false,
                runOutProbability: 0.683)

            let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

            #expect(detail.rightLabel == "Runs out in 2d · ≈ 70% run-out risk")
        }
    }

    @Test
    func `weekly pace detail localizes for simplified chinese`() throws {
        try AppStrings.withTestingLanguage(.simplifiedChinese) {
            let now = Date(timeIntervalSince1970: 0)
            let window = RateWindow(
                usedPercent: 10,
                windowMinutes: 10080,
                resetsAt: now.addingTimeInterval(4 * 24 * 3600),
                resetDescription: nil)
            let pace = try #require(UsagePace.weekly(window: window, now: now))

            let detail = UsagePaceText.weeklyDetail(pace: pace, now: now)

            #expect(detail.leftLabel == "预留 33%")
            #expect(detail.rightLabel == "可撑到重置")
        }
    }
}
