import AppKit
import CodexBarCore
import Foundation

/// Presentation only: original accounting and missing-cost semantics stay in the dashboard model.
struct SpendTrendChartModel {
    struct Segment: Identifiable, Equatable {
        let sourceID: String
        let provider: UsageProvider
        let name: String
        let date: Date
        let cost: Double
        var start: Double
        var end: Double

        var id: String {
            "\(self.sourceID):\(self.date.timeIntervalSince1970)"
        }
    }

    struct Bucket: Identifiable, Equatable {
        let date: Date
        let segments: [Segment]
        var total: Double {
            self.segments.last?.end ?? 0
        }

        var id: Date {
            self.date
        }
    }

    let segments: [Segment]
    let buckets: [Bucket]
    let total: Double?
    let domain: ClosedRange<Date>
    let scope: ClosedRange<Date>
    let section: SpendDashboardTrendSection
    let calendar: Calendar
    let unit: Calendar.Component

    init(
        group: SpendDashboardModel.CurrencyGroup,
        section: SpendDashboardTrendSection,
        day: Date?,
        sourceID: String? = nil,
        overviewInterval: DateInterval? = nil)
    {
        self.section = section
        self.calendar = group.calendar
        let points: [(source: (id: String, provider: UsageProvider, name: String), date: Date, cost: Double)]
        if section == .hourly {
            let day = day ?? Self.focusedDay(nil, group: group) ?? group.chartDomain.lowerBound
            let interval = group.calendar.dateInterval(of: .day, for: day)
                ?? DateInterval(start: day, duration: 86400)
            self.domain = interval.start...interval.end
            self.scope = self.domain
            self.unit = .hour
            points = group.hourlyPoints.filter {
                $0.hour >= interval.start && $0.hour < interval.end
            }.map {
                (($0.sourceID, $0.provider, $0.providerName), $0.hour, $0.cost)
            }
        } else {
            self.scope = overviewInterval.map { $0.start...$0.end } ?? group.chartDomain
            self.unit = Self.overviewUnit(in: self.scope, calendar: group.calendar)
            let start = group.calendar.dateInterval(of: self.unit, for: self.scope.lowerBound)?.start
                ?? self.scope.lowerBound
            let end = group.calendar.dateInterval(
                of: self.unit, for: self.scope.upperBound.addingTimeInterval(-1))?.end ?? self.scope.upperBound
            self.domain = start...end
            let scope = self.scope
            points = group.dailyPoints.filter {
                $0.day >= scope.lowerBound && $0.day < scope.upperBound
            }.map {
                (($0.sourceID, $0.provider, $0.providerName), $0.day, $0.cost)
            }
        }
        let filtered = points.filter { sourceID == nil || $0.source.id == sourceID }
        let unit = self.unit
        let grouped = Dictionary(grouping: filtered) {
            group.calendar.dateInterval(of: unit, for: $0.date)?.start ?? $0.date
        }
        self.buckets = grouped.keys.sorted().compactMap { date in
            var end = 0.0
            let sources = Dictionary(grouping: grouped[date] ?? [], by: { $0.source.id })
            let segments = sources.sorted { $0.key < $1.key }.map { _, points in
                let point = points[0]
                let cost = points.reduce(0) { $0 + $1.cost }
                let start = end
                end += cost
                return Segment(
                    sourceID: point.source.id,
                    provider: point.source.provider,
                    name: point.source.name,
                    date: date,
                    cost: cost,
                    start: start,
                    end: end)
            }
            return end.isFinite ? Bucket(date: date, segments: segments) : nil
        }
        self.segments = self.buckets.flatMap(\.segments)
        self.total = self.buckets.count == grouped.count
            ? SpendDashboardModel.safeCostSum(self.buckets.map(\.total)) : nil
    }

    var peak: Bucket? {
        self.buckets.max { $0.total < $1.total }
    }

    var yDomain: ClosedRange<Double> {
        let peak = self.peak?.total ?? 0
        let padded = peak * 1.15
        return 0...max(0.01, padded.isFinite ? padded : peak)
    }

