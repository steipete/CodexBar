import Foundation

package struct CostUsageTokenActivityCache: Sendable, Equatable {
    package let daily: [CostUsageDailyReport.Entry]
    package let coverageSinceKey: String
    package let coverageUntilKey: String

    package init(
        daily: [CostUsageDailyReport.Entry],
        coverageSinceKey: String,
        coverageUntilKey: String)
    {
        self.daily = daily
        self.coverageSinceKey = coverageSinceKey
        self.coverageUntilKey = coverageUntilKey
    }
}

public struct CostUsageWindowSummary: Sendable, Equatable {
    public let days: Int
    public let totalTokens: Int?
    public let totalCostUSD: Double?
    public let totalRequests: Int?
    public let entryCount: Int
    public let tokenMix: CostUsageTokenMix
    public let coverage: CostUsageCoverageCounts
    public let provenance: CostProvenance
    public let meteredCostUSD: Double?

    public init(
        days: Int,
        totalTokens: Int?,
        totalCostUSD: Double?,
        totalRequests: Int?,
        entryCount: Int,
        tokenMix: CostUsageTokenMix = CostUsageTokenMix(),
        coverage: CostUsageCoverageCounts = CostUsageCoverageCounts(),
        provenance: CostProvenance = .unknown,
        meteredCostUSD: Double? = nil)
    {
        self.days = days
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.totalRequests = totalRequests
        self.entryCount = entryCount
        self.tokenMix = tokenMix
        self.coverage = coverage
        self.provenance = provenance
        self.meteredCostUSD = meteredCostUSD
    }
}

/// A quota window derived from local cost history.
///
/// When `resetAt` is known, windows line up with the live Weekly bar rather than a rolling
/// calendar "last 7 days". Observed extra resets (official rollover plus a banked reset) become
/// additional boundaries. Hour buckets split a reset day at the reset instant; each hour belongs
/// to exactly one window. Daily-only snapshots fall back to exclusive day membership so a
/// boundary calendar day is never counted twice.
public struct CostUsageQuotaWeek: Sendable, Equatable {
    public let offset: Int
    public let start: Date
    public let end: Date
    public let totalTokens: Int?
    public let totalCostUSD: Double?
    public let entryCount: Int

    public var isCurrent: Bool {
        self.offset == 0
    }

    /// True when this window is within a day of the nominal 7×24h weekly quota.
    public var isNominalWeek: Bool {
        abs(self.end.timeIntervalSince(self.start) - TimeInterval(CostUsageTokenSnapshot.quotaWeekMinutes * 60))
            < 24 * 60 * 60
    }

    public init(
        offset: Int,
        start: Date,
        end: Date,
        totalTokens: Int?,
        totalCostUSD: Double?,
        entryCount: Int)
    {
        self.offset = offset
        self.start = start
        self.end = end
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.entryCount = entryCount
    }
}

/// An estimated local Codex conversation total derived from one session log.
/// This is intentionally distinct from account-level billing or quota data.
public struct CostUsageSessionBreakdown: Sendable, Equatable, Identifiable {
    public let sessionID: String
    public let lastActivity: Date
    public let inputTokens: Int?
    public let cachedInputTokens: Int?
    public let outputTokens: Int?
    public let reasoningTokens: Int?
    public let totalTokens: Int?
    public let requestCount: Int?
    public let costUSD: Double?
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]

    public var id: String {
        self.sessionID
    }

    public init(
        sessionID: String,
        lastActivity: Date,
        inputTokens: Int?,
        cachedInputTokens: Int?,
        outputTokens: Int?,
        reasoningTokens: Int? = nil,
        totalTokens: Int?,
        requestCount: Int?,
        costUSD: Double?,
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown])
    {
        self.sessionID = sessionID
        self.lastActivity = lastActivity
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningTokens = reasoningTokens
        self.totalTokens = totalTokens
        self.requestCount = requestCount
        self.costUSD = costUSD
        self.modelBreakdowns = modelBreakdowns
    }
}

public struct CostUsageHourlyEntry: Sendable, Equatable {
    public let hour: Date
    public let totalTokens: Int?
    public let costUSD: Double?

    public init(hour: Date, totalTokens: Int?, costUSD: Double?) {
        self.hour = hour
        self.totalTokens = totalTokens
        self.costUSD = costUSD
    }
}

public struct CostUsageTokenSnapshot: Sendable, Equatable {
    public let sessionTokens: Int?
    public let sessionCostUSD: Double?
    public let sessionRequests: Int?
    public let last30DaysTokens: Int?
    public let last30DaysCostUSD: Double?
    public let last30DaysRequests: Int?
    public let currencyCode: String
    public let historyDays: Int
    public let historyCoverageIsEstablished: Bool
    public let historyLabel: String?
    /// Provider-metered spend over the same window as `last30DaysCostUSD` — what the plan
    /// actually deducts, as opposed to the API-rate estimate. Only some providers (e.g. Cursor)
    /// report this; `nil` when unknown.
    public let meteredCostUSD: Double?
    /// How this snapshot's costs were produced. Never infer this solely from whether a
    /// cost figure exists — Bedrock and OpenAI Admin costs are vendor-reported.
    public let costProvenance: CostProvenance
    /// Internal credential scope used to prevent cross-account cache publication. This is a
    /// non-reversible fingerprint, not account identity, and is not emitted by CLI payloads.
    public let credentialScopeFingerprint: String?
    public let daily: [CostUsageDailyReport.Entry]
    public let projects: [CostUsageProjectBreakdown]
    public let sessions: [CostUsageSessionBreakdown]
    /// Per-request hour buckets. Native Codex/Claude fill this from event timestamps so weekly
    /// quota windows can split a mid-day reset; OpenCodex fills it from usage.jsonl.
    public let hourly: [CostUsageHourlyEntry]
    public let updatedAt: Date

