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

    @Test
    func weeklyPace_marksLowConfidenceOnLinearFallbackWhenProfileIsInsufficient() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let pace = UsagePace.weekly(window: window, now: now, profile: .empty)

        #expect(pace != nil)
        guard let pace else { return }
        #expect(pace.model == .linear)
        #expect(pace.confidence == .low)
        #expect(pace.isFallbackLinear == true)
    }

    @Test
    func weeklyPace_usesTimeOfDayProfileWhenConfidenceIsHigh() {
        let now = Date(timeIntervalSince1970: 0)
        let reset = now.addingTimeInterval((4 * 24 * 3600) + (6 * 3600))
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: reset,
            resetDescription: nil)

        let duration = TimeInterval(7 * 24 * 3600)
        let start = reset.addingTimeInterval(-duration)

        var bins = Array(repeating: 0.2, count: UsagePaceProfile.binsPerWeek)
        var cursor = start
        while cursor < now {
            let idx = UsagePaceProfile.binIndex(for: cursor)
            bins[idx] = 2.0
            cursor = cursor.addingTimeInterval(3600)
        }

        let profile = UsagePaceProfile(
            hourlyIntensity: bins,
            sampleCount: 120,
            activeBinCount: UsagePaceProfile.binsPerWeek,
            spanHours: 240)

        let pace = UsagePace.weekly(window: window, now: now, profile: profile)

        #expect(pace != nil)
        guard let pace else { return }
        #expect(pace.model == .timeOfDayProfile)
        #expect(pace.confidence == .high)
        #expect(pace.isFallbackLinear == false)
        #expect(pace.expectedUsedPercent > 55)
    }
}
