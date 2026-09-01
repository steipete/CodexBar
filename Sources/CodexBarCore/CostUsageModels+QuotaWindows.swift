import Foundation

extension CostUsageTokenSnapshot {
    public static let quotaWeekMinutes = 7 * 24 * 60

    /// Buckets local cost into consecutive quota windows.
    ///
    /// Pass the live Weekly `resetsAt` / `windowMinutes` to match the quota bar. When reset
    /// metadata is missing, windows fall back to rolling calendar weeks ending tomorrow.
    /// Exact slices use half-open `[start, end)` membership so an event is never counted in two
    /// windows. Legacy hour buckets and daily residuals are treated as intervals; if a reset cuts
    /// such a coarse interval, that interval is omitted instead of guessing its side. Other days
    /// and fully contained buckets in the same window still count.
    ///
    /// `observedNextResets` are previously published Weekly `resetsAt` values (for example from
    /// plan-utilization samples). An elapsed stored next-reset is treated as a real reset instant,
    /// so an official rollover and a later banked reset on the same day become two windows instead
    /// of one 7-day block. Gaps larger than one quota week between those observed resets are filled
    /// with nominal weekly boundaries. `observedResetInstants` are known start times such as a
    /// redeemed reset-credit `redeemedAt`.
    public func quotaWeekSummaries(
        resetAt: Date?,
        windowMinutes: Int? = nil,
        observedNextResets: [Date] = [],
        observedResetInstants: [Date] = [],
        weekCount: Int = 4,
        now: Date? = nil,
        calendar: Calendar = .current) -> [CostUsageQuotaWeek]
    {
        let calendar = CostUsageLocalDay.gregorianCalendar(matching: calendar)
        let now = now ?? self.updatedAt
        let duration = TimeInterval(Self.normalizedQuotaWeekMinutes(windowMinutes) * 60)
        let currentEnd = Self.currentQuotaWeekEnd(
            resetAt: resetAt,
            duration: duration,
            now: now,
            calendar: calendar)
        let historyStart = calendar.date(
            byAdding: .day,
            value: -(max(1, self.historyDays) - 1),
            to: calendar.startOfDay(for: self.updatedAt)) ?? self.updatedAt
        let projectionDays = Self.quotaProjectionDays(
            daily: self.daily,
            quotaSlices: self.quotaSlices,
            hourly: self.hourly,
            calendar: calendar)

        let count = max(1, min(weekCount, 8))
        let boundaries = Self.quotaWeekBoundaries(
            currentEnd: currentEnd,
            observed: (observedNextResets, observedResetInstants),
            weekCount: count,
            now: now,
            stride: QuotaWeekStride(
                duration: duration,
                calendar: calendar,
                usesCalendarFallback: resetAt == nil))
        var weeks: [CostUsageQuotaWeek] = []
        weeks.reserveCapacity(count)
        var offset = 0
        var endIndex = boundaries.count - 1
        while offset < count, endIndex > 0 {
            let end = boundaries[endIndex]
            let start = boundaries[endIndex - 1]
            endIndex -= 1
            // A window that starts before scanned history would report a truncated slice as a
            // complete older week. Keep the current window (it is the live quota) and drop the rest.
            if offset > 0, start < historyStart {
                break
            }
            let projection = Self.projectQuotaWindow(
                start: start,
                end: end,
                days: projectionDays)
            weeks.append(CostUsageQuotaWeek(
                offset: offset,
                start: start,
                end: end,
                totalTokens: projection.totalTokens,
                totalCostUSD: projection.totalCostUSD,
                entryCount: projection.entryCount))
            offset += 1
        }
        return weeks
    }

    public static let quotaWeekBoundaryTolerance: TimeInterval = 2 * 60