    public init(
        sessionTokens: Int?,
        sessionCostUSD: Double?,
        sessionRequests: Int? = nil,
        last30DaysTokens: Int?,
        last30DaysCostUSD: Double?,
        last30DaysRequests: Int? = nil,
        currencyCode: String = "USD",
        historyDays: Int = 30,
        historyCoverageIsEstablished: Bool = true,
        historyLabel: String? = nil,
        meteredCostUSD: Double? = nil,
        costProvenance: CostProvenance = .unknown,
        credentialScopeFingerprint: String? = nil,
        daily: [CostUsageDailyReport.Entry],
        projects: [CostUsageProjectBreakdown] = [],
        sessions: [CostUsageSessionBreakdown] = [],
        hourly: [CostUsageHourlyEntry] = [],
        updatedAt: Date)
    {
        self.sessionTokens = sessionTokens
        self.sessionCostUSD = sessionCostUSD
        self.sessionRequests = sessionRequests
        self.last30DaysTokens = last30DaysTokens
        self.last30DaysCostUSD = last30DaysCostUSD
        self.last30DaysRequests = last30DaysRequests
        let normalizedCurrencyCode = currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        self.currencyCode = normalizedCurrencyCode.isEmpty ? "XXX" : normalizedCurrencyCode
        self.historyDays = historyDays
        self.historyCoverageIsEstablished = historyCoverageIsEstablished
        self.historyLabel = historyLabel
        self.meteredCostUSD = meteredCostUSD
        self.costProvenance = costProvenance
        self.credentialScopeFingerprint = credentialScopeFingerprint
        self.daily = daily
        self.projects = projects
        self.sessions = sessions
        self.hourly = hourly
        self.updatedAt = updatedAt
    }

    public func currentDayEntry(calendar: Calendar = .current) -> CostUsageDailyReport.Entry? {
        Self.entry(in: self.daily, forLocalDayContaining: self.updatedAt, calendar: calendar)
    }

