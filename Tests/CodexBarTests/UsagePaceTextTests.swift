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
}
