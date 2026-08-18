import CodexBarCore
import Foundation

// swiftlint:disable:next type_body_length
struct SpendDashboardModel: Equatable, Sendable {
    enum SourceKind: String, Sendable, Equatable {
        case native
        case openCodex
    }

    static let openCodexSourceID = "opencodex"
    struct ProviderInput: Sendable {
        let id: String
        let provider: UsageProvider
        let displayName: String
        let modelProviderName: String
        let snapshot: CostUsageTokenSnapshot
        let tokenActivityCache: CostUsageTokenActivityCache?

        init(
            id: String? = nil,
            provider: UsageProvider,
            displayName: String,
            modelProviderName: String? = nil,
            snapshot: CostUsageTokenSnapshot,
            tokenActivityCache: CostUsageTokenActivityCache? = nil,
            sourceKind: SpendDashboardModel.SourceKind = .native)
        {
            self.id = id ?? provider.rawValue
            self.provider = provider
            self.displayName = displayName
            self.modelProviderName = modelProviderName ?? displayName
            self.snapshot = snapshot
            self.tokenActivityCache = tokenActivityCache
            self.sourceKind = sourceKind
        }

        let sourceKind: SpendDashboardModel.SourceKind
    }

    struct SourceFilterItem: Identifiable, Equatable, Sendable {
        let id: String
        let displayName: String
    }

    struct ProviderRow: Identifiable, Equatable, Sendable {
        let id: String
        let rank: Int
        let provider: UsageProvider
        let displayName: String
        let totalTokens: Int?
        let totalCost: Double?
        let coveredDayCount: Int
        let sourceKind: SourceKind

        init(
            id: String,
            rank: Int,
            provider: UsageProvider,
            displayName: String,
            totalTokens: Int?,
            totalCost: Double?,
            coveredDayCount: Int,
            sourceKind: SourceKind = .native)
        {
            self.id = id
            self.rank = rank
            self.provider = provider
            self.displayName = displayName
            self.totalTokens = totalTokens
            self.totalCost = totalCost
            self.coveredDayCount = coveredDayCount
            self.sourceKind = sourceKind
        }
    }

    struct ModelRow: Identifiable, Equatable, Sendable {
        let rank: Int
        let provider: UsageProvider
        let providerName: String
        let modelName: String
        let totalTokens: Int?
        let totalCost: Double?
        let tokenMix: CostUsageTokenMix

        var id: String {
            "\(self.provider.rawValue):\(self.modelName)"
        }

        init(
            rank: Int,
            provider: UsageProvider,
            providerName: String,
            modelName: String,
            totalTokens: Int?,
            totalCost: Double?,
            tokenMix: CostUsageTokenMix = CostUsageTokenMix())
        {
            self.rank = rank
            self.provider = provider
            self.providerName = providerName
            self.modelName = modelName
            self.totalTokens = totalTokens
            self.totalCost = totalCost
            self.tokenMix = tokenMix
        }
    }

    /// A project roll-up scoped to the requested window. Projects are keyed per source so
    /// the same repository used under two Codex accounts stays attributed to each subscription.
    struct ProjectRow: Identifiable, Equatable, Sendable {
        let rank: Int
        let provider: UsageProvider
        let providerName: String
        let sourceID: String
        let projectName: String
        let path: String?
        let totalTokens: Int?
        let totalCost: Double?

        var id: String {
            "\(self.sourceID):\(self.projectName)"
        }
    }

    struct DailyPoint: Identifiable, Equatable, Sendable {
        let sourceID: String
        let provider: UsageProvider
        let providerName: String
        let day: Date
        let cost: Double
        let stackStart: Double
        let stackEnd: Double

        var id: String {
            "\(self.sourceID):\(Int(self.day.timeIntervalSince1970))"
        }
    }

    struct TokenActivityPoint: Identifiable, Equatable, Sendable {
        let day: Date
        /// `nil` means at least one included source cannot establish coverage for this day.
        /// This must stay distinct from a proven zero so the heatmap does not fabricate inactivity.
        let totalTokens: Int?
        /// `false` means at least one source never scanned this day, so the gap is a window edge
        /// rather than missing data. A `nil` total with `true` means every source scanned the day
        /// and still cannot report it, which is a real gap the heatmap must keep visible.
        let isScanned: Bool

        init(day: Date, totalTokens: Int?, isScanned: Bool = true) {
            self.day = day
            self.totalTokens = totalTokens
            self.isScanned = isScanned
        }

        var id: Date {
            self.day
        }
    }

    enum ModelHistoryCompleteness: Equatable, Sendable {
        case complete
        case incomplete
    }

    struct CurrencyGroup: Identifiable, Equatable, Sendable {
        let currencyCode: String
        let providers: [ProviderRow]
        let models: [ModelRow]
        let dailyPoints: [DailyPoint]
        let totalTokens: Int?
        let totalCost: Double?
        let coveredDayCount: Int
        let chartDomain: ClosedRange<Date>
        let modelHistoryCompleteness: ModelHistoryCompleteness
        let tokenMix: CostUsageTokenMix
        let coverage: CostUsageCoverageCounts
        let provenance: CostProvenance
        let meteredCost: Double?
        let sessions: [SessionRow]
        let projects: [ProjectRow]
        let overflowModelCount: Int
        let displayedModels: [ModelRow]
        let selectedDay: Date?