    public func summary(forLastDays requestedDays: Int, calendar: Calendar = .current) -> CostUsageWindowSummary {
        let days = max(1, requestedDays)
        let today = calendar.startOfDay(for: self.updatedAt)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: today) ?? today
        let startKey = CostUsageLocalDay.key(from: start, calendar: calendar)
        let endKey = CostUsageLocalDay.key(from: today, calendar: calendar)
        let entries = self.daily.filter { entry in
            guard let dayKey = Self.localDayKey(for: entry.date, calendar: calendar) else { return false }
            return dayKey >= startKey && dayKey <= endKey
        }
        let costs = entries.compactMap(\.costUSD)
        let tokens = entries.compactMap(\.totalTokens)
        let requests = entries.compactMap(\.requestCount)
        var mix = CostUsageTokenMix()
        var coverage = CostUsageCoverageCounts()
        for entry in entries {
            mix.merge(.from(entry: entry))
            coverage.merge(entry.coverageCounts)
        }
        let coversFullHistory = days >= self.historyDays
        let windowMetered = coversFullHistory ? self.meteredCostUSD : nil
        let totalTokens: Int? = {
            guard !tokens.isEmpty else { return nil }
            var sum = 0
            for t in tokens {
                let (res, of) = sum.addingReportingOverflow(t)
                if of { return nil }
                sum = res
            }
            return sum
        }()
        let totalRequests: Int? = {
            guard !requests.isEmpty else { return nil }
            var sum = 0
            for r in requests {
                let (res, of) = sum.addingReportingOverflow(r)
                if of { return nil }
                sum = res
            }
            return sum
        }()
        return CostUsageWindowSummary(
            days: days,
            totalTokens: totalTokens,
            totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
            totalRequests: totalRequests,
            entryCount: entries.count,
            tokenMix: mix,
            coverage: coverage,
            provenance: CostProvenance.forWindow(
                snapshot: self.costProvenance,
                hasWindowCosts: !costs.isEmpty,
                includesMetered: windowMetered != nil),
            meteredCostUSD: windowMetered)
    }

    public func comparisonSummaries(
        periods: [Int] = [7, 30, 90],
        calendar: Calendar = .current) -> [CostUsageWindowSummary]
    {
        Array(Set(periods.map { max(1, $0) }))
            .filter { $0 < self.historyDays }
            .sorted()
            .map { self.summary(forLastDays: $0, calendar: calendar) }
    }

    public static let quotaWeekMinutes = 7 * 24 * 60

    /// Buckets local cost into consecutive quota windows.
    ///
    /// Pass the live Weekly `resetsAt` / `windowMinutes` to match the quota bar. When reset
    /// metadata is missing, windows fall back to rolling calendar weeks ending tomorrow.
    /// Hour entries use half-open `[start, end)` membership so a reset-day hour is never
    /// counted in two weeks. Daily-only history uses the day's start instant the same way.
    ///
    /// `observedNextResets` are previously published Weekly `resetsAt` values (for example from
    /// plan-utilization samples). An elapsed stored next-reset is treated as a real reset instant,
    /// so an official rollover and a later banked reset on the same day become two windows instead
    /// of one 7-day block. `observedResetInstants` are known start times such as a redeemed
    /// reset-credit `redeemedAt`.
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
        let usesHourly = !self.hourly.isEmpty
        let indexedDays: [(start: Date, entry: CostUsageDailyReport.Entry)] = usesHourly
            ? []
            : self.daily.compactMap { entry in
                guard let dayKey = Self.localDayKey(for: entry.date, calendar: calendar),
                      let dayStart = CostUsageLocalDay.date(fromKey: dayKey, calendar: calendar)
                else { return nil }
                return (dayStart, entry)
            }

        let count = max(1, min(weekCount, 8))
        let boundaries = Self.quotaWeekBoundaries(
            currentEnd: currentEnd,
            duration: duration,
            observedNextResets: observedNextResets,
            observedResetInstants: observedResetInstants,
            weekCount: count)
        var weeks: [CostUsageQuotaWeek] = []
        weeks.reserveCapacity(count)
        var offset = 0
        var endIndex = boundaries.count - 1
        while offset < count, endIndex > 0 {
            let end = boundaries[endIndex]
            let start = boundaries[endIndex - 1]
            endIndex -= 1
            if offset > 0, end <= historyStart {
                break
            }
            if usesHourly {
                let hours = self.hourly.filter { hour in
                    hour.hour >= start && hour.hour < end
                }
                let costs = hours.compactMap(\.costUSD)
                let tokens = hours.compactMap(\.totalTokens)
                weeks.append(CostUsageQuotaWeek(
                    offset: offset,
                    start: start,
                    end: end,
                    totalTokens: Self.summedInts(tokens),
                    totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                    entryCount: hours.count))
            } else {
                let entries = indexedDays.compactMap { day -> CostUsageDailyReport.Entry? in
                    guard day.start >= start, day.start < end else { return nil }
                    return day.entry
                }
                let costs = entries.compactMap(\.costUSD)
                let tokens = entries.compactMap(\.totalTokens)
                weeks.append(CostUsageQuotaWeek(
                    offset: offset,
                    start: start,
                    end: end,
                    totalTokens: Self.summedInts(tokens),
                    totalCostUSD: costs.isEmpty ? nil : costs.reduce(0, +),
                    entryCount: entries.count))
            }
            offset += 1
        }
        return weeks
    }

    public static let quotaWeekBoundaryTolerance: TimeInterval = 2 * 60

    /// Reconstructs quota-window edges from the live next reset plus any previously observed
    /// Weekly `resetsAt` values or known reset instants.
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
            duration: duration,
            observedNextResets: observedNextResets,
            observedResetInstants: observedResetInstants,
            weekCount: max(1, min(weekCount, 8)))
    }

    private static func quotaWeekBoundaries(
        currentEnd: Date,
        duration: TimeInterval,
        observedNextResets: [Date],
        observedResetInstants: [Date],
        weekCount: Int) -> [Date]
    {
        var dates: [Date] = [currentEnd, currentEnd.addingTimeInterval(-duration)]
        dates.reserveCapacity(weekCount + 1 + observedNextResets.count * 2 + observedResetInstants.count)
        for next in observedNextResets {
            dates.append(next)
            dates.append(next.addingTimeInterval(-duration))
        }
        dates.append(contentsOf: observedResetInstants)
        let latestAllowed = currentEnd.addingTimeInterval(self.quotaWeekBoundaryTolerance)
        var unique = self.uniqueSortedDates(dates, tolerance: self.quotaWeekBoundaryTolerance)
            .filter { $0 <= latestAllowed }
        if unique.last.map({ abs($0.timeIntervalSince(currentEnd)) < self.quotaWeekBoundaryTolerance }) != true {
            unique.append(currentEnd)
            unique = self.uniqueSortedDates(unique, tolerance: self.quotaWeekBoundaryTolerance)
        }
        let needed = weekCount + 1
        var previousCount = -1
        while unique.count < needed, duration > 0, unique.count != previousCount, let oldest = unique.first {
            previousCount = unique.count
            unique.insert(oldest.addingTimeInterval(-duration), at: 0)
            unique = self.uniqueSortedDates(unique, tolerance: self.quotaWeekBoundaryTolerance)
        }
        return unique
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

    private static func summedInts(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var sum = 0
        for value in values {
            let (result, overflowed) = sum.addingReportingOverflow(value)
            if overflowed { return nil }
            sum = result
        }
        return sum
    }

    public static func latestEntry(in entries: [CostUsageDailyReport.Entry]) -> CostUsageDailyReport.Entry? {
        entries.compactMap { entry -> (entry: CostUsageDailyReport.Entry, date: Date)? in
            guard let date = CostUsageDateParser.parse(entry.date) else { return nil }
            return (entry, date)
        }
        .max { lhs, rhs in
            if lhs.date != rhs.date {
                return lhs.date < rhs.date
            }
            let lCost = lhs.entry.costUSD ?? -1
            let rCost = rhs.entry.costUSD ?? -1
            if lCost != rCost {
                return lCost < rCost
            }
            let lTokens = lhs.entry.totalTokens ?? -1
            let rTokens = rhs.entry.totalTokens ?? -1
            if lTokens != rTokens {
                return lTokens < rTokens
            }
            return lhs.entry.date < rhs.entry.date
        }?.entry
    }

    public static func entry(
        in entries: [CostUsageDailyReport.Entry],
        forLocalDayContaining date: Date,
        calendar: Calendar = .current) -> CostUsageDailyReport.Entry?
    {
        let dayKey = CostUsageLocalDay.key(from: date, calendar: calendar)
        return entries.first { entry in
            let rawDate = entry.date.trimmingCharacters(in: .whitespacesAndNewlines)
            if rawDate == dayKey {
                return true
            }
            guard let parsed = CostUsageDateParser.parse(rawDate) else { return false }
            return CostUsageLocalDay.key(from: parsed, calendar: calendar) == dayKey
        }
    }

    private static func localDayKey(for rawDate: String, calendar: Calendar) -> String? {
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
}

public struct CostUsageProjectBreakdown: Sendable, Equatable {
    public static let unknownProjectName = "Unknown project"

    public let name: String
    public let path: String?
    public let totalTokens: Int?
    public let totalCostUSD: Double?
    public let daily: [CostUsageDailyReport.Entry]
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?
    public let sources: [CostUsageProjectSourceBreakdown]

    public init(
        name: String,
        path: String?,
        totalTokens: Int?,
        totalCostUSD: Double?,
        daily: [CostUsageDailyReport.Entry],
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?,
        sources: [CostUsageProjectSourceBreakdown] = [])
    {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? Self.unknownProjectName
            : name
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = cleanPath?.isEmpty == true ? nil : cleanPath
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.daily = daily
        self.modelBreakdowns = modelBreakdowns
        self.sources = sources
    }
}

public struct CostUsageProjectSourceBreakdown: Sendable, Equatable {
    public let name: String
    public let path: String?
    public let totalTokens: Int?
    public let totalCostUSD: Double?
    public let daily: [CostUsageDailyReport.Entry]
    public let modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?

    public init(
        name: String,
        path: String?,
        totalTokens: Int?,
        totalCostUSD: Double?,
        daily: [CostUsageDailyReport.Entry],
        modelBreakdowns: [CostUsageDailyReport.ModelBreakdown]?)
    {
        self.name = name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? CostUsageProjectBreakdown.unknownProjectName
            : name
        let cleanPath = path?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.path = cleanPath?.isEmpty == true ? nil : cleanPath
        self.totalTokens = totalTokens
        self.totalCostUSD = totalCostUSD
        self.daily = daily
        self.modelBreakdowns = modelBreakdowns
    }
}

public struct CostUsageDailyReport: Sendable, Decodable {
    public struct ModelBreakdown: Sendable, Decodable, Equatable {
        public let modelName: String
        public let costUSD: Double?
        public let totalTokens: Int?
        public let requestCount: Int?
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheCreationTokens: Int?
        public let reasoningTokens: Int?
        public let standardCostUSD: Double?
        public let priorityCostUSD: Double?
        public let standardTokens: Int?
        public let priorityTokens: Int?

        private enum CodingKeys: String, CodingKey {
            case modelName
            case costUSD
            case cost
            case totalTokens
            case requestCount
            case requests
            case inputTokens
            case outputTokens
            case cacheReadTokens
            case cacheCreationTokens
            case reasoningTokens
            case standardCostUSD
            case priorityCostUSD
            case standardTokens
            case priorityTokens
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.modelName = try container.decode(String.self, forKey: .modelName)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .cost)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.requestCount =
                try container.decodeIfPresent(Int.self, forKey: .requestCount)
                ?? container.decodeIfPresent(Int.self, forKey: .requests)
            self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            self.cacheReadTokens = try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            self.cacheCreationTokens = try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
            self.reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
            self.standardCostUSD = try container.decodeIfPresent(Double.self, forKey: .standardCostUSD)
            self.priorityCostUSD = try container.decodeIfPresent(Double.self, forKey: .priorityCostUSD)
            self.standardTokens = try container.decodeIfPresent(Int.self, forKey: .standardTokens)
            self.priorityTokens = try container.decodeIfPresent(Int.self, forKey: .priorityTokens)
        }

        public init(
            modelName: String,
            costUSD: Double?,
            totalTokens: Int? = nil,
            requestCount: Int? = nil,
            inputTokens: Int? = nil,
            outputTokens: Int? = nil,
            cacheReadTokens: Int? = nil,
            cacheCreationTokens: Int? = nil,
            reasoningTokens: Int? = nil,
            standardCostUSD: Double? = nil,
            priorityCostUSD: Double? = nil,
            standardTokens: Int? = nil,
            priorityTokens: Int? = nil)
        {
            self.modelName = modelName
            self.costUSD = costUSD
            self.totalTokens = totalTokens
            self.requestCount = requestCount
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.reasoningTokens = reasoningTokens
            self.standardCostUSD = standardCostUSD
            self.priorityCostUSD = priorityCostUSD
            self.standardTokens = standardTokens
            self.priorityTokens = priorityTokens
        }
    }

    public struct Entry: Sendable, Decodable, Equatable {
        public let date: String
        public let inputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheCreationTokens: Int?
        public let outputTokens: Int?
        public let reasoningTokens: Int?
        public let totalTokens: Int?
        public let requestCount: Int?
        public let costUSD: Double?
        public let modelsUsed: [String]?
        public let modelBreakdowns: [ModelBreakdown]?
        public let unpricedRequestCount: Int?
        /// Per-event count of requests with valid vendor costs. Unlike the aggregate
        /// "costUSD != nil" check, this survives fail-closed aggregation when an invalid
        /// cost from the same model poisons the summed amount.
        public let pricedRequestCount: Int?
        public let unmeteredRequestCount: Int?
        public let estimatedRequestCount: Int?

        public var coverageCounts: CostUsageCoverageCounts {
            let unpriced = max(0, self.unpricedRequestCount ?? 0)
            let unmetered = max(0, self.unmeteredRequestCount ?? 0)
            let estimated = max(0, self.estimatedRequestCount ?? 0)
            if let priced = self.pricedRequestCount {
                return CostUsageCoverageCounts(
                    priced: max(0, priced),
                    unpriced: unpriced,
                    unmetered: unmetered,
                    estimated: estimated)
            }
            if let requests = self.requestCount, requests > 0 {
                let priced = if self.costUSD != nil {
                    max(0, requests - unpriced - unmetered - estimated)
                } else {
                    0
                }
                return CostUsageCoverageCounts(
                    priced: priced,
                    unpriced: unpriced,
                    unmetered: unmetered,
                    estimated: estimated)
            }
            if unpriced + unmetered + estimated > 0 {
                return CostUsageCoverageCounts(
                    priced: 0,
                    unpriced: unpriced,
                    unmetered: unmetered,
                    estimated: estimated)
            }
            if self.costUSD != nil {
                return CostUsageCoverageCounts(priced: 1)
            }
            if (self.totalTokens ?? 0) > 0 {
                return CostUsageCoverageCounts(unpriced: 1)
            }
            return CostUsageCoverageCounts()
        }

        private enum CodingKeys: String, CodingKey {
            case date
            case inputTokens
            case cacheReadTokens
            case cacheCreationTokens
            case cacheReadInputTokens
            case cacheCreationInputTokens
            case outputTokens
            case reasoningTokens
            case reasoningOutputTokens
            case totalTokens
            case requestCount
            case requests
            case costUSD
            case totalCost
            case modelsUsed
            case models
            case modelBreakdowns
            case unpricedRequestCount
            case pricedRequestCount
            case unmeteredRequestCount
            case estimatedRequestCount
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.date = try container.decode(String.self, forKey: .date)
            self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            self.cacheReadTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)
            self.cacheCreationTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)
            self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            self.reasoningTokens =
                try container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .reasoningOutputTokens)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.requestCount =
                try container.decodeIfPresent(Int.self, forKey: .requestCount)
                ?? container.decodeIfPresent(Int.self, forKey: .requests)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
            self.modelsUsed = Self.decodeModelsUsed(from: container)
            self.modelBreakdowns = try container.decodeIfPresent([ModelBreakdown].self, forKey: .modelBreakdowns)
            self.unpricedRequestCount = try container.decodeIfPresent(Int.self, forKey: .unpricedRequestCount)
            self.pricedRequestCount = try container.decodeIfPresent(Int.self, forKey: .pricedRequestCount)
            self.unmeteredRequestCount = try container.decodeIfPresent(Int.self, forKey: .unmeteredRequestCount)
            self.estimatedRequestCount = try container.decodeIfPresent(Int.self, forKey: .estimatedRequestCount)
        }

        public init(
            date: String,
            inputTokens: Int?,
            outputTokens: Int?,
            cacheReadTokens: Int? = nil,
            cacheCreationTokens: Int? = nil,
            reasoningTokens: Int? = nil,
            totalTokens: Int?,
            requestCount: Int? = nil,
            costUSD: Double?,
            modelsUsed: [String]?,
            modelBreakdowns: [ModelBreakdown]?,
            unpricedRequestCount: Int? = nil,
            unmeteredRequestCount: Int? = nil,
            estimatedRequestCount: Int? = nil,
            pricedRequestCount: Int? = nil)
        {
            self.date = date
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.requestCount = requestCount
            self.costUSD = costUSD
            self.modelsUsed = modelsUsed
            self.modelBreakdowns = modelBreakdowns
            self.unpricedRequestCount = unpricedRequestCount
            self.unmeteredRequestCount = unmeteredRequestCount
            self.estimatedRequestCount = estimatedRequestCount
            self.pricedRequestCount = pricedRequestCount
        }

        private static func decodeModelsUsed(from container: KeyedDecodingContainer<CodingKeys>) -> [String]? {
            func decodeStringList(_ key: CodingKeys) -> [String]? {
                (try? container.decodeIfPresent([String].self, forKey: key)).flatMap(\.self)
            }

            if let modelsUsed = decodeStringList(.modelsUsed) {
                return modelsUsed
            }
            if let models = decodeStringList(.models) {
                return models
            }

            guard container.contains(.models) else { return nil }

            guard let modelMap = try? container.nestedContainer(keyedBy: CostUsageAnyCodingKey.self, forKey: .models)
            else { return nil }

            let modelNames = modelMap.allKeys.map(\.stringValue).sorted()
            return modelNames.isEmpty ? nil : modelNames
        }
    }

    public struct Summary: Sendable, Decodable, Equatable {
        public let totalInputTokens: Int?
        public let totalOutputTokens: Int?
        public let cacheReadTokens: Int?
        public let cacheCreationTokens: Int?
        public let reasoningTokens: Int?
        public let totalTokens: Int?
        public let totalCostUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case totalInputTokens
            case totalOutputTokens
            case cacheReadTokens
            case cacheCreationTokens
            case totalCacheReadTokens
            case totalCacheCreationTokens
            case reasoningTokens
            case totalTokens
            case totalCostUSD
            case totalCost
        }

        public init(
            totalInputTokens: Int?,
            totalOutputTokens: Int?,
            cacheReadTokens: Int? = nil,
            cacheCreationTokens: Int? = nil,
            reasoningTokens: Int? = nil,
            totalTokens: Int?,
            totalCostUSD: Double?)
        {
            self.totalInputTokens = totalInputTokens
            self.totalOutputTokens = totalOutputTokens
            self.cacheReadTokens = cacheReadTokens
            self.cacheCreationTokens = cacheCreationTokens
            self.reasoningTokens = reasoningTokens
            self.totalTokens = totalTokens
            self.totalCostUSD = totalCostUSD
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalInputTokens = try container.decodeIfPresent(Int.self, forKey: .totalInputTokens)
            self.totalOutputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
            self.cacheReadTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .totalCacheReadTokens)
            self.cacheCreationTokens =
                try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
                ?? container.decodeIfPresent(Int.self, forKey: .totalCacheCreationTokens)
            self.reasoningTokens = try container.decodeIfPresent(Int.self, forKey: .reasoningTokens)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.totalCostUSD =
                try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public let data: [Entry]
    public let summary: Summary?
    public let hourly: [CostUsageHourlyEntry]

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case summary
        case daily
        case totals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.hourly = []

        if container.contains(.type) {
            _ = try container.decode(String.self, forKey: .type)
            self.data = try container.decode([Entry].self, forKey: .data)
            self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
            return
        }

        self.data = try container.decode([Entry].self, forKey: .daily)
        if container.contains(.totals) {
            let totals = try container.decode(CostUsageLegacyTotals.self, forKey: .totals)
            self.summary = Summary(
                totalInputTokens: totals.totalInputTokens,
                totalOutputTokens: totals.totalOutputTokens,
                cacheReadTokens: totals.cacheReadTokens,
                cacheCreationTokens: totals.cacheCreationTokens,
                totalTokens: totals.totalTokens,
                totalCostUSD: totals.totalCost)
        } else {
            self.summary = nil
        }
    }

    public init(data: [Entry], summary: Summary?, hourly: [CostUsageHourlyEntry] = []) {
        self.data = data
        self.summary = summary
        self.hourly = hourly
    }
}

