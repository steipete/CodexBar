import CodexBarCore
import Foundation
import Testing

/// Cross-platform tests for the OpenAI dashboard text parser.
///
/// The dashboard renders reset countdowns like "Resets Wednesday at 3pm". The parser
/// converts a textual weekday into the next occurrence of that weekday so it can be
/// formatted into a concrete `Date`. These tests pin down full-weekday-name coverage
/// because the underlying regex previously missed "Wednesday" and "Saturday" (their
/// abbreviations were not long enough to combine with the optional "day" suffix).
@Suite
struct OpenAIDashboardParserLinuxTests {
    private static func fixedNow() -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        // 2026-05-21 is a Thursday in the Gregorian calendar; using a fixed anchor keeps
        // the test deterministic regardless of when it executes.
        return calendar.date(from: DateComponents(year: 2026, month: 5, day: 21))!
    }

    private static func body(forWeekday weekday: String) -> String {
        """
        5h limit
        50% remaining
        Resets \(weekday)
        """
    }

    @Test
    func parsesResetLineForEveryFullWeekdayName() {
        let now = Self.fixedNow()
        for weekday in ["Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday", "Sunday"] {
            let result = OpenAIDashboardParser.parseRateLimits(
                bodyText: Self.body(forWeekday: weekday),
                now: now)
            #expect(
                result.primary?.resetsAt != nil,
                "Expected a parsed resetsAt for weekday \(weekday)")
        }
    }

    @Test
    func parsesResetLineForLowercaseWednesday() {
        let now = Self.fixedNow()
        let result = OpenAIDashboardParser.parseRateLimits(
            bodyText: Self.body(forWeekday: "wednesday"),
            now: now)
        #expect(result.primary?.resetsAt != nil)
    }

    @Test
    func parsesResetLineForLowercaseSaturday() {
        let now = Self.fixedNow()
        let result = OpenAIDashboardParser.parseRateLimits(
            bodyText: Self.body(forWeekday: "saturday"),
            now: now)
        #expect(result.primary?.resetsAt != nil)
    }
}