        var id: String {
            self.currencyCode
        }

        init(
            currencyCode: String,
            providers: [ProviderRow],
            models: [ModelRow],
            projects: [ProjectRow] = [],
            dailyPoints: [DailyPoint],
            totalTokens: Int?,
            totalCost: Double?,
            coveredDayCount: Int,
            chartDomain: ClosedRange<Date>,
            modelHistoryCompleteness: ModelHistoryCompleteness,
            tokenMix: CostUsageTokenMix = CostUsageTokenMix(),
            coverage: CostUsageCoverageCounts = CostUsageCoverageCounts(),
            provenance: CostProvenance = .unknown,
            meteredCost: Double? = nil,
            sessions: [SessionRow] = [],
            overflowModelCount: Int = 0,
            selectedDay: Date? = nil)
        {
            self.currencyCode = currencyCode
            self.providers = providers
            self.models = models
            self.dailyPoints = dailyPoints
            self.totalTokens = totalTokens
            self.totalCost = totalCost
            self.coveredDayCount = coveredDayCount
            self.chartDomain = chartDomain
            self.modelHistoryCompleteness = modelHistoryCompleteness
            self.tokenMix = tokenMix
            self.coverage = coverage
            self.provenance = provenance
            self.meteredCost = meteredCost
            self.sessions = sessions
            self.projects = projects
            self.overflowModelCount = overflowModelCount
            self.displayedModels = Array(models.prefix(Self.modelRowDisplayLimit))
            self.selectedDay = selectedDay
        }

        static let modelRowDisplayLimit = 8
    }

    struct SessionRow: Identifiable, Equatable, Sendable {
        let id: String
        let sourceID: String
        let provider: UsageProvider
        let displayName: String
        let lastActivity: Date
        let totalTokens: Int?
        let totalCost: Double?
        let modelName: String?
    }

    struct HourlyPoint: Identifiable, Equatable, Sendable {
        let hour: Date
        let tokens: Int
        let cost: Double?

        var id: Date {
            self.hour
        }
    }

    let requestedDays: Int
    let groups: [CurrencyGroup]
    let availableSources: [SourceFilterItem]
    let tokenActivity: [TokenActivityPoint]
    let hourlyPoints: [HourlyPoint]
    let selectedDay: Date?

    static let tokenActivityDayCount = 365
    static let modelRowDisplayLimit = 8

    init(
        requestedDays: Int,
        groups: [CurrencyGroup],
        availableSources: [SourceFilterItem] = [],
        tokenActivity: [TokenActivityPoint] = [],
        hourlyPoints: [HourlyPoint] = [],
        selectedDay: Date? = nil)
    {
        self.requestedDays = requestedDays
        self.groups = groups
        self.availableSources = availableSources
        self.tokenActivity = tokenActivity
        self.hourlyPoints = hourlyPoints
        self.selectedDay = selectedDay
    }

    static func build(
        inputs: [ProviderInput],
        requestedDays: Int,
        now: Date,
        calendar: Calendar = .current,
        preferredCurrencyCode: String = "auto",
        hiddenSourceIDs: Set<String> = [],
        hideNativeCodexWhenOpenCodexPresent: Bool = false,
        selectedDay: Date? = nil) -> Self
    {
        let days = max(1, min(SpendDashboardSource.scanDays, requestedDays))
        let calculationCalendar = Self.gregorianCalendar(timeZone: calendar.timeZone)
        let availableSources = inputs
            .map { SourceFilterItem(id: $0.id, displayName: $0.displayName) }
            .sorted { $0.id < $1.id }
        let visibleInputs = Self.visibleInputs(
            inputs,
            hiddenSourceIDs: hiddenSourceIDs,
            hideNativeCodexWhenOpenCodexPresent: hideNativeCodexWhenOpenCodexPresent)
        let classifiedInputs = visibleInputs.compactMap { input -> ClassifiedInput? in
            guard let sourceCurrencyCode = Self.currencyCode(input.snapshot.currencyCode) else { return nil }
            let targetCurrencyCode = UsageFormatter.effectiveCurrencyCode(
                preferred: preferredCurrencyCode,
                providerCurrency: sourceCurrencyCode)
            let conversion = CurrencyExchange.shared.convert(
                amount: 1,
                from: sourceCurrencyCode,
                to: targetCurrencyCode)
            return ClassifiedInput(
                currencyCode: conversion == nil ? sourceCurrencyCode : targetCurrencyCode,
                input: input,
                costMultiplier: conversion ?? 1)
        }
        let groups = Dictionary(grouping: classifiedInputs, by: { $0.currencyCode })
            .map { currencyCode, inputs in
                Self.buildCurrencyGroup(
                    currencyCode: currencyCode,
                    inputs: inputs,
                    days: days,
                    now: now,
                    calendar: calculationCalendar,
                    selectedDay: selectedDay.map { calculationCalendar.startOfDay(for: $0) })
            }
            .sorted { $0.currencyCode < $1.currencyCode }
        return Self(
            requestedDays: days,
            groups: groups,
            availableSources: availableSources,
            tokenActivity: Self.tokenActivity(
                inputs: visibleInputs,
                now: now,
                calendar: calculationCalendar),
            hourlyPoints: Self.hourlyPoints(
                inputs: visibleInputs,
                days: days,
                now: now,
                calendar: calculationCalendar),
            selectedDay: selectedDay.map { calculationCalendar.startOfDay(for: $0) })
    }