extension CostUsageDailyReport {
    private struct BreakdownAccumulator {
        var totalTokens: Int = 0
        var sawTotalTokens = false
        var costUSD: Double = 0
        var sawCost = false
        var standardCostUSD: Double = 0
        var sawStandardCost = false
        var priorityCostUSD: Double = 0
        var sawPriorityCost = false
        var standardTokens: Int = 0
        var sawStandardTokens = false
        var priorityTokens: Int = 0
        var sawPriorityTokens = false

        mutating func add(_ breakdown: ModelBreakdown) {
            if let totalTokens = breakdown.totalTokens {
                self.totalTokens += totalTokens
                self.sawTotalTokens = true
            }
            if let costUSD = breakdown.costUSD {
                self.costUSD += costUSD
                self.sawCost = true
            }
            if let standardCostUSD = breakdown.standardCostUSD {
                self.standardCostUSD += standardCostUSD
                self.sawStandardCost = true
            }
            if let priorityCostUSD = breakdown.priorityCostUSD {
                self.priorityCostUSD += priorityCostUSD
                self.sawPriorityCost = true
            }
            if let standardTokens = breakdown.standardTokens {
                self.standardTokens += standardTokens
                self.sawStandardTokens = true
            }
            if let priorityTokens = breakdown.priorityTokens {
                self.priorityTokens += priorityTokens
                self.sawPriorityTokens = true
            }
        }

