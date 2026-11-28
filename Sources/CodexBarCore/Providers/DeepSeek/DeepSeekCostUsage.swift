import Foundation

extension DeepSeekUsageSummary {
    public func toCostUsageTokenSnapshot(calendar: Calendar = .current) -> CostUsageTokenSnapshot {
        let isMonthToDate = self.period == .currentMonth
        let resolvedCalendar: Calendar = if isMonthToDate {
            CostUsageBucketTimeZone.calendar(identifier: "UTC")
        } else if let offset = self.timeZoneSeconds, TimeZone(secondsFromGMT: offset) != nil {
            CostUsageLocalDay.fixedOffsetGregorianCalendar(secondsFromGMT: offset)
        } else {
            CostUsageLocalDay.gregorianCalendar(matching: calendar)
        }
        let validTokens: (Int) -> Int? = { value in
            value >= 0 ? value : nil
        }
        let validCost: (Double?) -> Double? = { value in
            guard let value, value.isFinite, value.sign != .minus else { return nil }
            return value
        }
        let entries = self.daily.map { day in
            // The parser already supplies Gregorian day keys in the source's reporting time zone.
            CostUsageDailyReport.Entry(
                date: day.date,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: validTokens(day.totalTokens),
                requestCount: validTokens(day.requestCount),
                costUSD: validCost(day.cost),
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        let todayKey = CostUsageLocalDay.key(from: self.updatedAt, calendar: resolvedCalendar)
        let today = entries.first { $0.date == todayKey }
        let historyDays: Int
        let historyCoverageIsEstablished: Bool
        let historyScanIsPartial: Bool
        let coveredDayIntervals: [CostUsageDayInterval]?
        let historyLabel: String?
        if isMonthToDate {
            historyDays = resolvedCalendar.component(.day, from: self.updatedAt)
            historyCoverageIsEstablished = true
            historyScanIsPartial = false
            coveredDayIntervals = nil
            historyLabel = "This month"
        } else if let coverage = self.coverage {
            historyDays = coverage.requestedDays
            historyCoverageIsEstablished = coverage.isComplete
            historyScanIsPartial = coverage.isPartial
            coveredDayIntervals = coverage.coveredIntervals
            if coverage.isPartial || coverage.requestedPeriod == .monthToDate || coverage.isBoundedAll {
                historyLabel = self.periodLabel
            } else {
                historyLabel = nil
            }
        } else {
            historyDays = 30
            historyCoverageIsEstablished = true
            historyScanIsPartial = false
            coveredDayIntervals = nil
            historyLabel = nil
        }
        let hasConfirmedEmptyCoverage = self.coverage.map { $0.coveredDays > 0 } ?? false
        let totalTokens: Int? = entries.isEmpty
            ? (hasConfirmedEmptyCoverage ? validTokens(self.currentMonthTokens) : nil)
            : validTokens(self.currentMonthTokens)
        let totalRequests: Int? = entries.isEmpty
            ? (hasConfirmedEmptyCoverage ? validTokens(self.currentMonthRequestCount) : nil)
            : validTokens(self.currentMonthRequestCount)
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: validCost(self.todayCost),
            sessionRequests: today?.requestCount,
            last30DaysTokens: totalTokens,
            last30DaysCostUSD: validCost(self.currentMonthCost),
            last30DaysRequests: totalRequests,
            currencyCode: self.currency,
            historyDays: historyDays,
            historyCoverageIsEstablished: historyCoverageIsEstablished,
            historyScanIsPartial: historyScanIsPartial,
            coveredDayIntervals: coveredDayIntervals,
            preservesSourceHistoryLabel: true,
            historyLabel: historyLabel,
            costProvenance: .vendorMetered,
            daily: entries,
            updatedAt: self.updatedAt)
    }
}