    static func visibleInputs(
        _ inputs: [ProviderInput],
        hiddenSourceIDs: Set<String>,
        hideNativeCodexWhenOpenCodexPresent: Bool) -> [ProviderInput]
    {
        var filtered = inputs.filter { !hiddenSourceIDs.contains($0.id) }
        let hasOpenCodex = filtered.contains { $0.sourceKind == .openCodex }
        if hideNativeCodexWhenOpenCodexPresent, hasOpenCodex {
            // Provider-specific by design: the OpenCodex source can explicitly replace native Codex rows.
            filtered.removeAll { $0.sourceKind == .native && $0.provider == .codex }
        }
        return filtered
    }

    private struct ClassifiedInput {
        let currencyCode: String
        let input: ProviderInput
        let costMultiplier: Double
    }

    struct InputSummary {
        let input: ProviderInput
        let costMultiplier: Double
        let entries: [WindowEntry]
        let totalTokens: Int?
        let totalCost: Double?
        let coveredInterval: ClosedRange<Date>?
        let coveredDayCount: Int
        let hasInvalidCostHistory: Bool
    }

    struct WindowEntry {
        let day: Date
        let entry: CostUsageDailyReport.Entry
    }

    private struct DailyKey: Hashable {
        let day: Date
        let sourceID: String
    }

    private struct DailyAccumulator {
        let provider: UsageProvider
        let providerName: String
        var cost: Double?
        var invalid = false
        var overflowed = false
    }

    private struct TokenActivityInputSummary {
        let coveredInterval: ClosedRange<Date>?
        let totalsByDay: [Date: Int]
        let invalidDays: Set<Date>
        let hasCompleteHistory: Bool
        let isGloballyInvalid: Bool

        /// Whether the scan window reached this day at all. A day outside the window is unknown
        /// because nobody looked; a day inside it is unknown because the data itself is missing.
        func scanned(_ day: Date) -> Bool {
            self.coveredInterval?.contains(day) == true
        }

        func tokens(on day: Date) -> Int? {
            guard self.scanned(day),
                  !self.isGloballyInvalid,
                  !self.invalidDays.contains(day)
            else { return nil }
            if let tokens = self.totalsByDay[day] {
                return tokens
            }
            return self.hasCompleteHistory ? 0 : nil
        }
    }

    // swiftlint:disable:next function_parameter_count
    private static func buildCurrencyGroup(
        currencyCode: String,
        inputs: [ClassifiedInput],
        days: Int,
        now: Date,
        calendar: Calendar,
        selectedDay: Date?) -> CurrencyGroup
    {
        let bounds = Self.bounds(days: days, now: now, calendar: calendar)
        let summaries = inputs.map { classified in
            Self.inputSummary(
                input: classified.input,
                costMultiplier: classified.costMultiplier,
                bounds: bounds,
                calendar: calendar)
        }
        let providers = Self.providerRows(summaries)
        let scopedSummaries = Self.summaries(summaries, matching: selectedDay)
        let modelSummaries = scopedSummaries.filter { summary in
            let summaryModelHistory = Self.modelSummary(summaries: [summary])
            if summary.totalCost != nil {
                return summaryModelHistory.completeness == .complete ||
                    Self.canRetainPartialCodexModelHistory(summary)
            }
            return Self.canRetainUnpricedModelHistory(summary)
        }
        // Unpriced named models can still list. Incomplete priced coverage stays hidden so a
        // partial list cannot look like a lower-bound total.
        let modelSummary = Self.modelSummary(summaries: modelSummaries)
        let modelHistoryCompleteness = modelSummaries.count == scopedSummaries.count &&
            modelSummary.completeness == .complete
            ? ModelHistoryCompleteness.complete
            : ModelHistoryCompleteness.incomplete
        let dailyPoints = Self.dailyPoints(summaries: summaries)
        var tokenMix = CostUsageTokenMix()
        var coverage = CostUsageCoverageCounts()
        var metered: Double?
        var sawMetered = false
        var sawEstimate = false
        for summary in scopedSummaries {
            for windowEntry in summary.entries {
                tokenMix.merge(.from(entry: windowEntry.entry))
                coverage.merge(windowEntry.entry.coverageCounts)
            }
            if selectedDay == nil,
               let meteredCost = summary.input.snapshot.meteredCostUSD,
               days >= summary.input.snapshot.historyDays
            {
                sawMetered = true
                metered = (metered ?? 0) + meteredCost * summary.costMultiplier
            }
            if summary.totalCost != nil {
                sawEstimate = true
            }
        }
        let provenance: CostProvenance = switch (sawMetered, sawEstimate) {
        case (true, true): .mixed
        case (true, false): .vendorMetered
        case (false, true): .listPriceEstimate
        case (false, false): .unknown
        }
        let overflowCount = max(0, modelSummary.rows.count - CurrencyGroup.modelRowDisplayLimit)
        return CurrencyGroup(
            currencyCode: currencyCode,
            providers: providers,
            models: modelSummary.rows,
            projects: Self.projectRows(summaries: summaries, bounds: bounds, calendar: calendar),
            dailyPoints: dailyPoints,
            totalTokens: Self.knownIntSum(providers.map(\.totalTokens)),
            totalCost: Self.knownCostSum(providers.map(\.totalCost)),
            coveredDayCount: Self.commonCoverageDayCount(summaries: summaries, calendar: calendar),
            chartDomain: Self.chartDomain(bounds: bounds, calendar: calendar),
            modelHistoryCompleteness: modelHistoryCompleteness,
            tokenMix: tokenMix,
            coverage: coverage,
            provenance: provenance,
            meteredCost: sawMetered ? metered : nil,
            sessions: Self.sessionRows(summaries: summaries, bounds: bounds, calendar: calendar),
            overflowModelCount: overflowCount,
            selectedDay: selectedDay)
    }