        func build(modelName: String) -> ModelBreakdown {
            ModelBreakdown(
                modelName: modelName,
                costUSD: self.sawCost ? self.costUSD : nil,
                totalTokens: self.sawTotalTokens ? self.totalTokens : nil,
                standardCostUSD: self.sawStandardCost ? self.standardCostUSD : nil,
                priorityCostUSD: self.sawPriorityCost ? self.priorityCostUSD : nil,
                standardTokens: self.sawStandardTokens ? self.standardTokens : nil,
                priorityTokens: self.sawPriorityTokens ? self.priorityTokens : nil)
        }
    }

    private struct EntryAccumulator {
        var inputTokens: Int = 0
        var sawInputTokens = false
        var cacheReadTokens: Int = 0
        var sawCacheReadTokens = false
        var cacheCreationTokens: Int = 0
        var sawCacheCreationTokens = false
        var outputTokens: Int = 0
        var sawOutputTokens = false
        var totalTokens: Int = 0
        var sawTotalTokens = false
        var derivedTotalTokensWithoutExplicitTotal: Int = 0
        var costUSD: Double = 0
        var sawCost = false
        var modelsUsed: Set<String> = []
        var breakdowns: [String: BreakdownAccumulator] = [:]

        mutating func add(_ entry: Entry) {
            let entryDerivedTotalTokens = (entry.inputTokens ?? 0)
                + (entry.cacheReadTokens ?? 0)
                + (entry.cacheCreationTokens ?? 0)
                + (entry.outputTokens ?? 0)
            if let inputTokens = entry.inputTokens {
                self.inputTokens += inputTokens
                self.sawInputTokens = true
            }
            if let cacheReadTokens = entry.cacheReadTokens {
                self.cacheReadTokens += cacheReadTokens
                self.sawCacheReadTokens = true
            }
            if let cacheCreationTokens = entry.cacheCreationTokens {
                self.cacheCreationTokens += cacheCreationTokens
                self.sawCacheCreationTokens = true
            }
            if let outputTokens = entry.outputTokens {
                self.outputTokens += outputTokens
                self.sawOutputTokens = true
            }
            if let totalTokens = entry.totalTokens {
                self.totalTokens += totalTokens
                self.sawTotalTokens = true
            } else if entryDerivedTotalTokens > 0 {
                self.derivedTotalTokensWithoutExplicitTotal += entryDerivedTotalTokens
            }
            if let costUSD = entry.costUSD {
                self.costUSD += costUSD
                self.sawCost = true
            }
            if let modelsUsed = entry.modelsUsed {
                self.modelsUsed.formUnion(modelsUsed)
            }
            if let modelBreakdowns = entry.modelBreakdowns {
                for breakdown in modelBreakdowns {
                    var accumulator = self.breakdowns[breakdown.modelName] ?? BreakdownAccumulator()
                    accumulator.add(breakdown)
                    self.breakdowns[breakdown.modelName] = accumulator
                    self.modelsUsed.insert(breakdown.modelName)
                }
            }
        }

