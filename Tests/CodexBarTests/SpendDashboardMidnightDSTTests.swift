import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct SpendDashboardMidnightDSTTests {
    @Test(arguments: [6, 7, 11], [false, true])
    func `native model preserves daily keys across midnight DST`(
        septemberDay: Int,
        completeHistory: Bool) throws
    {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let now = try #require(calendar.date(from: DateComponents(
            year: 2026, month: 9, day: septemberDay, hour: 12)))
        let dates = try (0..<365).map { offset in
            let date = try #require(calendar.date(byAdding: .day, value: -offset, to: now))
            return calendar.startOfDay(for: date)
        }
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd"
        let entries = dates.enumerated().map { offset, day in
            CostUsageDailyReport.Entry(
                date: formatter.string(from: day),
                inputTokens: offset + 1,
                outputTokens: 0,
                totalTokens: offset + 1,
                costUSD: 0,
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: nil,
            sessionCostUSD: nil,
            last30DaysTokens: completeHistory ? (1...365).reduce(0, +) : nil,
            last30DaysCostUSD: nil,
            historyDays: 365,
            daily: entries,
            updatedAt: now)
        for requestedDays in [7, 30, 365] {
            let model = SpendDashboardModel.build(
                inputs: [.init(provider: .codex, displayName: "Codex", snapshot: snapshot)],
                requestedDays: requestedDays,
                now: now,
                calendar: calendar)
            #expect(model.tokenActivity.map(\.day) == Array(dates.reversed()))
            #expect(model.tokenActivity.compactMap(\.totalTokens) == Array((1...365).reversed()))
            let group = try #require(model.groups.first)
            #expect(group.dailySummaries.map(\.day) == Array(dates.prefix(requestedDays).reversed()))
            #expect(group.totalTokens == (1...requestedDays).reduce(0, +))
            if completeHistory {
                #expect(group.coveredDayCount == requestedDays)
                #expect(group.dailySummaries.compactMap(\.totalTokens) == Array((1...requestedDays).reversed()))
            }
            let series = SpendActivitySeries.make(from: model.tokenActivity, now: now, calendar: calendar)
            #expect(series.visibleDayCount == 365)
            #expect(series.coveredDayCount == 365)
            #expect(series.daily.reduce(0, +) == (1...365).reduce(0, +))
        }
    }

    @Test
    func `coverage and chart bounds use complete civil days around midnight DST`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Santiago"))
        let transition = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 6, hour: 12)))
        let next = try #require(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7, hour: 12)))
        let nextStart = calendar.startOfDay(for: next)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1,
            sessionCostUSD: 1,
            last30DaysTokens: 2,
            last30DaysCostUSD: 2,
            historyDays: 2,
            historyCoverageIsEstablished: true,
            daily: ["2026-09-06", "2026-09-07"].map {
                .init(
                    date: $0,
                    inputTokens: 1,
                    outputTokens: 0,
                    totalTokens: 1,
                    costUSD: 1,
                    modelsUsed: nil,
                    modelBreakdowns: nil)
            },
            updatedAt: next)
        let covered = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Synthetic Codex", snapshot: snapshot)],
            requestedDays: 2,
            now: next,
            calendar: calendar)
        #expect(covered.groups.first?.coveredDayCount == 2)
        #expect(covered.groups.first?.providers.first?.coveredDayCount == 2)
        let selected = SpendDashboardModel.build(
            inputs: [.init(provider: .codex, displayName: "Synthetic Codex", snapshot: snapshot)],
            requestedDays: 2,
            now: transition,
            calendar: calendar,
            selectedDay: transition)
        #expect(selected.groups.first?.chartDomain.upperBound == nextStart)
        #expect(selected.groups.first?.hourlyChartDomain?.upperBound == nextStart)
    }
}