    func emptyStateTitle(group: SpendDashboardModel.CurrencyGroup, sourceID: String?) -> String {
        guard self.section == .daily,
              self.scope.lowerBound >= group.chartDomain.lowerBound,
              self.scope.upperBound <= group.chartDomain.upperBound else { return L("Spend unavailable") }
        let sources = group.providers.filter { sourceID == nil || $0.id == sourceID }
        let days = Self.reportingDayCount(in: self.scope, calendar: self.calendar)
        guard !sources.isEmpty, days > 0 else { return L("Spend unavailable") }
        let periodDays = Self.reportingDayCount(in: group.chartDomain, calendar: self.calendar)
        if sources.allSatisfy({
            $0.totalCost == 0 && !$0.costIsLowerBound && $0.incompleteRequestCount == 0
                && $0.coveredDayCount >= periodDays
        }) { return L("No usage yet") }
        let ids = Set(sources.map(\.id))
        let records = group.dailySummaries.filter { $0.day >= self.scope.lowerBound && $0.day < self.scope.upperBound }
        let isCoveredZero = records.count == days && records.allSatisfy { record in
            let rows = record.providers.filter { ids.contains($0.sourceID) }
            return rows.count == sources.count && rows.allSatisfy {
                $0.totalCost == 0 && !$0.costIsLowerBound && $0.incompleteRequestCount == 0
            }
        }
        return isCoveredZero ? L("No usage yet") : L("Spend unavailable")
    }

    /// Drawable points omit unpriced records; their sum is never an authoritative period total.
    var recordedSpendLabel: String {
        self.section == .hourly ? "Recorded hourly spend" : "Recorded spend"
    }

    var visibleDuration: TimeInterval {
        guard self.unit == .day,
              let start = self.calendar.date(byAdding: .day, value: -31, to: self.domain.upperBound)
        else { return self.domain.upperBound.timeIntervalSince(self.domain.lowerBound) }
        return self.domain.upperBound.timeIntervalSince(max(
            self.domain.lowerBound,
            self.calendar.startOfDay(for: start)))
    }

    var visibleDayCount: Int {
        let days = Self.reportingDayCount(in: self.domain, calendar: self.calendar)
        return self.unit == .day ? min(days, 31) : days
    }

    var needsScrolling: Bool {
        self.unit == .day && Self.reportingDayCount(in: self.domain, calendar: self.calendar) > 32
    }

    static func overviewUnit(in scope: ClosedRange<Date>, calendar: Calendar) -> Calendar.Component {
        let days = Self.reportingDayCount(in: scope, calendar: calendar)
        return days > 180 ? .month : days > 45 ? .weekOfYear : .day
    }

    private static func reportingDayCount(in scope: ClosedRange<Date>, calendar: Calendar) -> Int {
        guard scope.upperBound > scope.lowerBound else { return 0 }
        // Ordinality can advance before midnight on DST days; compare day starts.
        let first = calendar.startOfDay(for: scope.lowerBound)
        let last = calendar.startOfDay(for: max(scope.lowerBound, scope.upperBound.addingTimeInterval(-1)))
        return SpendDashboardModel.dayCount(
            in: first...last,
            calendar: calendar)
    }

    var hourlyTicks: [Date] {
        let ticks = stride(from: 0, to: 24, by: 4).compactMap { hour in
            self.calendar.date(bySettingHour: hour, minute: 0, second: 0, of: self.domain.lowerBound)
        }
        return ticks.filter { $0 >= self.domain.lowerBound && $0 < self.domain.upperBound }
            + [self.domain.upperBound]
    }

    func hourlyAxisText(_ date: Date) -> String {
        date == self.domain.upperBound ? "24:00" : Self.clockText(date, calendar: self.calendar)
    }

    var hourlyTimeZoneText: String {
        let start = Self.utcOffsetText(self.domain.lowerBound, timeZone: self.calendar.timeZone)
        let end = Self.utcOffsetText(self.domain.upperBound.addingTimeInterval(-1), timeZone: self.calendar.timeZone)
        return start == end ? start : "\(start) → \(end)"
    }

    /// Clock notation is language independent; surrounding dates and UI labels remain localized.
    static func clockText(_ date: Date, calendar: Calendar) -> String {
        String(
            format: "%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            calendar.component(.hour, from: date),
            calendar.component(.minute, from: date))
    }

    static func hourText(_ date: Date, calendar: Calendar) -> String {
        "\(self.clockText(date, calendar: calendar)) \(self.utcOffsetText(date, timeZone: calendar.timeZone))"
    }