        func build(date: String) -> Entry {
            let derivedTotalTokens = self.inputTokens
                + self.cacheReadTokens
                + self.cacheCreationTokens
                + self.outputTokens
            let totalTokens: Int? = if self.sawTotalTokens {
                self.totalTokens + self.derivedTotalTokensWithoutExplicitTotal
            } else if derivedTotalTokens > 0 {
                derivedTotalTokens
            } else {
                nil
            }
            let modelBreakdowns: [ModelBreakdown]? = {
                guard !self.breakdowns.isEmpty else { return nil }
                return CostUsageDailyReport.sortedModelBreakdowns(
                    self.breakdowns
                        .map { modelName, accumulator in
                            accumulator.build(modelName: modelName)
                        })
            }()
            let modelsUsed = self.modelsUsed.isEmpty ? nil : self.modelsUsed.sorted()
            return Entry(
                date: date,
                inputTokens: self.sawInputTokens ? self.inputTokens : nil,
                outputTokens: self.sawOutputTokens ? self.outputTokens : nil,
                cacheReadTokens: self.sawCacheReadTokens ? self.cacheReadTokens : nil,
                cacheCreationTokens: self.sawCacheCreationTokens ? self.cacheCreationTokens : nil,
                totalTokens: totalTokens,
                costUSD: self.sawCost ? self.costUSD : nil,
                modelsUsed: modelsUsed,
                modelBreakdowns: modelBreakdowns)
        }
    }

    public func merged(with other: CostUsageDailyReport, calendar: Calendar = .current) -> CostUsageDailyReport {
        Self.merged([self, other], calendar: calendar)
    }

    public static func merged(
        _ reports: [CostUsageDailyReport],
        calendar: Calendar = .current) -> CostUsageDailyReport
    {
        let entries = self.mergedEntries(from: reports)
        guard !entries.isEmpty else { return CostUsageDailyReport(data: [], summary: nil) }
        return CostUsageDailyReport(
            data: entries,
            summary: self.mergedSummary(from: entries),
            hourly: self.mergedHourly(from: reports, calendar: calendar))
    }

    private struct HourlyAccumulator {
        var totalTokens = 0
        var sawTokens = false
        var costUSD = 0.0
        var sawCost = false

        mutating func add(_ entry: CostUsageHourlyEntry) {
            if let tokens = entry.totalTokens {
                self.totalTokens += tokens
                self.sawTokens = true
            }
            if let costUSD = entry.costUSD {
                self.costUSD += costUSD
                self.sawCost = true
            }
        }

        func build(hour: Date) -> CostUsageHourlyEntry {
            CostUsageHourlyEntry(
                hour: hour,
                totalTokens: self.sawTokens ? self.totalTokens : nil,
                costUSD: self.sawCost ? self.costUSD : nil)
        }
    }

