import CodexBarCore
import Foundation
import Testing

struct UsagePaceTests {
    @Test
    func `weekly pace computes delta and eta`() {
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
        #expect(pace.runOutProbability == nil)
        #expect(abs((pace.etaSeconds ?? 0) - (3 * 24 * 3600)) < 1)
    }

    @Test
    func `weekly pace marks lasts to reset when usage is low`() {
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
        #expect(pace.runOutProbability == nil)
        #expect(pace.stage == .farBehind)
    }

    @Test
    func `weekly pace hides when reset missing or outside window`() {
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
    func `weekly pace hides when usage exists but no elapsed`() {
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
    func `session pace computes delta and eta for five hour window`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let pace = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300)

        #expect(pace != nil)
        guard let pace else { return }
        #expect(abs(pace.expectedUsedPercent - 60.0) < 0.01)
        #expect(abs(pace.deltaPercent - -10.0) < 0.01)
        #expect(pace.stage == .behind)
        #expect(pace.willLastToReset == true)
    }
}
