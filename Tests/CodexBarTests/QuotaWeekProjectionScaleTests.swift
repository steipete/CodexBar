import Foundation
import Testing
@testable import CodexBarCore

struct QuotaWeekProjectionScaleTests {
    @Test
    func `dense exact slices land in the quota week that contains them`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
        // Spans the 2025-10-26 fall-back day, so one local day is 25 hours long.
        let now = try #require(calendar.date(from: DateComponents(year: 2025, month: 11, day: 5, hour: 12)))
        let resetAt = try #require(calendar.date(from: DateComponents(year: 2025, month: 11, day: 7, hour: 9)))
        let historyStart = try #require(calendar.date(byAdding: .day, value: -29, to: calendar.startOfDay(for: now)))

        let sliceCount = 54000
        let step = now.timeIntervalSince(historyStart) / Double(sliceCount)
        let slices = (0..<sliceCount).map { index in
            CostUsageTimedEntry(
                timestamp: historyStart.addingTimeInterval(Double(index) * step),
                totalTokens: index % 7 + 1,
                costUSD: nil)
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [],
            quotaSlices: slices,
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(resetAt: resetAt, now: now, calendar: calendar)

        #expect(weeks.count == 4)
        #expect(snapshot.quotaWeekSummaries(resetAt: resetAt, now: now, calendar: calendar) == weeks)

        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = try #require(TimeZone(identifier: "UTC"))
        let cold = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: nil,
            last30DaysCostUSD: nil,
            daily: [],
            quotaSlices: slices,
            updatedAt: now)
        #expect(
            snapshot.quotaWeekSummaries(resetAt: resetAt, now: now, calendar: utc)
                == cold.quotaWeekSummaries(resetAt: resetAt, now: now, calendar: utc))
        for week in weeks {
            let expected = slices
                .filter { $0.timestamp >= week.start && $0.timestamp < week.end }
                .reduce(0) { $0 + ($1.totalTokens ?? 0) }
            #expect(week.totalTokens == expected)
        }
    }
}
