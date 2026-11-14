import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

struct DeepSeekMenuBarCostTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 8 * 3600) ?? .gmt
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        self.calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour)) ?? .distantPast
    }

    private func summary(
        period: DeepSeekUsagePeriod,
        updatedAt: Date) -> DeepSeekUsageSummary
    {
        DeepSeekUsageSummary(
            todayTokens: 4_203_896,
            currentMonthTokens: 166_214_238,
            todayCost: 0.797,
            currentMonthCost: 30.1475,
            requestCount: 120,
            currentMonthRequestCount: 2493,
            topModel: "example-model",
            categoryBreakdown: [],
            daily: [
                DeepSeekDailyUsage(date: "2026-11-10", totalTokens: 1000, cost: 0.5, requestCount: 10),
                DeepSeekDailyUsage(date: "2026-11-11", totalTokens: 4_203_896, cost: 0.797, requestCount: 120),
            ],
            currency: "CNY",
            period: period,
            updatedAt: updatedAt)
    }

    @Test
    func `platform daily buckets feed the menu bar today cost token`() {
        let now = self.date(2026, 11, 11)
        let snapshot = self.summary(period: .last30Days, updatedAt: now)
            .toCostUsageTokenSnapshot(calendar: self.calendar)

        #expect(snapshot.currencyCode == "CNY")
        #expect(snapshot.costProvenance == .vendorMetered)
        #expect(snapshot.historyDays == 30)
        #expect(snapshot.historyLabel == nil)
        #expect(snapshot.sessionCostUSD == 0.797)
        #expect(snapshot.sessionTokens == 4_203_896)
        #expect(snapshot.last30DaysCostUSD == 30.1475)
        #expect(snapshot.daily.map(\.date) == ["2026-11-10", "2026-11-11"])
        #expect(MenuBarLayoutCostResolver.todayCostUSD(snapshot: snapshot, now: now, calendar: self.calendar) == 0.797)
    }

    @Test
    func `monthly fallback keeps the month to date label`() {
        let now = self.date(2026, 11, 11)
        let snapshot = self.summary(period: .currentMonth, updatedAt: now)
            .toCostUsageTokenSnapshot(calendar: self.calendar)

        #expect(snapshot.historyLabel == "This month")
        #expect(snapshot.historyDays == 11)
        #expect(MenuBarLayoutCostResolver.todayCostUSD(snapshot: snapshot, now: now, calendar: self.calendar) == 0.797)
    }

    @Test
    func `monthly fallback preserves Gregorian source days with another user calendar`() {
        var calendar = Calendar(identifier: .islamicCivil)
        calendar.timeZone = TimeZone(secondsFromGMT: -12 * 3600) ?? .gmt
        let snapshot = self.summary(period: .currentMonth, updatedAt: Date(timeIntervalSince1970: 1_794_398_400))
            .toCostUsageTokenSnapshot(calendar: calendar)
        #expect(snapshot.historyDays == 11)
        #expect(snapshot.sessionCostUSD == 0.797)
        #expect(snapshot.daily.map(\.date) == ["2026-11-10", "2026-11-11"])
    }

    @Test
    func `a day without reported cost stays unavailable instead of zero`() {
        let now = self.date(2026, 11, 12)
        let summary = DeepSeekUsageSummary(
            todayTokens: 0,
            currentMonthTokens: 166_214_238,
            todayCost: nil,
            currentMonthCost: 30.1475,
            requestCount: 0,
            currentMonthRequestCount: 2493,
            topModel: nil,
            categoryBreakdown: [],
            daily: [
                DeepSeekDailyUsage(date: "2026-11-11", totalTokens: 4_203_896, cost: 0.797, requestCount: 120),
            ],
            currency: "CNY",
            updatedAt: now)
        let snapshot = summary.toCostUsageTokenSnapshot(calendar: self.calendar)

        #expect(MenuBarLayoutCostResolver.todayCostUSD(snapshot: snapshot, now: now, calendar: self.calendar) == nil)
    }
}