    /// Reconstructs quota-window edges from the live next reset plus any previously observed
    /// Weekly `resetsAt` values or known reset instants. Future observed next-reset values
    /// contribute their nominal window start, but are not treated as reset instants until elapsed.
    public static func quotaWeekBoundaries(
        liveNextReset: Date?,
        observedNextResets: [Date],
        observedResetInstants: [Date] = [],
        windowMinutes: Int? = nil,
        weekCount: Int = 4,
        now: Date,
        calendar: Calendar = .current) -> [Date]
    {
        let calendar = CostUsageLocalDay.gregorianCalendar(matching: calendar)
        let duration = TimeInterval(self.normalizedQuotaWeekMinutes(windowMinutes) * 60)
        let currentEnd = self.currentQuotaWeekEnd(
            resetAt: liveNextReset,
            duration: duration,
            now: now,
            calendar: calendar)
        return self.quotaWeekBoundaries(
            currentEnd: currentEnd,
            observed: (observedNextResets, observedResetInstants),
            weekCount: max(1, min(weekCount, 8)),
            now: now,
            stride: QuotaWeekStride(
                duration: duration,
                calendar: calendar,
                usesCalendarFallback: liveNextReset == nil))
    }

    private struct QuotaWeekStride {
        let duration: TimeInterval
        let calendar: Calendar
        let usesCalendarFallback: Bool

        func step(from date: Date, weeks: Int) -> Date {
            if self.usesCalendarFallback {
                return self.calendar.date(byAdding: .day, value: 7 * weeks, to: date)
                    ?? date.addingTimeInterval(self.duration * TimeInterval(weeks))
            }
            return date.addingTimeInterval(self.duration * TimeInterval(weeks))
        }
    }

    private static func quotaWeekBoundaries(
        currentEnd: Date,
        observed: (nextResets: [Date], resetInstants: [Date]),
        weekCount: Int,
        now: Date,
        stride: QuotaWeekStride) -> [Date]
    {
        var dates: [Date] = [
            currentEnd,
            stride.step(from: currentEnd, weeks: -1),
        ]
        dates.reserveCapacity(weekCount + 1 + observed.nextResets.count * 2 + observed.resetInstants.count)
        for next in observed.nextResets {
            // A persisted `resetsAt` in the future is still useful for recovering the
            // corresponding historical window start, but it has not happened yet and must not
            // split the live current window. Once it has elapsed, it is a real reset instant
            // (including an early/banked reset) and becomes an additional boundary.
            dates.append(stride.step(from: next, weeks: -1))
            if next <= now.addingTimeInterval(self.quotaWeekBoundaryTolerance) {
                dates.append(next)
            }
        }
        dates.append(contentsOf: observed.resetInstants)
        let latestAllowed = currentEnd.addingTimeInterval(self.quotaWeekBoundaryTolerance)
        var unique = self.uniqueSortedDates(dates, tolerance: self.quotaWeekBoundaryTolerance)
            .filter { $0 <= latestAllowed }
        // The live reset is authoritative. Ascending tolerance de-duplication otherwise keeps an
        // older observed reset and can make the current window end just before `now`.
        unique.removeAll { abs($0.timeIntervalSince(currentEnd)) < self.quotaWeekBoundaryTolerance }
        unique.append(currentEnd)
        unique.sort()
        unique = self.fillQuotaWeekBoundaryGaps(unique, stride: stride)
        let needed = weekCount + 1
        var previousCount = -1
        while unique.count < needed, stride.duration > 0, unique.count != previousCount, let oldest = unique.first {
            previousCount = unique.count
            unique.insert(stride.step(from: oldest, weeks: -1), at: 0)
            unique = self.uniqueSortedDates(unique, tolerance: self.quotaWeekBoundaryTolerance)
        }
        return unique
    }

    /// Insert nominal weekly ticks inside gaps larger than one quota week, so a 30-day hole
    /// between observed resets does not collapse into a single "previous window". Gaps shorter
    /// than `duration` (official plus banked reset on the same day) stay intact.
    private static func fillQuotaWeekBoundaryGaps(_ dates: [Date], stride: QuotaWeekStride) -> [Date] {
        guard dates.count >= 2, stride.duration > 0 else { return dates }
        var filled: [Date] = []
        filled.reserveCapacity(dates.count)
        filled.append(dates[0])
        for later in dates.dropFirst() {
            var cursor = filled[filled.count - 1]
            while true {
                let next = stride.step(from: cursor, weeks: 1)
                if next <= cursor { break }
                if later.timeIntervalSince(next) <= self.quotaWeekBoundaryTolerance { break }
                filled.append(next)
                cursor = next
            }
            filled.append(later)
        }
        return self.uniqueSortedDates(filled, tolerance: self.quotaWeekBoundaryTolerance)
    }

