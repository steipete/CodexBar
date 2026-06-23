import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTodayBucketTests {

    // MARK: - Helpers

    /// Returns a fixed calendar date built from explicit components (UTC).
    private static func fixedDate(
        _ year: Int, _ month: Int, _ day: Int,
        calendar: Calendar = .current) -> Date
    {
        var comps = DateComponents()
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return calendar.date(from: comps)!
    }

    /// Shorthand for yyyy-MM-dd string entries use.
    private static func dayString(_ year: Int, _ month: Int, _ day: Int) -> String {
        String(format: "%04d-%02d-%02d", year, month, day)
    }

    /// A one-day-old entry with modest token/cost values.
    private static func pastEntry(
        year: Int, month: Int, day: Int,
        tokens: Int = 500,
        cost: Double = 0.03) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: dayString(year, month, day),
            inputTokens: tokens / 2,
            outputTokens: tokens / 2,
            totalTokens: tokens,
            requestCount: 3,
            costUSD: cost,
            modelsUsed: ["test-model"],
            modelBreakdowns: nil)
    }

    /// A today-ish entry.
    private static func todayEntry(
        year: Int, month: Int, day: Int) -> CostUsageDailyReport.Entry
    {
        CostUsageDailyReport.Entry(
            date: dayString(year, month, day),
            inputTokens: 120,
            outputTokens: 80,
            totalTokens: 200,
            requestCount: 1,
            costUSD: 0.01,
            modelsUsed: ["todays-model"],
            modelBreakdowns: nil)
    }

    // MARK: - 1. No local-day row → session nil, historical totals preserved

    @Test
    func `token snapshot with past rows only has nil session values but keeps history`() {
        let calendar = Calendar(identifier: .gregorian)
        // "now" is June 22, 2026. The daily rows only go up to June 20.
        let now = Self.fixedDate(2026, 6, 22, calendar: calendar)
        let past = Self.pastEntry(year: 2026, month: 6, day: 20, tokens: 600, cost: 0.04)
        let older = Self.pastEntry(year: 2026, month: 6, day: 19, tokens: 300, cost: 0.02)

        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,      // will be set by the new fetcher logic
            sessionCostUSD: nil,
            last30DaysTokens: 900,    // 600 + 300
            last30DaysCostUSD: 0.06,
            daily: [older, past],
            updatedAt: now)

        // Simulate what CostUsageFetcher.tokenSnapshot does with the new API:
        // it calls currentDayEntry / entry(in:forLocalDayContaining:).
        let todayRow = CostUsageTokenSnapshot.entry(
            in: snapshot.daily,
            forLocalDayContaining: now,
            calendar: calendar)

        // No row for June 22 → todayRow must be nil.
        #expect(todayRow == nil)

        // The entries DO exist for June 19/20.
        let june19Row = CostUsageTokenSnapshot.entry(
            in: snapshot.daily,
            forLocalDayContaining: Self.fixedDate(2026, 6, 19, calendar: calendar),
            calendar: calendar)
        #expect(june19Row?.totalTokens == 300)

        let june20Row = CostUsageTokenSnapshot.entry(
            in: snapshot.daily,
            forLocalDayContaining: Self.fixedDate(2026, 6, 20, calendar: calendar),
            calendar: calendar)
        #expect(june20Row?.totalTokens == 600)

        // Historical totals are still in the snapshot regardless of today.
        #expect(snapshot.last30DaysTokens == 900)
        #expect(snapshot.last30DaysCostUSD == 0.06)
    }

    // MARK: - 2. Local-day row EXISTS → session populated

    @Test
    func `token snapshot with matching local-day row populates session values`() {
        let calendar = Calendar(identifier: .gregorian)
        let now = Self.fixedDate(2026, 6, 22, calendar: calendar)
        let today = Self.todayEntry(year: 2026, month: 6, day: 22)
        let yesterday = Self.pastEntry(year: 2026, month: 6, day: 21, tokens: 400, cost: 0.02)

        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 200,       // pre-populated by fetcher from today's row
            sessionCostUSD: 0.01,
            last30DaysTokens: 600,
            last30DaysCostUSD: 0.03,
            daily: [yesterday, today],
            updatedAt: now)

        let todayRow = CostUsageTokenSnapshot.entry(
            in: snapshot.daily,
            forLocalDayContaining: now,
            calendar: calendar)

        #expect(todayRow != nil)
        #expect(todayRow?.totalTokens == 200)
        #expect(todayRow?.costUSD == 0.01)

        // session fields match the today-row values.
        #expect(snapshot.sessionTokens == 200)
        #expect(snapshot.sessionCostUSD == 0.01)
    }

    // MARK: - 3. latestEntry — always the newest historical row

    @Test
    func `latestEntry returns newest historical row regardless of today`() {
        let e1 = Self.pastEntry(year: 2026, month: 6, day: 18, tokens: 100, cost: 0.01)
        let e2 = Self.pastEntry(year: 2026, month: 6, day: 19, tokens: 200, cost: 0.02)
        let e3 = Self.pastEntry(year: 2026, month: 6, day: 20, tokens: 300, cost: 0.03)
        let entries = [e1, e2, e3]

        let latest = CostUsageTokenSnapshot.latestEntry(in: entries)
        #expect(latest?.date == Self.dayString(2026, 6, 20))
        #expect(latest?.totalTokens == 300)
    }

    @Test
    func `latestEntry returns nil for empty array`() {
        #expect(CostUsageTokenSnapshot.latestEntry(in: []) == nil)
    }

    // MARK: - 4. entry(in:forLocalDayContaining:) boundary accuracy

    @Test
    func `entry for local day matches exact date and returns nil across day boundary`() {
        let calendar = Calendar(identifier: .gregorian)
        let e1 = Self.pastEntry(year: 2026, month: 6, day: 20, tokens: 500, cost: 0.03)
        let e2 = Self.pastEntry(year: 2026, month: 6, day: 21, tokens: 600, cost: 0.04)
        let entries = [e1, e2]

        // Query June 20 → must hit e1.
        let r1 = CostUsageTokenSnapshot.entry(
            in: entries,
            forLocalDayContaining: Self.fixedDate(2026, 6, 20, calendar: calendar),
            calendar: calendar)
        #expect(r1?.totalTokens == 500)

        // Query June 21 → must hit e2.
        let r2 = CostUsageTokenSnapshot.entry(
            in: entries,
            forLocalDayContaining: Self.fixedDate(2026, 6, 21, calendar: calendar),
            calendar: calendar)
        #expect(r2?.totalTokens == 600)

        // Query June 22 (no row) → nil.
        let r3 = CostUsageTokenSnapshot.entry(
            in: entries,
            forLocalDayContaining: Self.fixedDate(2026, 6, 22, calendar: calendar),
            calendar: calendar)
        #expect(r3 == nil)
    }
}
