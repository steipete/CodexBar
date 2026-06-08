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

    // MARK: - Workday-aware pace

    @Test
    func `workday aware pace shows on track for five day user on friday`() {
        // Window: Sun Jun 7 00:00 → Sun Jun 14 00:00 (7 days).
        // "now" is Friday Jun 12 18:00 → elapsed = 5.75 days.
        // 7-day linear: expected ≈ 82.1%, actual = 100% → ~18% deficit.
        // 5-day workday: Mon-Fri fully elapsed → expected ≈ 100% → on pace.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        // Reset on Sunday Jun 14 00:00
        var resetComponents = DateComponents()
        resetComponents.calendar = calendar
        resetComponents.timeZone = calendar.timeZone
        resetComponents.year = 2026
        resetComponents.month = 6
        resetComponents.day = 14 // Sunday
        resetComponents.hour = 0
        resetComponents.minute = 0
        let resetsAt = calendar.date(from: resetComponents)!

        // "now" is Friday Jun 12 18:00 (30 hours before reset)
        let now = resetsAt.addingTimeInterval(-30 * 3600)

        let window = RateWindow(
            usedPercent: 100,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace7 = UsagePace.weekly(window: window, now: now, workDays: nil)
        let pace5 = UsagePace.weekly(window: window, now: now, workDays: 5)

        // 7-day linear: expected ≈ 82%, actual = 100% → ~18% deficit
        #expect(pace7 != nil)
        #expect(pace7!.deltaPercent > 15)

        // 5-day workday: all workdays fully elapsed → expected ≈ 100% → on pace
        #expect(pace5 != nil)
        #expect(abs(pace5!.deltaPercent) <= 5)
    }

    @Test
    func `workday aware pace shows on track midweek`() {
        // Window: Sun Jun 7 00:00 → Sun Jun 14 00:00.
        // "now" is Wed Jun 10 18:00 → 3 full workdays (Mon-Wed) elapsed of 5.
        // 5-day model: expected ≈ 60%.
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        // Reset on Sunday Jun 14 00:00
        var resetComponents = DateComponents()
        resetComponents.calendar = calendar
        resetComponents.timeZone = calendar.timeZone
        resetComponents.year = 2026
        resetComponents.month = 6
        resetComponents.day = 14 // Sunday
        resetComponents.hour = 0
        resetComponents.minute = 0
        let resetsAt = calendar.date(from: resetComponents)!

        // Wed Jun 10 18:00 (3.25 days before Sat, 3.75 days elapsed)
        // From window start Sun Jun 7: Mon(8), Tue(9), Wed(10) all workdays
        let now = resetsAt.addingTimeInterval(-78 * 3600) // Wed 18:00

        let window = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace5 = UsagePace.weekly(window: window, now: now, workDays: 5)

        // 3 full workdays elapsed out of 5 → expected ≈ 60%
        #expect(pace5 != nil)
        #expect(abs(pace5!.deltaPercent) < 5)
    }

    @Test
    func `workday aware pace falls back to linear when workDays is nil or 7`() {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let paceNil = UsagePace.weekly(window: window, now: now, workDays: nil)
        let pace7 = UsagePace.weekly(window: window, now: now, workDays: 7)
        let paceDefault = UsagePace.weekly(window: window, now: now)

        #expect(paceNil != nil)
        #expect(pace7 != nil)
        #expect(paceDefault != nil)
        // All should produce identical expected values (linear)
        #expect(abs(paceNil!.expectedUsedPercent - paceDefault!.expectedUsedPercent) < 0.01)
        #expect(abs(pace7!.expectedUsedPercent - paceDefault!.expectedUsedPercent) < 0.01)
    }

    @Test
    func `workday aware pace ignores non weekly windows`() {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute session window — workDays should have no effect
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let paceNoWork = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300, workDays: nil)
        let paceWork5 = UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300, workDays: 5)

        #expect(paceNoWork != nil)
        #expect(paceWork5 != nil)
        #expect(abs(paceNoWork!.expectedUsedPercent - paceWork5!.expectedUsedPercent) < 0.01)
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