    private static func uniqueSortedDates(_ dates: [Date], tolerance: TimeInterval) -> [Date] {
        let sorted = dates.sorted()
        var unique: [Date] = []
        unique.reserveCapacity(sorted.count)
        for date in sorted {
            if let last = unique.last, abs(date.timeIntervalSince(last)) < tolerance {
                continue
            }
            unique.append(date)
        }
        return unique
    }

    public static func normalizedQuotaWeekMinutes(_ windowMinutes: Int?) -> Int {
        let week = self.quotaWeekMinutes
        guard let windowMinutes, (week - 24 * 60)...(week + 24 * 60) ~= windowMinutes else {
            return week
        }
        return windowMinutes
    }

    public static func quotaWeekReset(from window: RateWindow?) -> Date? {
        guard let window else { return nil }
        if let minutes = window.windowMinutes {
            let week = self.quotaWeekMinutes
            guard (week - 24 * 60)...(week + 24 * 60) ~= minutes else { return nil }
        }
        return window.resetsAt
    }

    private static func currentQuotaWeekEnd(
        resetAt: Date?,
        duration: TimeInterval,
        now: Date,
        calendar: Calendar) -> Date
    {
        guard duration > 0 else {
            return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
        }
        if let resetAt {
            if resetAt > now {
                return resetAt
            }
            let elapsed = now.timeIntervalSince(resetAt)
            let periods = floor(elapsed / duration) + 1
            return resetAt.addingTimeInterval(periods * duration)
        }
        return calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: now)) ?? now
    }

    private struct QuotaProjectionSlice {
        let start: Date
        /// Nil denotes an exact event. Non-nil denotes a coarse `[start, end)` interval.
        let end: Date?
        let totalTokens: Int?
        let costUSD: Double?

        func overlaps(start windowStart: Date, end windowEnd: Date) -> Bool {
            if let end {
                return self.start < windowEnd && end > windowStart
            }
            return self.start >= windowStart && self.start < windowEnd
        }

        func isContained(start windowStart: Date, end windowEnd: Date) -> Bool {
            if let end {
                return self.start >= windowStart && end <= windowEnd
            }
            return self.start >= windowStart && self.start < windowEnd
        }
    }

    private struct QuotaProjectionDay {
        let start: Date
        let end: Date
        let daily: CostUsageDailyReport.Entry?
        let slices: [QuotaProjectionSlice]

        func overlaps(start windowStart: Date, end windowEnd: Date) -> Bool {
            self.start < windowEnd && self.end > windowStart
        }

        func isContained(start windowStart: Date, end windowEnd: Date) -> Bool {
            self.start >= windowStart && self.end <= windowEnd
        }
    }

    private struct QuotaExactHourAccumulator {
        var totalTokens = 0
        var sawTokens = false
        var tokensAreComplete = true
        var costUSD = 0.0
        var sawCost = false
        var costIsComplete = true

        mutating func add(_ entry: CostUsageTimedEntry) {
            if let tokens = entry.totalTokens, tokens >= 0 {
                let (sum, overflowed) = self.totalTokens.addingReportingOverflow(tokens)
                if overflowed {
                    self.tokensAreComplete = false
                } else {
                    self.totalTokens = sum
                    self.sawTokens = true
                }
            } else {
                self.tokensAreComplete = false
            }
            if let cost = entry.costUSD, cost.isFinite, cost >= 0 {
                let sum = self.costUSD + cost
                if sum.isFinite {
                    self.costUSD = sum
                    self.sawCost = true
                } else {
                    self.costIsComplete = false
                }
            } else {
                self.costIsComplete = false
            }
        }

        var knownTokens: Int? {
            self.sawTokens && self.tokensAreComplete ? self.totalTokens : nil
        }

        var knownCost: Double? {
            self.sawCost && self.costIsComplete ? self.costUSD : nil
        }
    }

    private struct QuotaTokenContribution {
        let isValid: Bool
        let sawValue: Bool
        let value: Int
        let usedDaily: Bool
    }

    private struct QuotaCostContribution {
        let isValid: Bool
        let sawValue: Bool
        let value: Double
        let usedDaily: Bool
    }

    private struct QuotaWindowProjection {
        let totalTokens: Int?
        let totalCostUSD: Double?
        let entryCount: Int
    }

    private enum QuotaReconciliation {
        case exact
        case residual
        case inconsistent
    }

    private static func quotaProjectionDays(
        daily: [CostUsageDailyReport.Entry],
        quotaSlices: [CostUsageTimedEntry],
        hourly: [CostUsageHourlyEntry],
        calendar: Calendar) -> [QuotaProjectionDay]
    {
        var slicesByDay: [String: [QuotaProjectionSlice]] = [:]
        if !quotaSlices.isEmpty {
            for entry in quotaSlices {
                let dayKey = CostUsageLocalDay.key(from: entry.timestamp, calendar: calendar)
                slicesByDay[dayKey, default: []].append(QuotaProjectionSlice(
                    start: entry.timestamp,
                    end: nil,
                    totalTokens: entry.totalTokens,
                    costUSD: entry.costUSD))
            }
            for slice in self.quotaHourlyResidualSlices(
                exact: quotaSlices,
                hourly: hourly,
                calendar: calendar)
            {
                let dayKey = CostUsageLocalDay.key(from: slice.start, calendar: calendar)
                slicesByDay[dayKey, default: []].append(slice)
            }
        } else {
            for entry in hourly {
                let dayKey = CostUsageLocalDay.key(from: entry.hour, calendar: calendar)
                let hourEnd = calendar.date(byAdding: .hour, value: 1, to: entry.hour)
                    ?? entry.hour.addingTimeInterval(60 * 60)
                slicesByDay[dayKey, default: []].append(QuotaProjectionSlice(
                    start: entry.hour,
                    end: hourEnd,
                    totalTokens: entry.totalTokens,
                    costUSD: entry.costUSD))
            }
        }

        var dailyByDay: [String: CostUsageDailyReport.Entry] = [:]
        for entry in daily {
            guard let dayKey = self.quotaLocalDayKey(for: entry.date, calendar: calendar) else { continue }
            dailyByDay[dayKey] = entry
        }

        return Set(dailyByDay.keys).union(slicesByDay.keys)
            .compactMap { dayKey -> QuotaProjectionDay? in
                guard let dayStart = CostUsageLocalDay.date(fromKey: dayKey, calendar: calendar),
                      let dayEnd = calendar.date(byAdding: .day, value: 1, to: dayStart)
                else { return nil }
                return QuotaProjectionDay(
                    start: dayStart,
                    end: dayEnd,
                    daily: dailyByDay[dayKey],
                    slices: (slicesByDay[dayKey] ?? []).sorted { $0.start < $1.start })
            }
            .sorted { $0.start < $1.start }
    }

    private static func quotaLocalDayKey(for rawDate: String, calendar: Calendar) -> String? {
        let trimmed = rawDate.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.count >= 10 {
            let prefix = String(trimmed.prefix(10))
            if prefix.count == 10, prefix[prefix.index(prefix.startIndex, offsetBy: 4)] == "-",
               prefix[prefix.index(prefix.startIndex, offsetBy: 7)] == "-"
            {
                return prefix
            }
        }
        guard let parsed = CostUsageDateParser.parse(trimmed) else { return nil }
        return CostUsageLocalDay.key(from: parsed, calendar: calendar)
    }

    /// Preserve legacy/coarse providers when their hourly data is merged with a newer exact
    /// source. Native scanners publish both views, so only the provable hourly-minus-exact
    /// remainder is retained and no exact usage is counted twice.
    private static func quotaHourlyResidualSlices(
        exact: [CostUsageTimedEntry],
        hourly: [CostUsageHourlyEntry],
        calendar: Calendar) -> [QuotaProjectionSlice]
    {
        var exactByHour: [Date: QuotaExactHourAccumulator] = [:]
        for entry in exact {
            let hourStart = calendar.dateInterval(of: .hour, for: entry.timestamp)?.start
                ?? entry.timestamp
            var accumulator = exactByHour[hourStart] ?? QuotaExactHourAccumulator()
            accumulator.add(entry)
            exactByHour[hourStart] = accumulator
        }

        return hourly.compactMap { entry -> QuotaProjectionSlice? in
            let interval = calendar.dateInterval(of: .hour, for: entry.hour)
            let hourStart = interval?.start ?? entry.hour
            let hourEnd = interval?.end
                ?? calendar.date(byAdding: .hour, value: 1, to: hourStart)
                ?? hourStart.addingTimeInterval(60 * 60)
            let exactHour = exactByHour[hourStart]

            let residualTokens: Int? = {
                guard let hourlyTokens = entry.totalTokens, hourlyTokens >= 0 else { return nil }
                guard let exactHour else { return hourlyTokens }
                guard let exactTokens = exactHour.knownTokens, exactTokens <= hourlyTokens else { return nil }
                return hourlyTokens - exactTokens
            }()
            let residualCost: Double? = {
                guard let hourlyCost = entry.costUSD, hourlyCost.isFinite, hourlyCost >= 0 else { return nil }
                guard let exactHour else { return hourlyCost }
                guard let exactCost = exactHour.knownCost else { return nil }
                let residual = hourlyCost - exactCost
                let tolerance = max(1e-9, abs(hourlyCost) * 1e-9)
                guard residual >= -tolerance else { return nil }
                return abs(residual) <= tolerance ? 0 : residual
            }()

            if residualTokens == 0, residualCost == 0 {
                return nil
            }
            return QuotaProjectionSlice(
                start: hourStart,
                end: hourEnd,
                totalTokens: residualTokens,
                costUSD: residualCost)
        }
    }

    private static func projectQuotaWindow(
        start: Date,
        end: Date,
        days: [QuotaProjectionDay]) -> QuotaWindowProjection
    {
        var totalTokens = 0
        var sawTokens = false
        var tokensAreValid = true
        var totalCost = 0.0
        var sawCost = false
        var costIsValid = true
        var entryCount = 0

        for day in days where day.overlaps(start: start, end: end) {
            let tokenContribution = self.projectQuotaTokens(day: day, start: start, end: end)
            if !tokenContribution.isValid {
                tokensAreValid = false
            } else if tokenContribution.sawValue {
                let (sum, overflowed) = totalTokens.addingReportingOverflow(tokenContribution.value)
                if overflowed {
                    tokensAreValid = false
                } else {
                    totalTokens = sum
                    sawTokens = true
                }
            }

            let costContribution = self.projectQuotaCost(day: day, start: start, end: end)
            if !costContribution.isValid {
                costIsValid = false
            } else if costContribution.sawValue {
                let sum = totalCost + costContribution.value
                if sum.isFinite {
                    totalCost = sum
                    sawCost = true
                } else {
                    costIsValid = false
                }
            }

            entryCount += day.slices.count(where: { $0.overlaps(start: start, end: end) })
            if tokenContribution.usedDaily || costContribution.usedDaily || day.slices.isEmpty {
                entryCount += 1
            }
        }

        return QuotaWindowProjection(
            totalTokens: tokensAreValid && sawTokens ? totalTokens : nil,
            totalCostUSD: costIsValid && sawCost ? totalCost : nil,
            entryCount: entryCount)
    }

    private static func projectQuotaTokens(
        day: QuotaProjectionDay,
        start: Date,
        end: Date) -> QuotaTokenContribution
    {
        guard let daily = day.daily else {
            return self.projectTokenSlices(day.slices, start: start, end: end)
        }
        guard let dailyTokens = daily.totalTokens,
              dailyTokens >= 0,
              max(0, daily.unmeteredRequestCount ?? 0) == 0
        else {
            return QuotaTokenContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
        }

        switch self.tokenReconciliation(day.slices, daily: dailyTokens) {
        case .exact:
            if day.slices.isEmpty {
                return QuotaTokenContribution(isValid: true, sawValue: true, value: 0, usedDaily: false)
            }
            return self.projectTokenSlices(day.slices, start: start, end: end)
        case .inconsistent:
            return QuotaTokenContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
        case .residual:
            break
        }
        guard day.isContained(start: start, end: end) else {
            // A reset that cuts a coarse daily total cannot assign that remainder, but exact
            // timestamped slices on either side still belong to their windows.
            return self.projectTokenSlices(day.slices, start: start, end: end)
        }
        return QuotaTokenContribution(isValid: true, sawValue: true, value: dailyTokens, usedDaily: true)
    }

    private static func projectQuotaCost(
        day: QuotaProjectionDay,
        start: Date,
        end: Date) -> QuotaCostContribution
    {
        guard let daily = day.daily else {
            return self.projectCostSlices(day.slices, start: start, end: end)
        }
        guard let dailyCost = self.completeDailyCost(daily) else {
            return QuotaCostContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
        }

        switch self.costReconciliation(day.slices, daily: dailyCost) {
        case .exact:
            if day.slices.isEmpty {
                return QuotaCostContribution(isValid: true, sawValue: true, value: 0, usedDaily: false)
            }
            return self.projectCostSlices(day.slices, start: start, end: end)
        case .inconsistent:
            return QuotaCostContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
        case .residual:
            break
        }
        guard day.isContained(start: start, end: end) else {
            // A reset that cuts a coarse daily total cannot assign that remainder, but exact
            // timestamped slices on either side still belong to their windows.
            return self.projectCostSlices(day.slices, start: start, end: end)
        }
        return QuotaCostContribution(isValid: true, sawValue: true, value: dailyCost, usedDaily: true)
    }

    private static func completeDailyCost(_ daily: CostUsageDailyReport.Entry) -> Double? {
        guard let cost = daily.costUSD, cost.isFinite, cost >= 0 else { return nil }
        guard max(0, daily.unpricedRequestCount ?? 0) == 0,
              max(0, daily.unmeteredRequestCount ?? 0) == 0
        else { return nil }
        if daily.modelBreakdowns?.contains(where: { breakdown in
            breakdown.costUSD == nil
                && ((breakdown.totalTokens ?? 0) > 0 || (breakdown.requestCount ?? 0) > 0)
        }) == true {
            return nil
        }
        return cost
    }

    private static func tokenReconciliation(
        _ slices: [QuotaProjectionSlice],
        daily: Int) -> QuotaReconciliation
    {
        if slices.isEmpty { return daily == 0 ? .exact : .residual }
        var total = 0
        var isComplete = true
        for slice in slices {
            guard let tokens = slice.totalTokens, tokens >= 0 else {
                isComplete = false
                continue
            }
            let (sum, overflowed) = total.addingReportingOverflow(tokens)
            guard !overflowed else { return .inconsistent }
            total = sum
        }
        if total > daily { return .inconsistent }
        return isComplete && total == daily ? .exact : .residual
    }

    private static func costReconciliation(
        _ slices: [QuotaProjectionSlice],
        daily: Double) -> QuotaReconciliation
    {
        if slices.isEmpty { return daily == 0 ? .exact : .residual }
        var total = 0.0
        var isComplete = true
        for slice in slices {
            guard let cost = slice.costUSD, cost.isFinite, cost >= 0 else {
                isComplete = false
                continue
            }
            total += cost
            guard total.isFinite else { return .inconsistent }
        }
        let tolerance = max(1e-9, abs(daily) * 1e-9)
        if total > daily + tolerance { return .inconsistent }
        return isComplete && abs(total - daily) <= tolerance ? .exact : .residual
    }

    private static func projectTokenSlices(
        _ slices: [QuotaProjectionSlice],
        start: Date,
        end: Date) -> QuotaTokenContribution
    {
        var total = 0
        var sawValue = false
        for slice in slices where slice.overlaps(start: start, end: end) {
            // A reset that cuts a coarse hour/day interval cannot be assigned to one window.
            // Drop that interval only; known events and fully contained buckets still count.
            if !slice.isContained(start: start, end: end) {
                continue
            }
            guard let tokens = slice.totalTokens, tokens >= 0 else {
                return QuotaTokenContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
            }
            let (sum, overflowed) = total.addingReportingOverflow(tokens)
            guard !overflowed else {
                return QuotaTokenContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
            }
            total = sum
            sawValue = true
        }
        return QuotaTokenContribution(isValid: true, sawValue: sawValue, value: total, usedDaily: false)
    }

    private static func projectCostSlices(
        _ slices: [QuotaProjectionSlice],
        start: Date,
        end: Date) -> QuotaCostContribution
    {
        var total = 0.0
        var sawValue = false
        for slice in slices where slice.overlaps(start: start, end: end) {
            if !slice.isContained(start: start, end: end) {
                continue
            }
            guard let cost = slice.costUSD, cost.isFinite, cost >= 0 else {
                return QuotaCostContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
            }
            total += cost
            guard total.isFinite else {
                return QuotaCostContribution(isValid: false, sawValue: false, value: 0, usedDaily: false)
            }
            sawValue = true
        }
        return QuotaCostContribution(isValid: true, sawValue: sawValue, value: total, usedDaily: false)
    }
}
