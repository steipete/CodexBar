import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct HistoricalUsageMidnightDSTTests {
    @Test(arguments: [
        ("America/Santiago", 9, 6),
        ("America/New_York", 3, 8),
        ("America/New_York", 11, 1),
        ("UTC", 12, 31),
    ])
    func `backfill retains credits and civil day boundaries`(dateCase: (String, Int, Int)) throws {
        let (zone, month, day) = dateCase
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: zone))
        let first = try #require(calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: 12)))
        let asOf = try #require(calendar.date(byAdding: .day, value: 1, to: first))
        let firstStart = calendar.startOfDay(for: first)
        let secondStart = calendar.startOfDay(for: asOf)
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let breakdown = [(formatter.string(from: first), 23.0), (formatter.string(from: asOf), 12.0)]
            .map { day, credits in
                OpenAIDashboardDailyBreakdown(day: day, services: [], totalCreditsUsed: credits)
            }
        func credits(from start: Date, to end: Date) -> Double {
            HistoricalUsageHistoryStore._creditsUsedForTesting(
                breakdown: breakdown, asOf: asOf, start: start, end: end, calendar: calendar)
        }
        #expect(abs(credits(from: firstStart, to: asOf) - 35) < 0.001)
        #expect(abs(credits(from: firstStart, to: secondStart) - 23) < 0.001)
        #expect(abs(credits(from: secondStart, to: asOf) - 12) < 0.001)
    }
}
