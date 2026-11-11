import Foundation

extension DeepSeekUsageSummary {
    /// Projects Platform-reported daily buckets into the shared cost-usage shape.
    ///
    /// DeepSeek reports vendor-metered spend and token counts per day in its billing currency, but the
    /// provider only surfaced them as detail rows. Menu-bar cost tokens and Usage & Spend read
    /// `CostUsageTokenSnapshot`, so the summary has to be projected instead of parsed out of text.
    /// The preferred Platform endpoints cover a rolling 30-day window; the monthly fallback covers the
    /// current month to date, which keeps that label instead of claiming a 30-day window.
    public func toCostUsageTokenSnapshot(calendar: Calendar = .current) -> CostUsageTokenSnapshot {
        let isMonthToDate = self.period == .currentMonth
        let entries = self.daily.compactMap { day -> CostUsageDailyReport.Entry? in
            guard let dayKey = Self.costUsageDayKey(day.date, calendar: calendar) else { return nil }
            return CostUsageDailyReport.Entry(
                date: dayKey,
                inputTokens: nil,
                outputTokens: nil,
                totalTokens: day.totalTokens,
                requestCount: day.requestCount,
                costUSD: day.cost.map { max(0, $0) },
                modelsUsed: nil,
                modelBreakdowns: nil)
        }
        // `todayCost`/`todayTokens` are already keyed to the local day the fetch observed; prefer them
        // over a lookup so a late-arriving bucket cannot move today's number onto a different row.
        let todayKey = CostUsageLocalDay.key(from: self.updatedAt, calendar: calendar)
        let today = entries.first { $0.date == todayKey }
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens ?? (self.todayTokens > 0 ? self.todayTokens : nil),
            sessionCostUSD: today?.costUSD ?? self.todayCost,
            sessionRequests: today?.requestCount ?? (self.requestCount > 0 ? self.requestCount : nil),
            last30DaysTokens: entries.isEmpty ? nil : self.currentMonthTokens,
            last30DaysCostUSD: self.currentMonthCost,
            last30DaysRequests: entries.isEmpty ? nil : self.currentMonthRequestCount,
            currencyCode: self.currency,
            historyDays: isMonthToDate
                ? Self.monthToDateDayCount(through: self.updatedAt, calendar: calendar)
                : 30,
            historyLabel: isMonthToDate ? "This month" : nil,
            costProvenance: .vendorMetered,
            daily: entries,
            updatedAt: self.updatedAt)
    }

    private static func costUsageDayKey(_ rawDate: String, calendar: Calendar) -> String? {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let date = CostUsageDateParser.parse(trimmed) else { return nil }
        return CostUsageLocalDay.key(from: date, calendar: calendar)
    }

    private static func monthToDateDayCount(through now: Date, calendar: Calendar) -> Int {
        guard let monthStart = calendar.dateInterval(of: .month, for: now)?.start else { return 1 }
        let days = calendar.dateComponents([.day], from: monthStart, to: now).day ?? 0
        return max(1, days + 1)
    }
}