    private static func summaries(_ summaries: [InputSummary], matching selectedDay: Date?) -> [InputSummary] {
        guard let selectedDay else { return summaries }
        return summaries.map { summary in
            InputSummary(
                input: summary.input,
                costMultiplier: summary.costMultiplier,
                entries: summary.entries.filter { $0.day == selectedDay },
                totalTokens: summary.totalTokens,
                totalCost: summary.totalCost,
                coveredInterval: summary.coveredInterval,
                coveredDayCount: summary.coveredDayCount,
                hasInvalidCostHistory: summary.hasInvalidCostHistory)
        }
    }

    private static func inputSummary(
        input: ProviderInput,
        costMultiplier: Double,
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> InputSummary
    {
        let coveredInterval = Self.coverageInterval(
            input: input,
            bounds: bounds,
            displayCalendar: calendar)
        var entries: [WindowEntry] = []
        var hasInvalidCostHistory = false
        var hasInvalidTokenHistory = false
        for entry in input.snapshot.daily {
            guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: calendar) else {
                hasInvalidCostHistory = hasInvalidCostHistory || !Self.hasProvenZeroCost(entry)
                hasInvalidTokenHistory = hasInvalidTokenHistory || !Self.hasProvenZeroTokens(entry)
                continue
            }
            guard bounds.contains(day) else { continue }
            guard coveredInterval?.contains(day) == true else {
                hasInvalidCostHistory = hasInvalidCostHistory || !Self.hasProvenZeroCost(entry)
                hasInvalidTokenHistory = hasInvalidTokenHistory || !Self.hasProvenZeroTokens(entry)
                continue
            }
            entries.append(WindowEntry(day: day, entry: entry))
        }
        let coveredDayCount = Self.dayCount(in: coveredInterval, calendar: calendar)
        let hasCompleteTokenHistory = Self.hasCompleteTokenHistory(input, displayCalendar: calendar)
        let tokenAggregateIsConsistent = input.snapshot.last30DaysTokens == nil || hasCompleteTokenHistory
        let totalTokens = hasInvalidTokenHistory || !tokenAggregateIsConsistent
            ? nil
            : entries.isEmpty
            ? (coveredDayCount > 0 && hasCompleteTokenHistory ? 0 : nil)
            : Self.completeIntSum(entries.map { Self.nonnegative($0.entry.totalTokens) })
        let hasConsistentCostHistory = Self.hasConsistentCostHistory(input, displayCalendar: calendar)
        let costAggregateIsConsistent = input.snapshot.last30DaysCostUSD == nil || hasConsistentCostHistory
        let invalidCostHistory = hasInvalidCostHistory || !costAggregateIsConsistent
        let totalCost = invalidCostHistory
            ? nil
            : entries.isEmpty
            ? (coveredDayCount > 0 && hasConsistentCostHistory ? 0 : nil)
            : hasConsistentCostHistory
            ? Self.safeCostSum(entries.compactMap {
                Self.validCost($0.entry.costUSD).map { $0 * costMultiplier }
            })
            : Self.completeCostSum(entries.map {
                Self.validCost($0.entry.costUSD).map { $0 * costMultiplier }
            })
        return InputSummary(
            input: input,
            costMultiplier: costMultiplier,
            entries: entries,
            totalTokens: totalTokens,
            totalCost: totalCost,
            coveredInterval: coveredInterval,
            coveredDayCount: coveredDayCount,
            hasInvalidCostHistory: invalidCostHistory)
    }

    private static func providerRows(_ summaries: [InputSummary]) -> [ProviderRow] {
        summaries.enumerated()
            .sorted { lhs, rhs in
                switch (lhs.element.totalCost, rhs.element.totalCost) {
                case let (left?, right?) where left != right: left > right
                case (_?, nil): true
                case (nil, _?): false
                default: lhs.offset < rhs.offset
                }
            }
            .enumerated()
            .map { rank, entry in
                ProviderRow(
                    id: entry.element.input.id,
                    rank: rank + 1,
                    provider: entry.element.input.provider,
                    displayName: entry.element.input.displayName,
                    totalTokens: entry.element.totalTokens,
                    totalCost: entry.element.totalCost,
                    coveredDayCount: entry.element.coveredDayCount,
                    sourceKind: entry.element.input.sourceKind)
            }
    }

