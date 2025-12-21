import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite
struct UsagePaceTextTests {
    @Test
    func weeklyPaceText_includesEtaWhenRunningOutBeforeReset() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let text = UsagePaceText.weekly(provider: .codex, window: window, now: now)

        #expect(text == "Pace: High (+7%) · 3d left")
    }

    @Test
    func weeklyPaceText_showsResetSafeWhenPaceIsSlow() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let text = UsagePaceText.weekly(provider: .codex, window: window, now: now)

        #expect(text == "Pace: Low (-33%) · Lasts to reset")
    }

    @Test
    func weeklyPaceText_hidesWhenResetIsMissing() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: nil)

        let text = UsagePaceText.weekly(provider: .codex, window: window, now: now)

        #expect(text == nil)
    }

    @Test
    func weeklyPaceText_hidesWhenResetIsInPastOrTooFar() {
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

        #expect(UsagePaceText.weekly(provider: .codex, window: pastWindow, now: now) == nil)
        #expect(UsagePaceText.weekly(provider: .codex, window: farFutureWindow, now: now) == nil)
    }

    @Test
    func weeklyPaceText_hidesWhenNoElapsedButUsageExists() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 5,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(7 * 24 * 3600),
            resetDescription: nil)

        let text = UsagePaceText.weekly(provider: .codex, window: window, now: now)

        #expect(text == nil)
    }
}
