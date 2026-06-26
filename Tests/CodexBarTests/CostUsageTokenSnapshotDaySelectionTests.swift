import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTokenSnapshotDaySelectionTests {
    @Test
    func `token snapshot reports zero today when latest history row is stale`() throws {
        let now = try Self.localNoon(year: 2026, month: 5, day: 18)
        let report = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-15",
                    inputTokens: 200,
                    outputTokens: 100,
                    totalTokens: 300,
                    costUSD: 1.5,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: now)

        #expect(snapshot.sessionCostUSD == 0)
        #expect(snapshot.sessionTokens == 0)
        #expect(snapshot.last30DaysCostUSD == 1.5)
        #expect(snapshot.last30DaysTokens == 300)
        #expect(snapshot.currentDayEntry() == nil)
    }

    @Test
    func `token snapshot uses current local day instead of newest historical row`() throws {
        let now = try Self.localNoon(year: 2026, month: 5, day: 18)
        let report = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-17",
                    inputTokens: 200,
                    outputTokens: 100,
                    totalTokens: 300,
                    costUSD: 1.5,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                CostUsageDailyReport.Entry(
                    date: "2026-05-18",
                    inputTokens: 20,
                    outputTokens: 10,
                    totalTokens: 30,
                    costUSD: 0.15,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let snapshot = CostUsageFetcher.tokenSnapshot(from: report, now: now)

        #expect(snapshot.sessionCostUSD == 0.15)
        #expect(snapshot.sessionTokens == 30)
        #expect(snapshot.last30DaysCostUSD == 1.65)
        #expect(snapshot.last30DaysTokens == 330)
    }

    @Test
    func `token snapshot can preserve latest bucket semantics`() throws {
        let now = try Self.localNoon(year: 2026, month: 5, day: 18)
        let report = CostUsageDailyReport(
            data: [
                CostUsageDailyReport.Entry(
                    date: "2026-05-15",
                    inputTokens: 200,
                    outputTokens: 100,
                    totalTokens: 300,
                    costUSD: 1.5,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            summary: nil)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: report,
            now: now,
            useCurrentLocalDayForSession: false)

        #expect(snapshot.sessionCostUSD == 1.5)
        #expect(snapshot.sessionTokens == 300)
    }

    @Test
    func `latest entry ignores invalid calendar dates`() {
        let latest = CostUsageTokenSnapshot.latestEntry(in: [
            CostUsageDailyReport.Entry(
                date: "2026-06-31",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 999,
                costUSD: 9.99,
                modelsUsed: nil,
                modelBreakdowns: nil),
            CostUsageDailyReport.Entry(
                date: "2026-06-30",
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: 100,
                costUSD: 1,
                modelsUsed: nil,
                modelBreakdowns: nil),
        ])

        #expect(latest?.date == "2026-06-30")
    }

    private static func localNoon(year: Int, month: Int, day: Int) throws -> Date {
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        components.hour = 12
        return try #require(components.date)
    }
}
