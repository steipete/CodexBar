import Foundation

extension DeepSeekUsageSummary {
    public func toCostUsageTokenSnapshot(calendar: Calendar = .current) -> CostUsageTokenSnapshot {
        let isMonthToDate = self.period == .currentMonth
        let calendar = isMonthToDate
            ? CostUsageBucketTimeZone.calendar(identifier: "UTC")
            : CostUsageLocalDay.gregorianCalendar(matching: calendar)
        let entries = self.daily.map { day in
            // The parser already supplies Gregorian day keys in the source's reporting time zone.
            CostUsageDailyReport.Entry(
                date: day.date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: day.totalTokens,
                requestCount: day.requestCount,
                costUSD: day.cost.map { max(0, $0) },
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let todayKey = CostUsageLocalDay.key(from: self.updatedAt, calendar: calendar)
        let today = entries.first { $0.date == todayKey }
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: self.todayCost,
            sessionRequests: today?.requestCount,
            last30DaysTokens: entries.isEmpty ? nil : self.currentMonthTokens,
            last30DaysCostUSD: self.currentMonthCost,
            last30DaysRequests: entries.isEmpty ? nil : self.currentMonthRequestCount,
            currencyCode: self.currency,
            historyDays: isMonthToDate ? calendar.component(.day, from: self.updatedAt) : 30,
            historyLabel: isMonthToDate ? "This month" : nil,
            costProvenance: .vendorMetered,
            daily: entries,
            updatedAt: self.updatedAt)
    }
}
