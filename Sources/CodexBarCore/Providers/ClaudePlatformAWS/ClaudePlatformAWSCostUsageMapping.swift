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
        let usesLocalDays = Self.usesLocalDays(historyLabel: history.historyLabel)
        let todayKey = usesLocalDays
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
            updatedAt: usesLocalDays
                ? Self.localNoon(onUTCDayOf: history.updatedAt, calendar: localCalendar)
                : history.updatedAt)
    }

    /// The generic plugin mapper stamps a history with noon UTC on its last day. Read as a local day, that
    /// instant is already the next date from UTC+12 eastward, so the same date is rebuilt in the local zone.
    static func localNoon(onUTCDayOf date: Date, calendar: Calendar) -> Date {
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        var day = utcCalendar.dateComponents([.year, .month, .day], from: date)
        day.hour = 12
        return CostUsageLocalDay.gregorianCalendar(matching: calendar).date(from: day) ?? date
    }

    /// The plugin states its day convention in the history label: local days with the default time zone
    /// setting, UTC days otherwise.
    public static func usesLocalDays(historyLabel: String?) -> Bool {
        historyLabel == "Last 30 days"
    }

    /// The label alone is not distinctive, so shared code asks on behalf of a provider.
    public static func usesLocalDays(_ provider: UsageProvider, historyLabel: String?) -> Bool {
        provider == .claudeplatformaws && self.usesLocalDays(historyLabel: historyLabel)
    }

    static func utcDayKey(_ date: Date) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .gmt
        return CostUsageLocalDay.key(from: date, calendar: calendar)
    }
}