    private static func mergedHourly(
        from reports: [CostUsageDailyReport],
        calendar: Calendar) -> [CostUsageHourlyEntry]
    {
        let hasHourly = reports.contains { !$0.hourly.isEmpty }
        guard hasHourly else { return [] }
        var buckets: [Date: HourlyAccumulator] = [:]
        for report in reports {
            let hours = report.hourly.isEmpty
                ? self.synthesizedHourly(from: report.data, calendar: calendar)
                : report.hourly
            for entry in hours {
                var accumulator = buckets[entry.hour] ?? HourlyAccumulator()
                accumulator.add(entry)
                buckets[entry.hour] = accumulator
            }
        }
        return buckets.keys.sorted().map { hour in
            buckets[hour, default: HourlyAccumulator()].build(hour: hour)
        }
    }

    private static func synthesizedHourly(
        from entries: [Entry],
        calendar: Calendar) -> [CostUsageHourlyEntry]
    {
        entries.compactMap { entry in
            guard entry.costUSD != nil || entry.totalTokens != nil,
                  let dayStart = CostUsageLocalDay.date(fromKey: entry.date, calendar: calendar)
            else { return nil }
            return CostUsageHourlyEntry(
                hour: dayStart,
                totalTokens: entry.totalTokens,
                costUSD: entry.costUSD)
        }
    }

    private static func mergedEntries(from reports: [CostUsageDailyReport]) -> [Entry] {
        var dayAccumulators: [String: EntryAccumulator] = [:]
        for report in reports {
            for entry in report.data {
                var accumulator = dayAccumulators[entry.date] ?? EntryAccumulator()
                accumulator.add(entry)
                dayAccumulators[entry.date] = accumulator
            }
        }

        return dayAccumulators
            .keys
            .sorted()
            .map { date in
                dayAccumulators[date, default: EntryAccumulator()].build(date: date)
            }
    }

    private static func mergedSummary(from entries: [Entry]) -> Summary {
        var totalInputTokens = 0
        var sawTotalInputTokens = false
        var totalOutputTokens = 0
        var sawTotalOutputTokens = false
        var totalCacheReadTokens = 0
        var sawTotalCacheReadTokens = false
        var totalCacheCreationTokens = 0
        var sawTotalCacheCreationTokens = false
        var totalTokens = 0
        var sawTotalTokens = false
        var totalCostUSD = 0.0
        var sawTotalCostUSD = false

        for entry in entries {
            if let inputTokens = entry.inputTokens {
                totalInputTokens += inputTokens
                sawTotalInputTokens = true
            }
            if let outputTokens = entry.outputTokens {
                totalOutputTokens += outputTokens
                sawTotalOutputTokens = true
            }
            if let cacheReadTokens = entry.cacheReadTokens {
                totalCacheReadTokens += cacheReadTokens
                sawTotalCacheReadTokens = true
            }
            if let cacheCreationTokens = entry.cacheCreationTokens {
                totalCacheCreationTokens += cacheCreationTokens
                sawTotalCacheCreationTokens = true
            }
            if let entryTotalTokens = entry.totalTokens {
                totalTokens += entryTotalTokens
                sawTotalTokens = true
            }
            if let costUSD = entry.costUSD {
                totalCostUSD += costUSD
                sawTotalCostUSD = true
            }
        }

        return Summary(
            totalInputTokens: sawTotalInputTokens ? totalInputTokens : nil,
            totalOutputTokens: sawTotalOutputTokens ? totalOutputTokens : nil,
            cacheReadTokens: sawTotalCacheReadTokens ? totalCacheReadTokens : nil,
            cacheCreationTokens: sawTotalCacheCreationTokens ? totalCacheCreationTokens : nil,
            totalTokens: sawTotalTokens ? totalTokens : nil,
            totalCostUSD: sawTotalCostUSD ? totalCostUSD : nil)
    }

    private static func sortedModelBreakdowns(_ breakdowns: [ModelBreakdown]) -> [ModelBreakdown] {
        breakdowns.sorted { lhs, rhs in
            let lhsCost = lhs.costUSD ?? -1
            let rhsCost = rhs.costUSD ?? -1
            if lhsCost != rhsCost {
                return lhsCost > rhsCost
            }

            let lhsTokens = lhs.totalTokens ?? -1
            let rhsTokens = rhs.totalTokens ?? -1
            if lhsTokens != rhsTokens {
                return lhsTokens > rhsTokens
            }

            return lhs.modelName > rhs.modelName
        }
    }
}

public struct CostUsageSessionReport: Sendable, Decodable {
    public struct Entry: Sendable, Decodable, Equatable {
        public let session: String
        public let inputTokens: Int?
        public let outputTokens: Int?
        public let totalTokens: Int?
        public let costUSD: Double?
        public let lastActivity: String?

        private enum CodingKeys: String, CodingKey {
            case session
            case sessionId
            case inputTokens
            case outputTokens
            case totalTokens
            case costUSD
            case totalCost
            case lastActivity
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.session =
                try container.decodeIfPresent(String.self, forKey: .session)
                ?? container.decode(String.self, forKey: .sessionId)
            self.inputTokens = try container.decodeIfPresent(Int.self, forKey: .inputTokens)
            self.outputTokens = try container.decodeIfPresent(Int.self, forKey: .outputTokens)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
            self.lastActivity = try container.decodeIfPresent(String.self, forKey: .lastActivity)
        }
    }

    public struct Summary: Sendable, Decodable, Equatable {
        public let totalCostUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case totalCostUSD
            case totalCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalCostUSD =
                try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public let data: [Entry]
    public let summary: Summary?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case summary
        case sessions
        case totals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if container.contains(.type) {
            _ = try container.decode(String.self, forKey: .type)
            self.data = try container.decode([Entry].self, forKey: .data)
            self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
            return
        }

        self.data = try container.decode([Entry].self, forKey: .sessions)
        self.summary = try container.decodeIfPresent(Summary.self, forKey: .totals)
    }
}

