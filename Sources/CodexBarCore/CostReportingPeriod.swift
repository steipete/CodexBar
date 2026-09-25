import Foundation

/// Calendar selection shared by cost surfaces. Day counts are resolved at the operation boundary.
public enum CostReportingPeriod: Hashable, Sendable, RawRepresentable {
    case rolling(days: Int)
    case monthToDate
    case allTime

    public static let defaultsKey = "costReportingPeriod"
    public static let legacyDaysKey = "tokenCostUsageHistoryDays"

    public init?(rawValue: String) {
        switch rawValue {
        case "month-to-date": self = .monthToDate
        case "all": self = .allTime
        default:
            guard rawValue.hasPrefix("rolling:"), let days = Int(rawValue.dropFirst(8)), days > 0 else { return nil }
            self = .rolling(days: min(365, days))
        }
    }

    public var rawValue: String {
        switch self {
        case let .rolling(days): "rolling:\(days)"
        case .monthToDate: "month-to-date"
        case .allTime: "all"
        }
    }

    public static func migrated(rawValue: String?, legacyDays: Int?) -> Self {
        rawValue.flatMap(Self.init(rawValue:)) ?? .rolling(days: max(1, min(365, legacyDays ?? 30)))
    }

    public var label: String {
        switch self {
        case let .rolling(days): days == 1 ? "Today" : "Last \(days) days"
        case .monthToDate: "Month to date"
        case .allTime: "All"
        }
    }

    public func bounds(now: Date, calendar: Calendar = .current, earliest: Date? = nil) -> ClosedRange<Date> {
        let calendar = CostUsageLocalDay.gregorianCalendar(matching: calendar)
        let end = calendar.startOfDay(for: now)
        let start: Date = switch self {
        case let .rolling(days): calendar.date(byAdding: .day, value: -(max(1, days) - 1), to: end) ?? end
        case .monthToDate: calendar.dateInterval(of: .month, for: now)?.start ?? end
        case .allTime: calendar.startOfDay(for: earliest ?? .distantPast)
        }
        return calendar.startOfDay(for: min(start, end))...end
    }

    public func days(now: Date, calendar: Calendar = .current, earliest: Date? = nil) -> Int {
        let bounds = self.bounds(now: now, calendar: calendar, earliest: earliest)
        return (calendar.dateComponents([.day], from: bounds.lowerBound, to: bounds.upperBound).day ?? 0) + 1
    }

    public func entries(
        _ entries: [CostUsageDailyReport.Entry], now: Date, calendar: Calendar) -> [CostUsageDailyReport.Entry]
    {
        let bounds = self.bounds(now: now, calendar: calendar)
        let start = CostUsageLocalDay.key(from: bounds.lowerBound, calendar: calendar)
        let end = CostUsageLocalDay.key(from: bounds.upperBound, calendar: calendar)
        return entries.filter {
            guard let day = CostUsageTokenSnapshot.localDayKey(for: $0.date, calendar: calendar) else { return false }
            return day >= start && day <= end
        }
    }

    public func identity(now: Date, calendar: Calendar = .current) -> String {
        let bounds = self.bounds(now: now, calendar: calendar)
        return "\(self.rawValue)|\(calendar.timeZone.identifier)|"
            + "\(CostUsageLocalDay.key(from: bounds.lowerBound, calendar: calendar))|"
            + CostUsageLocalDay.key(from: bounds.upperBound, calendar: calendar)
    }
}

extension CostUsageTokenSnapshot {
    public func displayHistoryDays(calendar: Calendar = .current) -> Int {
        guard self.reportingPeriod == .allTime else { return self.historyDays }
        let earliest = self.daily.compactMap {
            Self.localDayKey(for: $0.date, calendar: calendar)
                .flatMap { CostUsageLocalDay.date(fromKey: $0, calendar: calendar) }
        }.min()
        return CostReportingPeriod.allTime.days(
            now: self.updatedAt,
            calendar: calendar,
            earliest: earliest ?? self.updatedAt)
    }

    public var periodLabel: String {
        self.historyLabel ?? self.reportingPeriod?.label ?? CostReportingPeriod.rolling(days: self.historyDays).label
    }

    /// Attach the selection only after a scan of the resolved window, never to a previous-period cache entry.
    public func reporting(_ period: CostReportingPeriod) -> Self {
        if case .rolling = period { return self }
        var result = self
        result.reportingPeriod = period
        result.historyLabel = period.label
        return result
    }

    /// Daily-backed provider reports can cover a billing cycle wider than the selected calendar window.
    public func selecting(_ period: CostReportingPeriod, now: Date, calendar: Calendar) -> Self {
        guard period == .monthToDate else { return self.reporting(period) }
        let bounds = period.bounds(now: now, calendar: calendar)
        let coverage = CostReportingPeriod.rolling(days: self.historyDays).bounds(
            now: self.updatedAt,
            calendar: calendar)
        var result = CostUsageFetcher.tokenSnapshot(
            from: .init(data: period.entries(self.daily, now: now, calendar: calendar), summary: nil),
            now: now,
            historyDays: period.days(now: now, calendar: calendar),
            currencyCode: self.currencyCode,
            calendar: calendar,
            historyCoverageIsEstablished: self.historyCoverageIsEstablished
                && coverage.lowerBound <= bounds.lowerBound && coverage.upperBound >= bounds.upperBound,
            historyScanIsPartial: self.historyScanIsPartial,
            monetaryValuesAreAvailable: self.last30DaysCostUSD != nil || self.daily.contains { $0.costUSD != nil },
            costProvenance: self.costProvenance,
            credentialScopeFingerprint: self.credentialScopeFingerprint,
            updatedAt: self.updatedAt).reporting(period)
        if result.daily.isEmpty, result.historyIsFullyScanned, self.last30DaysRequests != nil {
            result.sessionRequests = 0
            result.last30DaysRequests = 0
        }
        return result
    }
}
