import Foundation

public enum ClaudePlatformAWSCostUsageMapping {
    /// Projects the plugin's daily history onto the shared spend catalog and fills the "today" figures.
    ///
    /// The generic plugin mapper leaves the session fields empty because a history window may end on any day.
    /// This plugin always ends its window on the current day in its configured time zone, so that day's entry
    /// is today's usage.
    public static func tokenSnapshot(
        from snapshot: UsageSnapshot,
        localCalendar: Calendar = .current) -> CostUsageTokenSnapshot?
    {
        guard let history = snapshot.costUsage else { return nil }
        let todayKey = Self.usesLocalDays(historyLabel: history.historyLabel)
            ? CostUsageLocalDay.key(from: snapshot.updatedAt, calendar: localCalendar)
            : Self.utcDayKey(snapshot.updatedAt)
        let today = history.daily.first { $0.date == todayKey }
        return CostUsageTokenSnapshot(
            sessionTokens: today?.totalTokens,
            sessionCostUSD: today?.costUSD,
            sessionRequests: today?.requestCount,
            last30DaysTokens: history.last30DaysTokens,
            last30DaysCostUSD: history.last30DaysCostUSD,
            last30DaysRequests: history.last30DaysRequests,
            currencyCode: history.currencyCode,
            historyDays: history.historyDays,
            historyCoverageIsEstablished: history.historyCoverageIsEstablished,
            historyLabel: history.historyLabel,
            meteredCostUSD: history.meteredCostUSD,
            costProvenance: history.costProvenance,
            daily: history.daily,
            updatedAt: history.updatedAt)
    }

    /// The plugin states its day convention in the history label: local days with the default time zone
    /// setting, UTC days otherwise.
    public static func usesLocalDays(historyLabel: String?) -> Bool {
        historyLabel == "Last 30 days (local time)"
    }

    static func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return CostUsageLocalDay.key(from: date, calendar: calendar)
    }
}