public struct CostUsageMonthlyReport: Sendable, Decodable {
    public struct Entry: Sendable, Decodable, Equatable {
        public let month: String
        public let totalTokens: Int?
        public let costUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case month
            case totalTokens
            case costUSD
            case totalCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.month = try container.decode(String.self, forKey: .month)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.costUSD =
                try container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public struct Summary: Sendable, Decodable, Equatable {
        public let totalTokens: Int?
        public let totalCostUSD: Double?

        private enum CodingKeys: String, CodingKey {
            case totalTokens
            case costUSD
            case totalCostUSD
            case totalCost
        }

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
            self.totalCostUSD =
                try container.decodeIfPresent(Double.self, forKey: .totalCostUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .costUSD)
                ?? container.decodeIfPresent(Double.self, forKey: .totalCost)
        }
    }

    public let data: [Entry]
    public let summary: Summary?

    private enum CodingKeys: String, CodingKey {
        case type
        case data
        case summary
        case monthly
        case totals
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        if container.contains(.type) {
            _ = try container.decode(String.self, forKey: .type)
            self.data = try container.decode([Entry].self, forKey: .data)
            self.summary = try container.decodeIfPresent(Summary.self, forKey: .summary)
            return
        }

        self.data = try container.decode([Entry].self, forKey: .monthly)
        self.summary = try container.decodeIfPresent(Summary.self, forKey: .totals)
    }
}

private struct CostUsageLegacyTotals: Decodable {
    let totalInputTokens: Int?
    let totalOutputTokens: Int?
    let cacheReadTokens: Int?
    let cacheCreationTokens: Int?
    let totalTokens: Int?
    let totalCost: Double?

    private enum CodingKeys: String, CodingKey {
        case totalInputTokens
        case totalOutputTokens
        case cacheReadTokens
        case cacheCreationTokens
        case totalCacheReadTokens
        case totalCacheCreationTokens
        case totalTokens
        case totalCost
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.totalInputTokens = try container.decodeIfPresent(Int.self, forKey: .totalInputTokens)
        self.totalOutputTokens = try container.decodeIfPresent(Int.self, forKey: .totalOutputTokens)
        self.cacheReadTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheReadTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCacheReadTokens)
        self.cacheCreationTokens =
            try container.decodeIfPresent(Int.self, forKey: .cacheCreationTokens)
            ?? container.decodeIfPresent(Int.self, forKey: .totalCacheCreationTokens)
        self.totalTokens = try container.decodeIfPresent(Int.self, forKey: .totalTokens)
        self.totalCost = try container.decodeIfPresent(Double.self, forKey: .totalCost)
    }
}

private struct CostUsageAnyCodingKey: CodingKey {
    var intValue: Int?
    var stringValue: String

    init?(intValue: Int) {
        self.intValue = intValue
        self.stringValue = "\(intValue)"
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
        self.intValue = nil
    }
}

enum CostUsageDateParser {
    private static let isoWithFractionalSecondsKey = "CostUsageDateParser.isoWithFractionalSeconds"
    private static let isoInternetDateTimeKey = "CostUsageDateParser.isoInternetDateTime"
    private static let dayFormatterKey = "CostUsageDateParser.dayFormatter"
    private static let monthDayYearFormatterKey = "CostUsageDateParser.monthDayYearFormatter"
    private static let monthYearFormatterKey = "CostUsageDateParser.monthYearFormatter"
    private static let fullMonthYearFormatterKey = "CostUsageDateParser.fullMonthYearFormatter"
    private static let yearMonthFormatterKey = "CostUsageDateParser.yearMonthFormatter"

    static func parse(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let d = self.isoFormatter(
            key: self.isoWithFractionalSecondsKey,
            options: [.withInternetDateTime, .withFractionalSeconds])
            .date(from: trimmed)
        {
            return d
        }
        if let d = self.isoFormatter(key: self.isoInternetDateTimeKey, options: [.withInternetDateTime])
            .date(from: trimmed)
        {
            return d
        }
        if let d = self.dateFormatter(key: self.dayFormatterKey, format: "yyyy-MM-dd").date(from: trimmed) {
            return d
        }
        if let d = self.dateFormatter(key: self.monthDayYearFormatterKey, format: "MMM d, yyyy")
            .date(from: trimmed)
        {
            return d
        }

        return nil
    }

    static func parseMonth(_ text: String?) -> Date? {
        guard let text, !text.isEmpty else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)

        if let d = self.dateFormatter(key: self.monthYearFormatterKey, format: "MMM yyyy").date(from: trimmed) {
            return d
        }
        if let d = self.dateFormatter(key: self.fullMonthYearFormatterKey, format: "MMMM yyyy").date(from: trimmed) {
            return d
        }
        if let d = self.dateFormatter(key: self.yearMonthFormatterKey, format: "yyyy-MM").date(from: trimmed) {
            return d
        }

        return nil
    }

    private static func isoFormatter(
        key: String,
        options: ISO8601DateFormatter.Options) -> ISO8601DateFormatter
    {
        let threadDict = Thread.current.threadDictionary
        if let cached = threadDict[key] as? ISO8601DateFormatter {
            return cached
        }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = options
        threadDict[key] = formatter
        return formatter
    }

    private static func dateFormatter(key: String, format: String) -> DateFormatter {
        let threadDict = Thread.current.threadDictionary
        let timeZone = TimeZone.current
        let cacheKey = "\(key).\(timeZone.identifier)"
        if let cached = threadDict[cacheKey] as? DateFormatter {
            return cached
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = format
        formatter.isLenient = false
        threadDict[cacheKey] = formatter
        return formatter
    }
}

enum CostUsageBucketInterval {
    static func contains(
        _ date: Date,
        startTime: Date,
        endTime: Date) -> Bool
    {
        guard startTime < endTime else { return false }
        return startTime <= date && date < endTime
    }
}

enum CostUsageLocalDay {
    static func gregorianCalendar(matching calendar: Calendar = .current) -> Calendar {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    static func key(from date: Date, calendar: Calendar = .current) -> String {
        let calendar = Self.gregorianCalendar(matching: calendar)
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    static func date(fromKey key: String, calendar: Calendar = .current) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        return Self.gregorianCalendar(matching: calendar).date(from: DateComponents(
            year: year,
            month: month,
            day: day))
    }
}
