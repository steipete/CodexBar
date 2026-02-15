import CodexBarCore
import Foundation
import Testing

@Suite
struct UsagePaceTests {
    @Test
    func weeklyPace_computesDeltaAndEta() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let pace = UsagePace.weekly(window: window, now: now)

        #expect(pace != nil)
        guard let pace else { return }
        #expect(abs(pace.expectedUsedPercent - 42.857) < 0.01)
        #expect(abs(pace.deltaPercent - 7.143) < 0.01)
        #expect(pace.stage == .ahead)
        #expect(pace.willLastToReset == false)
        #expect(pace.etaSeconds != nil)
        #expect(abs((pace.etaSeconds ?? 0) - (3 * 24 * 3600)) < 1)
    }

    @Test
    func weeklyPace_marksLastsToResetWhenUsageIsLow() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 5,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let pace = UsagePace.weekly(window: window, now: now)

        #expect(pace != nil)
        guard let pace else { return }
        #expect(pace.willLastToReset == true)
        #expect(pace.etaSeconds == nil)
        #expect(pace.stage == .farBehind)
    }

    @Test
    func weeklyPace_hidesWhenResetMissingOrOutsideWindow() {
        let now = Date(timeIntervalSince1970: 0)
        let missing = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: nil,
            resetDescription: nil)
        let tooFar = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(9 * 24 * 3600),
            resetDescription: nil)

        #expect(UsagePace.weekly(window: missing, now: now) == nil)
        #expect(UsagePace.weekly(window: tooFar, now: now) == nil)
    }

    @Test
    func sessionPace_computesDeltaAndEtaFor5HourWindow() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute (5-hour) window, 2 hours remaining => 3 hours elapsed
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300)

        #expect(pace != nil)
        guard let pace else { return }
        // elapsed = 3h of 5h => expected = 60%
        #expect(abs(pace.expectedUsedPercent - 60.0) < 0.01)
        // delta = 50 - 60 = -10 => behind (in reserve)
        #expect(abs(pace.deltaPercent - (-10.0)) < 0.01)
        #expect(pace.stage == .behind)
        #expect(pace.willLastToReset == true)
    }

    @Test
    func weeklyPace_hidesWhenUsageExistsButNoElapsed() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 12,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(7 * 24 * 3600),
            resetDescription: nil)

        let pace = UsagePace.weekly(window: window, now: now)

        #expect(pace == nil)
    }
}