    /// Rolls per-project daily entries up to window-scoped rows, mirroring the proven-zero
    /// discipline of provider totals: only days inside the window and the source's established
    /// coverage interval count, and one unknown day makes that project's aggregate unknown.
    /// Projects with no attributable day in the window are dropped rather than shown as zero.
    private static func projectRows(
        summaries: [InputSummary],
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> [ProjectRow]
    {
        struct Key: Hashable {
            let sourceID: String
            let name: String
        }

        struct Accumulator {
            let provider: UsageProvider
            let providerName: String
            let path: String?
            var tokens: Int?
            var cost: Double?
            var sawTokens = false
            var sawCost = false
            var invalidTokens = false
            var invalidCost = false
            var overflowedTokens = false
            var overflowedCost = false
        }

        var aggregates: [Key: Accumulator] = [:]
        for summary in summaries {
            let input = summary.input
            for project in input.snapshot.projects {
                let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = Key(sourceID: input.id, name: name)
                var aggregate = aggregates[key] ?? Accumulator(
                    provider: input.provider,
                    providerName: input.modelProviderName,
                    path: project.path,
                    tokens: 0,
                    cost: 0)
                for entry in project.daily {
                    guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: calendar),
                          bounds.contains(day),
                          summary.coveredInterval?.contains(day) == true
                    else { continue }
                    if let tokens = Self.nonnegative(entry.totalTokens) {
                        aggregate.sawTokens = true
                        aggregate.tokens = Self.add(
                            tokens,
                            to: aggregate.tokens,
                            overflowed: &aggregate.overflowedTokens)
                    } else if !Self.hasProvenZeroTokens(entry) {
                        aggregate.invalidTokens = true
                    }
                    if let cost = Self.validCost(entry.costUSD).map({ $0 * summary.costMultiplier }) {
                        aggregate.sawCost = true
                        aggregate.cost = Self.add(
                            cost,
                            to: aggregate.cost,
                            overflowed: &aggregate.overflowedCost)
                    } else if !Self.hasProvenZeroCost(entry) {
                        aggregate.invalidCost = true
                    }
                }
                aggregates[key] = aggregate
            }
        }

        return aggregates
            .map { key, value in
                ProjectRow(
                    rank: 0,
                    provider: value.provider,
                    providerName: value.providerName,
                    sourceID: key.sourceID,
                    projectName: key.name,
                    path: value.path,
                    totalTokens: value.sawTokens && !value.invalidTokens && !value.overflowedTokens
                        ? value.tokens
                        : nil,
                    totalCost: value.sawCost && !value.invalidCost && !value.overflowedCost
                        ? value.cost
                        : nil)
            }
            .filter { row in
                // A project the window never touched has no attributable spend; the scanner only
                // emits projects with recorded usage, so dropping keeps zeros from being fabricated.
                row.totalTokens != nil || row.totalCost != nil
            }
            .sorted { lhs, rhs in
                switch (lhs.totalCost, rhs.totalCost) {
                case let (left?, right?) where left != right: return left > right
                case (_?, nil): return true
                case (nil, _?): return false
                default:
                    if lhs.providerName != rhs.providerName {
                        return lhs.providerName < rhs.providerName
                    }
                    return lhs.projectName < rhs.projectName
                }
            }
            .enumerated()
            .map { rank, row in
                ProjectRow(
                    rank: rank + 1,
                    provider: row.provider,
                    providerName: row.providerName,
                    sourceID: row.sourceID,
                    projectName: row.projectName,
                    path: row.path,
                    totalTokens: row.totalTokens,
                    totalCost: row.totalCost)
            }
    }

    static func hasProvenZeroCost(_ entry: CostUsageDailyReport.Entry) -> Bool {
        self.validCost(entry.costUSD) == 0
            && (entry.modelBreakdowns?.allSatisfy(self.hasProvenZeroCost) ?? true)
    }

    static func hasProvenZeroCost(_ breakdown: CostUsageDailyReport.ModelBreakdown) -> Bool {
        let optionalCosts = [breakdown.standardCostUSD, breakdown.priorityCostUSD]
        return Self.validCost(breakdown.costUSD) == 0
            && optionalCosts.allSatisfy { value in
                value == nil || Self.validCost(value) == 0
            }
    }

    static func hasProvenZeroTokens(_ entry: CostUsageDailyReport.Entry) -> Bool {
        let optionalTokens = [
            entry.inputTokens,
            entry.cacheReadTokens,
            entry.cacheCreationTokens,
            entry.outputTokens,
        ]
        return Self.nonnegative(entry.totalTokens) == 0
            && optionalTokens.allSatisfy { $0 == nil || Self.nonnegative($0) == 0 }
            && (entry.modelBreakdowns?.allSatisfy(Self.hasProvenZeroTokens) ?? true)
    }

    static func hasProvenZeroTokens(_ breakdown: CostUsageDailyReport.ModelBreakdown) -> Bool {
        let optionalTokens = [breakdown.standardTokens, breakdown.priorityTokens]
        return Self.nonnegative(breakdown.totalTokens) == 0
            && optionalTokens.allSatisfy { $0 == nil || Self.nonnegative($0) == 0 }
    }

