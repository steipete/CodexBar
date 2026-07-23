import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCalendarTests {
    @Test
    func `day keys remain Gregorian under a Buddhist calendar`() throws {
        let bangkok = try #require(TimeZone(identifier: "Asia/Bangkok"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = bangkok
        let date = try #require(gregorian.date(from: DateComponents(
            timeZone: bangkok,
            year: 2026,
            month: 7,
            day: 23,
            hour: 12)))

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok
        #expect(buddhist.component(.year, from: date) == 2569)

        let range = CostUsageScanner.CostUsageDayRange(since: date, until: date, calendar: buddhist)
        #expect(range.sinceKey == "2026-07-23")
        #expect(range.untilKey == "2026-07-23")
        #expect(range.scanSinceKey == "2026-07-22")
        #expect(range.scanUntilKey == "2026-07-24")
        #expect(CostUsageScanner.dayKeyFromTimestamp(
            "2026-07-23T05:00:00Z",
            calendar: buddhist) == "2026-07-23")
        #expect(CostUsageScanner.dayKeyFromParsedISO(
            "2026-07-23T05:00:00Z",
            calendar: buddhist) == "2026-07-23")

        let parsed = try #require(CostUsageScanner.parseDayKey("2026-07-23", calendar: buddhist))
        #expect(CostUsageScanner.CostUsageDayRange.dayKey(
            from: parsed,
            calendar: buddhist) == "2026-07-23")
    }
}