    static func utcOffsetText(_ date: Date, timeZone: TimeZone) -> String {
        let offset = timeZone.secondsFromGMT(for: date)
        guard offset != 0 else { return "UTC" }
        let minutes = abs(offset) / 60
        return String(
            format: "UTC%@%02d:%02d",
            locale: Locale(identifier: "en_US_POSIX"),
            offset < 0 ? "-" : "+",
            minutes / 60,
            minutes % 60)
    }

    /// No nearest-point fallback: hovering a gap must not silently show a different hour's spend.
    func bucket(at date: Date) -> Bucket? {
        let start = self.calendar.dateInterval(of: self.unit, for: date)?.start
        return self.buckets.first { $0.date == start }
    }

    /// Plot padding can resolve to an adjacent date. Daily inspection must refer to a drawn bucket;
    /// hourly gaps within the selected day still distinguish missing data from recorded zero.
    func inspectionDate(at date: Date) -> Date? {
        guard date >= self.domain.lowerBound, date < self.domain.upperBound else { return nil }
        if self.section == .daily { return self.bucket(at: date)?.date }
        return self.calendar.dateInterval(of: self.unit, for: date)?.start
    }

    func legendProviders(in group: SpendDashboardModel.CurrencyGroup) -> [SpendDashboardModel.ProviderRow] {
        let sourceIDs = Set(self.segments.map(\.sourceID))
        return group.providers.filter { sourceIDs.contains($0.id) }
    }

    func interval(at date: Date) -> DateInterval? {
        guard let interval = self.calendar.dateInterval(of: self.unit, for: date) else { return nil }
        let start = max(interval.start, self.scope.lowerBound)
        let end = min(interval.end, self.scope.upperBound)
        return end > start ? DateInterval(start: start, end: end) : nil
    }

    static func hourlyDays(_ group: SpendDashboardModel.CurrencyGroup) -> [Date] {
        group.hourlyDays
    }

    static func focusedDay(_ day: Date?, group: SpendDashboardModel.CurrencyGroup) -> Date? {
        let days = self.hourlyDays(group)
        return [group.selectedDay, day].compactMap { $0.map { group.calendar.startOfDay(for: $0) } }
            .first(where: days.contains) ?? days.last
    }
}

enum SpendChartPalette {
    /// Source IDs, rather than display labels, keep same-name accounts distinct and colors stable
    /// when a day has no entries for one account or the legend isolates a source.
    static func color(
        sourceID: String,
        provider: UsageProvider,
        providers: [SpendDashboardModel.ProviderRow]) -> NSColor
    {
        let base = ProviderAccentPalette.color(for: provider)
        let color = NSColor(srgbRed: base.red, green: base.green, blue: base.blue, alpha: 1)
        let ids = providers.filter { $0.provider == provider }.map(\.id).sorted()
        guard let index = ids.firstIndex(of: sourceID), index > 0 else { return color }
        var hue: CGFloat = 0
        var saturation: CGFloat = 0
        var brightness: CGFloat = 0
        color.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: nil)
        return NSColor(
            calibratedHue: (hue + CGFloat(index) * 0.17).truncatingRemainder(dividingBy: 1),
            saturation: max(saturation, 0.55),
            brightness: max(0.60, brightness * 0.82),
            alpha: 1)
    }

    static func label(_ row: SpendDashboardModel.ProviderRow, providers: [SpendDashboardModel.ProviderRow]) -> String {
        let duplicates = providers.filter { $0.displayName == row.displayName }.sorted { $0.id < $1.id }
        guard duplicates.count > 1, let index = duplicates.firstIndex(where: { $0.id == row.id }) else {
            return row.displayName
        }
        return "\(row.displayName) · \(codexBarLocalizedInteger(index + 1))"
    }
}

/// Finds the id of the highest-`stackEnd` point per grouping key (day/hour), regardless of how
/// many providers are stacked in that group. Only that point's bar should render a rounded top.
func spendTopOfStackIDs<Point, Key: Hashable>(
    for points: [Point],
    key: (Point) -> Key,
    id: (Point) -> String,
    stackEnd: (Point) -> Double) -> Set<String>
{
    var bestByKey: [Key: (id: String, stackEnd: Double)] = [:]
    for point in points {
        let pointKey = key(point)
        let pointStackEnd = stackEnd(point)
        if let existing = bestByKey[pointKey], existing.stackEnd >= pointStackEnd {
            continue
        }
        bestByKey[pointKey] = (id(point), pointStackEnd)
    }
    return Set(bestByKey.values.map(\.id))
}
