import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsagePaceTextTests {
    @Test
    func weeklyPaceDetail_providesLeftRightLabels() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.weeklyDetail(provider: .codex, window: window, now: now)

        #expect(detail?.leftLabel == "7% in deficit")
        #expect(detail?.rightLabel == "Runs out in 3d")
    }

    @Test
    func weeklyPaceDetail_reportsLastsUntilReset() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.weeklyDetail(provider: .codex, window: window, now: now)

        #expect(detail?.leftLabel == "33% in reserve")
        #expect(detail?.rightLabel == "Lasts until reset")
    }

    @Test
    func weeklyPaceSummary_formatsSingleLineText() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let summary = UsagePaceText.weeklySummary(provider: .codex, window: window, now: now)

        #expect(summary == "Pace: 7% in deficit · Runs out in 3d")
    }

    @Test
    func weeklyPaceDetail_hidesWhenResetIsMissing() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: nil)

        let detail = UsagePaceText.weeklyDetail(provider: .codex, window: window, now: now)

        #expect(detail == nil)
    }

    @Test
    func weeklyPaceDetail_hidesWhenResetIsInPastOrTooFar() {
        let now = Date(timeIntervalSince1970: 0)
        let pastWindow = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(-60),
            resetDescription: nil)
        let farFutureWindow = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(9 * 24 * 3600),
            resetDescription: nil)

        #expect(UsagePaceText.weeklyDetail(provider: .codex, window: pastWindow, now: now) == nil)
        #expect(UsagePaceText.weeklyDetail(provider: .codex, window: farFutureWindow, now: now) == nil)
    }

    @Test
    func weeklyPaceDetail_hidesWhenNoElapsedButUsageExists() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 5,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(7 * 24 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.weeklyDetail(provider: .codex, window: window, now: now)

        #expect(detail == nil)
    }

    @Test
    func weeklyPaceDetail_hidesWhenTooEarlyInWindow() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 40,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval((7 * 24 * 3600) - (60 * 60)),
            resetDescription: nil)

        let detail = UsagePaceText.weeklyDetail(provider: .codex, window: window, now: now)

        #expect(detail == nil)
    }

    @Test
    func weeklyPaceDetail_hidesWhenUsageIsDepleted() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 100,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(2 * 24 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.weeklyDetail(provider: .codex, window: window, now: now)

        #expect(detail == nil)
    }

    // MARK: - Session pace (5-hour window)

    @Test
    func sessionPaceDetail_providesLeftRightLabels() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute window, 2h remaining => 3h elapsed out of 5h
        // expected = 60%, actual = 80% => 20% ahead (in deficit)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        #expect(detail != nil)
        #expect(detail?.leftLabel == "20% in deficit")
        #expect(detail?.rightLabel != nil)
        #expect(detail?.stage == .farAhead)
    }

    @Test
    func sessionPaceDetail_reportsLastsUntilReset() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute window, 2h remaining => 3h elapsed
        // expected = 60%, actual = 10% => far behind (in reserve)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        #expect(detail != nil)
        #expect(detail?.leftLabel == "50% in reserve")
        #expect(detail?.rightLabel == "Lasts until reset")
    }

    @Test
    func sessionPaceSummary_formatsSingleLineText() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 80,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let summary = UsagePaceText.sessionSummary(provider: .claude, window: window, now: now)

        #expect(summary != nil)
        #expect(summary?.hasPrefix("Pace:") == true)
    }

    @Test
    func sessionPaceDetail_hidesForUnsupportedProvider() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .zai, window: window, now: now)

        #expect(detail == nil)
    }

    @Test
    func sessionPaceDetail_hidesWhenResetIsMissing() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: nil,
            resetDescription: nil)

        let detail = UsagePaceText.sessionDetail(provider: .claude, window: window, now: now)

        #expect(detail == nil)
    }
}
