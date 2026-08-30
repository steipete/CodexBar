import CodexBarCore
import Foundation
import Testing

struct CostUsageQuotaWeekLinuxTests {
    @Test
    func `rolling weeks match last 7 calendar days when reset is unknown`() {
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-01", cost: 1, tokens: 100),
                Self.entry(day: "2026-07-08", cost: 3, tokens: 300),
                Self.entry(day: "2026-07-09", cost: 2, tokens: 200),
                Self.entry(day: "2026-07-15", cost: 5, tokens: 500),
            ],
            updatedAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 12))

        let weeks = snapshot.quotaWeekSummaries(resetAt: nil, calendar: Self.utcCalendar)
        let current = weeks.first { $0.offset == 0 }
        let last = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 7)
        #expect(current?.totalTokens == 700)
        #expect(current?.entryCount == 2)
        #expect(last?.totalCostUSD == 3)
        #expect(last?.totalTokens == 300)
        #expect(weeks.first { $0.offset == 2 }?.totalCostUSD == 1)
    }

    @Test
    func `quota weeks align to the live weekly reset instead of calendar last 7 days`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-08", cost: 4, tokens: 400),
                Self.entry(day: "2026-07-13", cost: 10, tokens: 1_000),
                Self.entry(day: "2026-07-20", cost: 99, tokens: 9_900),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 10)
        #expect(current?.totalTokens == 1_000)
        #expect(previous?.totalCostUSD == 4)
        #expect(previous?.totalTokens == 400)
        #expect(weeks.contains { $0.totalCostUSD == 99 } == false)
    }

    @Test
    func `stale reset advances by whole weeks until it covers now`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let staleReset = Self.utcDate(year: 2026, month: 7, day: 4, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-08", cost: 3, tokens: 300),
                Self.entry(day: "2026-07-13", cost: 8, tokens: 800),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(resetAt: staleReset, calendar: Self.utcCalendar)
        #expect(weeks.first?.isCurrent == true)
        #expect(weeks.first?.end > now)
        #expect(weeks.first?.totalCostUSD == 8)
        #expect(weeks.first { $0.offset == 1 }?.totalCostUSD == 3)
    }

    @Test
    func `historical weeks outside the scanned history are omitted`() {
        let snapshot = Self.snapshot(
            historyDays: 7,
            daily: [Self.entry(day: "2026-07-15", cost: 5, tokens: 50)],
            updatedAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 12))

        let weeks = snapshot.quotaWeekSummaries(resetAt: nil, calendar: Self.utcCalendar)
        #expect(weeks.map(\.offset) == [0])
        #expect(weeks.first?.totalCostUSD == 5)
    }

    @Test
    func `daily fallback assigns a reset day to exactly one week`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 12, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-11", cost: 6, tokens: 600),
                Self.entry(day: "2026-07-12", cost: 2, tokens: 200),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 2)
        #expect(current?.totalTokens == 200)
        #expect(previous?.totalCostUSD == 6)
        #expect(previous?.totalTokens == 600)
        #expect((current?.totalCostUSD ?? 0) + (previous?.totalCostUSD ?? 0) == 8)
    }

    @Test
    func `hourly buckets split the reset day at the reset instant`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 12, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let hourBefore = Self.utcDate(year: 2026, month: 7, day: 11, hour: 14)
        let hourAtReset = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [
                Self.entry(day: "2026-07-11", cost: 6, tokens: 600),
            ],
            hourly: [
                CostUsageHourlyEntry(hour: hourBefore, totalTokens: 200, costUSD: 2),
                CostUsageHourlyEntry(hour: hourAtReset, totalTokens: 400, costUSD: 4),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let previous = weeks.first { $0.offset == 1 }

        #expect(current?.totalCostUSD == 4)
        #expect(current?.totalTokens == 400)
        #expect(previous?.totalCostUSD == 2)
        #expect(previous?.totalTokens == 200)
        #expect((current?.totalCostUSD ?? 0) + (previous?.totalCostUSD ?? 0) == 6)
        #expect(current?.entryCount == 1)
        #expect(previous?.entryCount == 1)
    }

    @Test
    func `hourly membership is exclusive across adjacent weeks`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 15, hour: 12)
        let resetAt = Self.utcDate(year: 2026, month: 7, day: 18, hour: 15)
        var hours: [CostUsageHourlyEntry] = []
        for day in 8...15 {
            for hour in [0, 14, 15, 23] {
                hours.append(CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: day, hour: hour),
                    totalTokens: 10,
                    costUSD: 1))
            }
        }
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [Self.entry(day: "2026-07-15", cost: Double(hours.count), tokens: hours.count * 10)],
            hourly: hours,
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: resetAt,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            calendar: Self.utcCalendar)
        let counted = weeks.reduce(0) { $0 + $1.entryCount }
        let cost = weeks.compactMap(\.totalCostUSD).reduce(0, +)
        #expect(counted == hours.count)
        #expect(cost == Double(hours.count))
    }

    @Test
    func `session window minutes are ignored for weekly alignment`() {
        let session = RateWindow(
            usedPercent: 10,
            windowMinutes: 5 * 60,
            resetsAt: Self.utcDate(year: 2026, month: 7, day: 15, hour: 18),
            resetDescription: nil)
        #expect(CostUsageTokenSnapshot.quotaWeekReset(from: session) == nil)
        #expect(CostUsageTokenSnapshot.normalizedQuotaWeekMinutes(session.windowMinutes)
            == CostUsageTokenSnapshot.quotaWeekMinutes)
    }

    @Test
    func `merged report keeps hourly buckets and synthesizes daily-only sources`() {
        let hour = Self.utcDate(year: 2026, month: 7, day: 11, hour: 15)
        let native = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: 100,
                    outputTokens: 20,
                    totalTokens: 120,
                    costUSD: 1.2,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil,
            hourly: [CostUsageHourlyEntry(hour: hour, totalTokens: 120, costUSD: 1.2)])
        let pi = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-07-11",
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15,
                    costUSD: 0.3,
                    modelsUsed: ["gpt-5.4"],
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let merged = CostUsageDailyReport.merged([native, pi], calendar: Self.utcCalendar)
        #expect(merged.hourly.count == 2)
        let resetHour = merged.hourly.first { $0.hour == hour }
        let midnight = merged.hourly.first { $0.hour == Self.utcDate(year: 2026, month: 7, day: 11, hour: 0) }
        #expect(resetHour?.costUSD == 1.2)
        #expect(resetHour?.totalTokens == 120)
        #expect(midnight?.costUSD == 0.3)
        #expect(midnight?.totalTokens == 15)
    }

    @Test
    func `observed official and banked resets on the same day become separate windows`() {
        let now = Self.utcDate(year: 2026, month: 7, day: 17, hour: 12)
        let official = Self.utcDate(year: 2026, month: 7, day: 16, hour: 15)
        let banked = Self.utcDate(year: 2026, month: 7, day: 16, hour: 18)
        let liveNext = Self.utcDate(year: 2026, month: 7, day: 23, hour: 18)
        let snapshot = Self.snapshot(
            historyDays: 30,
            daily: [Self.entry(day: "2026-07-16", cost: 6, tokens: 600)],
            hourly: [
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 16, hour: 14),
                    totalTokens: 100,
                    costUSD: 1),
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 16, hour: 16),
                    totalTokens: 200,
                    costUSD: 2),
                CostUsageHourlyEntry(
                    hour: Self.utcDate(year: 2026, month: 7, day: 16, hour: 19),
                    totalTokens: 300,
                    costUSD: 3),
            ],
            updatedAt: now)

        let weeks = snapshot.quotaWeekSummaries(
            resetAt: liveNext,
            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
            observedNextResets: [official],
            now: now,
            calendar: Self.utcCalendar)
        let current = weeks.first { $0.isCurrent }
        let afterOfficial = weeks.first { $0.offset == 1 }
        let beforeOfficial = weeks.first { $0.offset == 2 }

        #expect(current?.start == banked)
        #expect(current?.totalCostUSD == 3)
        #expect(current?.isNominalWeek == true)
        #expect(afterOfficial?.start == official)
        #expect(afterOfficial?.end == banked)
        #expect(afterOfficial?.totalCostUSD == 2)
        #expect(afterOfficial?.isNominalWeek == false)
        #expect(beforeOfficial?.end == official)
        #expect(beforeOfficial?.totalCostUSD == 1)
        #expect(beforeOfficial?.isNominalWeek == true)
    }

    private static func snapshot(
        historyDays: Int,
        daily: [CostUsageDailyReport.Entry],
        hourly: [CostUsageHourlyEntry] = [],
        updatedAt: Date) -> CostUsageTokenSnapshot
    {
        CostUsageTokenSnapshot(
            sessionTokens: daily.last?.totalTokens,
            sessionCostUSD: daily.last?.costUSD,
            last30DaysTokens: daily.compactMap(\.totalTokens).reduce(0, +),
            last30DaysCostUSD: daily.compactMap(\.costUSD).reduce(0, +),
            historyDays: historyDays,
            daily: daily,
            hourly: hourly,
            updatedAt: updatedAt)
    }

    private static func entry(day: String, cost: Double, tokens: Int) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: day,
            inputTokens: nil,
            outputTokens: nil,
            totalTokens: tokens,
            costUSD: cost,
            modelsUsed: nil,
            modelBreakdowns: nil)
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int) -> Date {
        var components = DateComponents()
        components.calendar = self.utcCalendar
        components.timeZone = TimeZone(secondsFromGMT: 0)
        components.year = year
        components.month = month
        components.day = day
        components.hour = hour
        return components.date!
    }

    private static var utcCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }
}