    static func costsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
        let scaledTolerance = max(abs(lhs), abs(rhs)) * 1e-12
        let tolerance = min(1e-6, max(1e-9, scaledTolerance))
        return abs(lhs - rhs) <= tolerance
    }

    /// A completed Codex scan can carry an authoritative priced subtotal while exact request-tier
    /// evidence leaves some model/day rows unpriceable. Those explicit gaps do not contradict the subtotal.
    private static func hasConsistentCostHistory(
        _ input: ProviderInput,
        displayCalendar: Calendar) -> Bool
    {
        guard let aggregate = validCost(input.snapshot.last30DaysCostUSD) else { return false }
        let coverage = Self.sourceCoverageInterval(input: input, displayCalendar: displayCalendar)
        var dailyTotal = 0.0
        for entry in input.snapshot.daily {
            guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: displayCalendar) else {
                guard Self.hasProvenZeroCost(entry) else { return false }
                continue
            }
            guard coverage.contains(day) else { continue }
            guard let cost = validCost(entry.costUSD) else {
                // Provider-specific by design: Codex and Cursor can omit prices on some model/day rows.
                guard input.snapshot.historyCoverageIsEstablished,
                      Self.hasExplicitlyUnpriceableLedgerCost(input.provider, entry)
                else { return false }
                continue
            }
            dailyTotal += cost
            guard dailyTotal.isFinite else { return false }
        }
        return self.costsMatch(aggregate, dailyTotal)
    }

    private static func hasCompleteTokenHistory(
        _ input: ProviderInput,
        displayCalendar: Calendar) -> Bool
    {
        guard let aggregate = nonnegative(input.snapshot.last30DaysTokens) else { return false }
        let coverage = Self.sourceCoverageInterval(input: input, displayCalendar: displayCalendar)
        var dailyTotal = 0
        for entry in input.snapshot.daily {
            guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: displayCalendar) else {
                guard Self.hasProvenZeroTokens(entry) else { return false }
                continue
            }
            guard coverage.contains(day) else { continue }
            guard let tokens = nonnegative(entry.totalTokens) else { return false }
            let addition = dailyTotal.addingReportingOverflow(tokens)
            guard !addition.overflow else { return false }
            dailyTotal = addition.partialValue
        }
        return aggregate == dailyTotal
    }

    private static func dailyPoints(summaries: [InputSummary]) -> [DailyPoint] {
        var aggregates: [DailyKey: DailyAccumulator] = [:]
        for summary in summaries where !summary.hasInvalidCostHistory {
            let input = summary.input
            for windowEntry in summary.entries {
                let day = windowEntry.day
                let entry = windowEntry.entry
                let key = DailyKey(day: day, sourceID: input.id)
                var aggregate = aggregates[key] ?? DailyAccumulator(
                    provider: input.provider,
                    providerName: input.displayName,
                    cost: 0)
                if let cost = Self.validCost(entry.costUSD).map({ $0 * summary.costMultiplier }) {
                    aggregate.cost = Self.add(cost, to: aggregate.cost, overflowed: &aggregate.overflowed)
                } else {
                    aggregate.invalid = true
                }
                aggregates[key] = aggregate
            }
        }

        let byDay = Dictionary(grouping: aggregates, by: { $0.key.day })
        return byDay.keys.sorted().flatMap { day -> [DailyPoint] in
            let rows = (byDay[day] ?? [])
                .filter { !$0.value.invalid && !$0.value.overflowed && $0.value.cost != nil }
                .sorted { $0.key.sourceID < $1.key.sourceID }
            guard let total = Self.completeCostSum(rows.map(\.value.cost)), total.isFinite else { return [] }
            var cursor = 0.0
            var points: [DailyPoint] = []
            for (key, value) in rows {
                guard let cost = value.cost else { return [] }
                let start = cursor
                cursor += cost
                points.append(DailyPoint(
                    sourceID: key.sourceID,
                    provider: value.provider,
                    providerName: value.providerName,
                    day: day,
                    cost: cost,
                    stackStart: start,
                    stackEnd: cursor))
            }
            return points
        }
    }

    private static func tokenActivity(
        inputs: [ProviderInput],
        now: Date,
        calendar: Calendar) -> [TokenActivityPoint]
    {
        guard !inputs.isEmpty else { return [] }
        let bounds = Self.bounds(days: Self.tokenActivityDayCount, now: now, calendar: calendar)
        let summaries = inputs.map {
            Self.tokenActivityInputSummary(input: $0, bounds: bounds, calendar: calendar)
        }
        return (0..<Self.tokenActivityDayCount).compactMap { offset in
            guard let day = calendar.date(byAdding: .day, value: offset, to: bounds.lowerBound) else {
                return nil
            }
            var total = 0
            var scannedContributors = 0
            var hasUnresolvedScannedProvider = false
            for summary in summaries {
                guard summary.scanned(day) else { continue }
                scannedContributors += 1
                guard let tokens = summary.tokens(on: day) else {
                    hasUnresolvedScannedProvider = true
                    continue
                }
                let addition = total.addingReportingOverflow(tokens)
                total = addition.overflow ? Int.max : addition.partialValue
            }
            guard scannedContributors > 0 else {
                return TokenActivityPoint(day: day, totalTokens: nil, isScanned: false)
            }
            if hasUnresolvedScannedProvider {
                return TokenActivityPoint(day: day, totalTokens: nil, isScanned: true)
            }
            return TokenActivityPoint(day: day, totalTokens: total, isScanned: true)
        }
    }

    private static func tokenActivityInputSummary(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> TokenActivityInputSummary
    {
        let coveredInterval = Self.tokenActivityCoverageInterval(
            input: input,
            bounds: bounds,
            displayCalendar: calendar)
        var totalsByDay: [Date: Int] = [:]
        var invalidDays: Set<Date> = []
        var hasUnplacedTokens = false
        for entry in input.tokenActivityCache?.daily ?? input.snapshot.daily {
            guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: calendar) else {
                hasUnplacedTokens = hasUnplacedTokens || !Self.hasProvenZeroTokens(entry)
                continue
            }
            guard coveredInterval?.contains(day) == true else { continue }
            guard let tokens = Self.nonnegative(entry.totalTokens) else {
                invalidDays.insert(day)
                continue
            }
            guard !invalidDays.contains(day) else { continue }
            let addition = (totalsByDay[day] ?? 0).addingReportingOverflow(tokens)
            if addition.overflow {
                totalsByDay.removeValue(forKey: day)
                invalidDays.insert(day)
            } else {
                totalsByDay[day] = addition.partialValue
            }
        }

        let hasCompleteHistory = input.tokenActivityCache != nil
            || Self.hasCompleteTokenHistory(input, displayCalendar: calendar)
        let aggregateIsInconsistent = input.tokenActivityCache == nil
            && input.snapshot.last30DaysTokens != nil
            && !hasCompleteHistory
        return TokenActivityInputSummary(
            coveredInterval: coveredInterval,
            totalsByDay: totalsByDay,
            invalidDays: invalidDays,
            hasCompleteHistory: hasCompleteHistory,
            isGloballyInvalid: hasUnplacedTokens || aggregateIsInconsistent)
    }

    private static func tokenActivityCoverageInterval(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        displayCalendar: Calendar) -> ClosedRange<Date>?
    {
        guard let cache = input.tokenActivityCache else {
            return self.coverageInterval(input: input, bounds: bounds, displayCalendar: displayCalendar)
        }
        guard let start = Self.day(
            cache.coverageSinceKey,
            provider: input.provider,
            displayCalendar: displayCalendar),
            let end = Self.day(
                cache.coverageUntilKey,
                provider: input.provider,
                displayCalendar: displayCalendar)
        else { return nil }
        let overlapStart = max(bounds.lowerBound, start)
        let overlapEnd = min(bounds.upperBound, end)
        return overlapStart <= overlapEnd ? overlapStart...overlapEnd : nil
    }

    private static func bounds(days: Int, now: Date, calendar: Calendar) -> ClosedRange<Date> {
        let end = calendar.startOfDay(for: now)
        let start = calendar.date(byAdding: .day, value: -(days - 1), to: end) ?? end
        return start...end
    }

    private static func gregorianCalendar(timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar
    }

    private static func chartDomain(bounds: ClosedRange<Date>, calendar: Calendar) -> ClosedRange<Date> {
        let end = calendar.date(byAdding: .day, value: 1, to: bounds.upperBound) ?? bounds.upperBound
        return bounds.lowerBound...end
    }

    private static func coverageInterval(
        input: ProviderInput,
        bounds: ClosedRange<Date>,
        displayCalendar: Calendar) -> ClosedRange<Date>?
    {
        guard input.snapshot.historyCoverageIsEstablished else { return nil }
        let sourceCoverage = Self.sourceCoverageInterval(input: input, displayCalendar: displayCalendar)
        let overlapStart = max(bounds.lowerBound, sourceCoverage.lowerBound)
        let overlapEnd = min(bounds.upperBound, sourceCoverage.upperBound)
        guard overlapStart <= overlapEnd else { return nil }
        return overlapStart...overlapEnd
    }

    private static func sourceCoverageInterval(
        input: ProviderInput,
        displayCalendar: Calendar) -> ClosedRange<Date>
    {
        let bucketCalendar = Self.bucketCalendar(for: input.provider, displayCalendar: displayCalendar)
        let bucketEnd = bucketCalendar.startOfDay(for: input.snapshot.updatedAt)
        let scanEnd = displayCalendar.startOfDay(for: bucketEnd)
        let scanDays = max(1, input.snapshot.historyDays)
        let bucketStart = bucketCalendar.date(byAdding: .day, value: -(scanDays - 1), to: bucketEnd) ?? bucketEnd
        let scanStart = displayCalendar.startOfDay(for: bucketStart)
        return scanStart...scanEnd
    }

    private static func commonCoverageDayCount(summaries: [InputSummary], calendar: Calendar) -> Int {
        guard let first = summaries.first?.coveredInterval else { return 0 }
        var intersection = first
        for summary in summaries.dropFirst() {
            guard let interval = summary.coveredInterval else { return 0 }
            let start = max(intersection.lowerBound, interval.lowerBound)
            let end = min(intersection.upperBound, interval.upperBound)
            guard start <= end else { return 0 }
            intersection = start...end
        }
        return Self.dayCount(in: intersection, calendar: calendar)
    }

    private static func dayCount(in interval: ClosedRange<Date>?, calendar: Calendar) -> Int {
        guard let interval else { return 0 }
        return (calendar.dateComponents([.day], from: interval.lowerBound, to: interval.upperBound).day ?? 0) + 1
    }

    private static func day(
        _ rawValue: String,
        provider: UsageProvider,
        displayCalendar: Calendar) -> Date?
    {
        let bytes = Array(rawValue.utf8)
        let digitIndices = [0, 1, 2, 3, 5, 6, 8, 9]
        guard bytes.count == 10,
              bytes[4] == 45,
              bytes[7] == 45,
              digitIndices.allSatisfy({ (48...57).contains(bytes[$0]) })
        else { return nil }
        let parts = rawValue.split(separator: "-")
        let bucketCalendar = Self.bucketCalendar(for: provider, displayCalendar: displayCalendar)
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]),
              let date = bucketCalendar.date(from: DateComponents(year: year, month: month, day: day))
        else { return nil }
        guard bucketCalendar.dateComponents([.year, .month, .day], from: date) == DateComponents(
            year: year,
            month: month,
            day: day)
        else { return nil }
        return displayCalendar.startOfDay(for: date)
    }

    private static func bucketCalendar(for provider: UsageProvider, displayCalendar: Calendar) -> Calendar {
        guard provider == .mistral else { return displayCalendar }
        // Mistral labels both daily buckets and snapshot coverage by UTC day. Map each UTC boundary into the
        // containing local dashboard day instead of reinterpreting the label as a local date.
        return self.gregorianCalendar(timeZone: TimeZone(secondsFromGMT: 0) ?? .gmt)
    }

    private static func currencyCode(_ rawValue: String) -> String? {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        return value.isEmpty || value == "XXX" ? nil : value
    }

    static func validCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    static func nonnegative(_ value: Int?) -> Int? {
        guard let value, value >= 0 else { return nil }
        return value
    }

    private static func safeCostSum(_ values: [Double]) -> Double? {
        guard !values.isEmpty else { return nil }
        var result = 0.0
        for value in values {
            result += value
            guard result.isFinite else { return nil }
        }
        return result
    }

    private static func completeCostSum(_ values: [Double?]) -> Double? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return self.safeCostSum(values.compactMap(\.self))
    }

    private static func knownCostSum(_ values: [Double?]) -> Double? {
        self.safeCostSum(values.compactMap(\.self))
    }

    private static func safeIntSum(_ values: [Int]) -> Int? {
        guard !values.isEmpty else { return nil }
        var result = 0
        for value in values {
            let addition = result.addingReportingOverflow(value)
            guard !addition.overflow else { return nil }
            result = addition.partialValue
        }
        return result
    }

    private static func completeIntSum(_ values: [Int?]) -> Int? {
        guard values.allSatisfy({ $0 != nil }) else { return nil }
        return self.safeIntSum(values.compactMap(\.self))
    }

    private static func knownIntSum(_ values: [Int?]) -> Int? {
        self.safeIntSum(values.compactMap(\.self))
    }

    static func add(_ value: Int, to current: Int?, overflowed: inout Bool) -> Int? {
        guard !overflowed, let current else { return nil }
        let addition = current.addingReportingOverflow(value)
        if addition.overflow {
            overflowed = true
            return nil
        }
        return addition.partialValue
    }

    static func add(_ value: Double, to current: Double?, overflowed: inout Bool) -> Double? {
        guard !overflowed, let current else { return nil }
        let result = current + value
        guard result.isFinite else {
            overflowed = true
            return nil
        }
        return result
    }

    static func sessionRows(
        summaries: [InputSummary],
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> [SessionRow]
    {
        let rows = summaries.flatMap { summary -> [SessionRow] in
            summary.input.snapshot.sessions.compactMap { session -> SessionRow? in
                let day = calendar.startOfDay(for: session.lastActivity)
                guard bounds.contains(day) else { return nil }
                let modelName = session.modelBreakdowns.max {
                    ($0.totalTokens ?? 0) < ($1.totalTokens ?? 0)
                }?.modelName
                return SessionRow(
                    id: "\(summary.input.id):\(session.sessionID)",
                    sourceID: summary.input.id,
                    provider: summary.input.provider,
                    displayName: summary.input.displayName,
                    lastActivity: session.lastActivity,
                    totalTokens: session.totalTokens,
                    totalCost: session.costUSD.map { $0 * summary.costMultiplier },
                    modelName: modelName)
            }
        }
        .sorted { lhs, rhs in
            if lhs.lastActivity != rhs.lastActivity {
                return lhs.lastActivity > rhs.lastActivity
            }
            return lhs.id < rhs.id
        }
        return Array(rows.prefix(12))
    }

    static func hourlyPoints(
        inputs: [ProviderInput],
        days: Int,
        now: Date,
        calendar: Calendar) -> [HourlyPoint]
    {
        let today = calendar.startOfDay(for: now)
        guard let windowStart = calendar.date(byAdding: .day, value: -(days - 1), to: today) else { return [] }
        var totals: [Date: (tokens: Int, cost: Double)] = [:]
        for input in inputs {
            for session in input.snapshot.sessions {
                let hour = calendar.dateInterval(of: .hour, for: session.lastActivity)?.start ?? session.lastActivity
                guard hour >= windowStart else { continue }
                let current = totals[hour] ?? (0, 0)
                totals[hour] = (
                    current.tokens + max(0, session.totalTokens ?? 0),
                    current.cost + max(0, session.costUSD ?? 0))
            }
        }
        return totals.keys.sorted().map { hour in
            let value = totals[hour] ?? (0, 0)
            return HourlyPoint(hour: hour, tokens: value.tokens, cost: value.cost > 0 ? value.cost : nil)
        }
    }
}

extension SpendDashboardModel.CurrencyGroup {
    var pricedProviderCount: Int {
        self.providers.count { $0.totalCost != nil }
    }

    var hasPartialCost: Bool {
        let values = self.providers.map(\.totalCost)
        return values.contains { $0 != nil } && values.contains { $0 == nil }
    }

    var hasPartialTokens: Bool {
        let values = self.providers.map(\.totalTokens)
        return values.contains { $0 != nil } && values.contains { $0 == nil }
    }
}
