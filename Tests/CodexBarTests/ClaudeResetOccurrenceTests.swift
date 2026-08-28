import CodexBarCore
import Foundation
import Testing

struct ClaudeResetOccurrenceTests {
    @Test
    func `parser preserves both repeated daylight saving times`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        let startOfDay = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 1, hour: 0)))
        let searchStart = try #require(calendar.date(byAdding: .second, value: -1, to: startOfDay))
        let matching = DateComponents(hour: 1, minute: 30, second: 0)
        let first = try #require(calendar.nextDate(
            after: searchStart,
            matching: matching,
            matchingPolicy: .strict,
            repeatedTimePolicy: .first,
            direction: .forward))
        let second = try #require(calendar.nextDate(
            after: searchStart,
            matching: matching,
            matchingPolicy: .strict,
            repeatedTimePolicy: .last,
            direction: .forward))
        let tomorrow = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 11, day: 2, hour: 1, minute: 30)))

        let timeOnlyCases = [
            (now: first.addingTimeInterval(-60), expected: first),
            (now: first.addingTimeInterval(30 * 60), expected: second),
            (now: second.addingTimeInterval(60), expected: tomorrow),
        ]
        for item in timeOnlyCases {
            let parsed = ClaudeStatusProbe.parseResetDate(
                from: "Resets 1:30am (America/New_York)",
                now: item.now)
            #expect(parsed == item.expected)
        }

        let betweenOccurrences = first.addingTimeInterval(30 * 60)
        #expect(ClaudeStatusProbe.parseResetDate(
            from: "Resets Nov 1, 1:30am (America/New_York)",
            now: betweenOccurrences) == second)
        #expect(ClaudeStatusProbe.parseResetDate(
            from: "Resets Nov 1, 1:30am (America/New_York)",
            now: second.addingTimeInterval(60),
            expectedWindow: 7 * 24 * 60 * 60) == second)
        #expect(ClaudeStatusProbe.parseResetDate(
            from: "Resets Nov 1, 2026, 1:30am (America/New_York)",
            now: betweenOccurrences) == second)
        #expect(ClaudeStatusProbe.parseResetDate(
            from: "Resets Nov 1, 2026, 1:30am (America/New_York)",
            now: second.addingTimeInterval(60)) == second)
    }

    @Test
    func `parser searches across leap years`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "UTC"))
        let leapReset = try #require(calendar.date(from: DateComponents(
            year: 2028, month: 2, day: 29, hour: 9)))
        let futureCases = [
            DateComponents(year: 2025, month: 1, day: 1),
            DateComponents(year: 2024, month: 3, day: 1),
        ]
        for nowComponents in futureCases {
            let now = try #require(calendar.date(from: nowComponents))
            #expect(ClaudeStatusProbe.parseResetDate(
                from: "Resets Feb 29, 9am (UTC)",
                now: now) == leapReset)
        }

        let currentLeapReset = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 2, day: 29, hour: 9)))
        let shortlyAfter = try #require(calendar.date(from: DateComponents(
            year: 2024, month: 2, day: 29, hour: 10)))
        #expect(ClaudeStatusProbe.parseResetDate(
            from: "Resets Feb 29, 9am (UTC)",
            now: shortlyAfter,
            expectedWindow: 7 * 24 * 60 * 60) == currentLeapReset)
    }

    @Test
    func `parser keeps explicit years authoritative across supported time forms`() throws {
        let now = try Self.isoDate("2025-01-01T00:00:00Z")
        let cases = [
            (
                text: "Resets Jan 2, 2026, 10:59pm (Europe/Helsinki)",
                expected: "2026-01-02T20:59:00Z"),
            (text: "Resets Jan 2 2026 10pm (UTC)", expected: "2026-01-02T22:00:00Z"),
            (text: "Resets Jan 2, 2026, 22:15 (UTC)", expected: "2026-01-02T22:15:00Z"),
            (text: "Resets Jan 2, 2026, 22 (UTC)", expected: "2026-01-02T22:00:00Z"),
        ]

        for item in cases {
            let expected = try Self.isoDate(item.expected)
            #expect(ClaudeStatusProbe.parseResetDate(
                from: item.text,
                now: now) == expected)
        }

        let afterStatedYear = try Self.isoDate("2027-01-01T00:00:00Z")
        let statedReset = try Self.isoDate(cases[0].expected)
        #expect(ClaudeStatusProbe.parseResetDate(
            from: cases[0].text,
            now: afterStatedYear) == statedReset)
    }

    @Test
    func `parser rejects nonexistent explicit local time`() throws {
        let now = try Self.isoDate("2026-01-01T00:00:00Z")
        #expect(ClaudeStatusProbe.parseResetDate(
            from: "Resets Mar 8, 2026, 2:30am (America/New_York)",
            now: now) == nil)
    }

    private static func isoDate(_ text: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        return try #require(formatter.date(from: text))
    }
}
