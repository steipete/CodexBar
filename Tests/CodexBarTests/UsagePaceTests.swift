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
    func `workday aware pace shows on track for five day user on friday`() throws {
        // Window: Sun Jun 7 00:00 → Sun Jun 14 00:00 (7 days).
        // "now" is Friday Jun 12 18:00 → elapsed = 5.75 days.
        // 7-day linear: expected ≈ 82.1%, actual = 100% → ~18% deficit.
        // 5-day workday: Mon-Thu plus 18 hours Friday → expected = 95%.
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
        let resetsAt = try #require(calendar.date(from: resetComponents))

        // "now" is Friday Jun 12 18:00 (30 hours before reset)
        let now = resetsAt.addingTimeInterval(-30 * 3600)

        let window = RateWindow(
            usedPercent: 100,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace7 = try #require(UsagePace.weekly(window: window, now: now, workDays: nil))
        let pace5 = try #require(UsagePace.weekly(window: window, now: now, workDays: 5))

        // 7-day linear: expected ≈ 82%, actual = 100% → ~18% deficit
        #expect(pace7.deltaPercent > 15)

        // 5-day workday: expected = 95%, so 100% actual remains within the on-pace threshold.
        #expect(abs(pace5.expectedUsedPercent - 95) < 0.01)
        #expect(abs(pace5.deltaPercent) <= 5)
    }

    @Test
    func `workday aware pace shows on track midweek`() throws {
        // Window: Sun Jun 7 00:00 → Sun Jun 14 00:00.
        // "now" is Thu Jun 11 00:00 → 3 full workdays (Mon-Wed) elapsed of 5.
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
        let resetsAt = try #require(calendar.date(from: resetComponents))

        // Thu Jun 11 00:00 (3 days before reset).
        let now = resetsAt.addingTimeInterval(-72 * 3600)

        let window = RateWindow(
            usedPercent: 60,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace5 = try #require(UsagePace.weekly(window: window, now: now, workDays: 5))

        // 3 full workdays elapsed out of 5 → expected ≈ 60%
        #expect(abs(pace5.expectedUsedPercent - 60) < 0.01)
        #expect(abs(pace5.deltaPercent) < 0.01)
    }

    @Test
    func `workday aware exhausted quota does not last through weekend`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14)))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 13,
            hour: 12)))
        let window = RateWindow(
            usedPercent: 100,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace = try #require(UsagePace.weekly(window: window, now: now, workDays: 5))

        #expect(pace.willLastToReset == false)
        #expect(pace.etaSeconds == 0)
    }

    @Test
    func `workday aware eta excludes non workday elapsed time`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14)))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 8,
            hour: 12)))
        let window = RateWindow(
            usedPercent: 20,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace = try #require(UsagePace.weekly(window: window, now: now, workDays: 5))

        #expect(pace.willLastToReset == false)
        #expect(abs((pace.etaSeconds ?? 0) - (48 * 3600)) < 1)
    }

    @Test
    func `workday aware pace does not declare zero usage safe before first workday`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14)))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 7,
            hour: 12)))
        let window = RateWindow(
            usedPercent: 0,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace = try #require(UsagePace.weekly(window: window, now: now, workDays: 5))

        #expect(pace.expectedUsedPercent == 0)
        #expect(pace.willLastToReset == false)
        #expect(pace.etaSeconds == nil)
    }

    @Test
    func `workday aware pace splits a non midnight reset at local day boundaries`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .current

        let resetsAt = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 14,
            hour: 20)))
        let now = try #require(calendar.date(from: DateComponents(
            calendar: calendar,
            timeZone: calendar.timeZone,
            year: 2026,
            month: 6,
            day: 8,
            hour: 12)))
        let window = RateWindow(
            usedPercent: 10,
            windowMinutes: 10080,
            resetsAt: resetsAt,
            resetDescription: nil)

        let pace = try #require(UsagePace.weekly(window: window, now: now, workDays: 5))

        // The weekly window starts Sunday at 20:00. Monday 00:00-12:00 is 12 of
        // the week's 120 work hours, so it must contribute 10% despite the reset offset.
        #expect(abs(pace.expectedUsedPercent - 10) < 0.01)
        #expect(abs(pace.deltaPercent) < 0.01)
    }

    @Test
    func `workday aware pace falls back to linear when workDays is nil or 7`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let paceNil = try #require(UsagePace.weekly(window: window, now: now, workDays: nil))
        let pace7 = try #require(UsagePace.weekly(window: window, now: now, workDays: 7))
        let paceDefault = try #require(UsagePace.weekly(window: window, now: now))

        // All should produce identical expected values (linear)
        #expect(abs(paceNil.expectedUsedPercent - paceDefault.expectedUsedPercent) < 0.01)
        #expect(abs(pace7.expectedUsedPercent - paceDefault.expectedUsedPercent) < 0.01)
    }

    @Test
    func `workday aware pace ignores non weekly windows`() throws {
        let now = Date(timeIntervalSince1970: 0)
        // 300-minute session window — workDays should have no effect
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 300,
            resetsAt: now.addingTimeInterval(2 * 3600),
            resetDescription: nil)

        let paceNoWork = try #require(
            UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300, workDays: nil))
        let paceWork5 = try #require(
            UsagePace.weekly(window: window, now: now, defaultWindowMinutes: 300, workDays: 5))

        #expect(abs(paceNoWork.expectedUsedPercent - paceWork5.expectedUsedPercent) < 0.01)
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

    @Test
    func `one work day falls back to linear pace`() throws {
        let now = Date(timeIntervalSince1970: 0)
        let window = RateWindow(
            usedPercent: 50,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(4 * 24 * 3600),
            resetDescription: nil)

        let paceOne = try #require(UsagePace.weekly(window: window, now: now, workDays: 1))
        let paceNil = try #require(UsagePace.weekly(window: window, now: now))

        // workDays == 1 should fall back to linear pace, identical to workDays: nil
        #expect(abs(paceOne.expectedUsedPercent - paceNil.expectedUsedPercent) < 0.01)
    }
}
