import CodexBarCore
import Foundation

struct SpendDashboardModel: Equatable, Sendable {
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
            tokenActivityCache: CostUsageTokenActivityCache? = nil)
        {
            self.id = id ?? provider.rawValue
            self.provider = provider
            self.displayName = displayName
            self.modelProviderName = modelProviderName ?? displayName
            self.snapshot = snapshot
            self.tokenActivityCache = tokenActivityCache
        }
    }

    struct ProviderRow: Identifiable, Equatable, Sendable {
        let id: String
        let rank: Int
        let provider: UsageProvider
        let displayName: String
        let totalTokens: Int?
        let totalCost: Double?
        let coveredDayCount: Int
    }

    struct ModelRow: Identifiable, Equatable, Sendable {
        let rank: Int
        let provider: UsageProvider
        let providerName: String
        let modelName: String
        let totalTokens: Int?
        let totalCost: Double?

        var id: String {
            "\(self.provider.rawValue):\(self.modelName)"
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

        var id: String {
            self.currencyCode
        }

        var knownCostProviderCount: Int {
            self.providers.count { $0.totalCost != nil }
        }

        var knownCost: Double? {
            let costs = self.providers.compactMap(\.totalCost)
            guard !costs.isEmpty else { return nil }
            var total = 0.0
            for cost in costs {
                total += cost
                guard total.isFinite else { return nil }
            }
            return total
        }
    }

    let requestedDays: Int
    let groups: [CurrencyGroup]
    let tokenActivity: [TokenActivityPoint]

    static let tokenActivityDayCount = 365

    init(
        requestedDays: Int,
        groups: [CurrencyGroup],
        tokenActivity: [TokenActivityPoint] = [])
    {
        self.requestedDays = requestedDays
        self.groups = groups
        self.tokenActivity = tokenActivity
    }

    static func build(
        inputs: [ProviderInput],
        requestedDays: Int,
        now: Date,
        calendar: Calendar = .current,
        preferredCurrencyCode: String = "auto") -> Self
    {
        let days = max(1, min(365, requestedDays))
        let calculationCalendar = Self.gregorianCalendar(timeZone: calendar.timeZone)
        let classifiedInputs = inputs.compactMap { input -> ClassifiedInput? in
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
                    calendar: calculationCalendar)
            }
            .sorted { $0.currencyCode < $1.currencyCode }
        return Self(
            requestedDays: days,
            groups: groups,
            tokenActivity: Self.tokenActivity(
                inputs: inputs,
                now: now,
                calendar: calculationCalendar))
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

        func tokens(on day: Date) -> Int? {
            guard self.coveredInterval?.contains(day) == true,
                  !self.isGloballyInvalid,
                  !self.invalidDays.contains(day)
            else { return nil }
            if let tokens = self.totalsByDay[day] {
                return tokens
            }
            return self.hasCompleteHistory ? 0 : nil
        }
    }

    private static func buildCurrencyGroup(
        currencyCode: String,
        inputs: [ClassifiedInput],
        days: Int,
        now: Date,
        calendar: Calendar) -> CurrencyGroup
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
        let modelSummaries = summaries.filter { summary in
            guard summary.totalCost != nil else { return false }
            let summaryModelHistory = Self.modelSummary(summaries: [summary])
            return summaryModelHistory.completeness == .complete ||
                Self.canRetainPartialCodexModelHistory(summary) ||
                Self.canRetainTokenOnlyModelHistory(summary)
        }
        // A Codex session can have valid priced rows alongside model-less or unpriced rows.
        // Keep only the directly priced portion, but mark the aggregate partial and remove ranking.
        let modelSummary = Self.modelSummary(summaries: modelSummaries)
        let modelHistoryCompleteness = modelSummaries.count == summaries.count &&
            modelSummary.completeness == .complete
            ? ModelHistoryCompleteness.complete
            : ModelHistoryCompleteness.incomplete
        let dailyPoints = Self.dailyPoints(summaries: summaries)
        return CurrencyGroup(
            currencyCode: currencyCode,
            providers: providers,
            models: modelSummary.rows,
            dailyPoints: dailyPoints,
            totalTokens: Self.completeIntSum(providers.map(\.totalTokens)),
            totalCost: Self.completeCostSum(providers.map(\.totalCost)),
            coveredDayCount: Self.commonCoverageDayCount(summaries: summaries, calendar: calendar),
            chartDomain: Self.chartDomain(bounds: bounds, calendar: calendar),
            modelHistoryCompleteness: modelHistoryCompleteness)
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
        let hasCompleteCostHistory = Self.hasCompleteCostHistory(input, displayCalendar: calendar)
        let costAggregateIsConsistent = input.snapshot.last30DaysCostUSD == nil || hasCompleteCostHistory
        let invalidCostHistory = hasInvalidCostHistory || !costAggregateIsConsistent
        let totalCost = invalidCostHistory
            ? nil
            : entries.isEmpty
            ? (coveredDayCount > 0 && hasCompleteCostHistory ? 0 : nil)
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
                    coveredDayCount: entry.element.coveredDayCount)
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

    private static func hasCompleteCostHistory(
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
            guard let cost = validCost(entry.costUSD) else { return false }
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
            for summary in summaries {
                guard let tokens = summary.tokens(on: day) else {
                    return TokenActivityPoint(day: day, totalTokens: nil)
                }
                let addition = total.addingReportingOverflow(tokens)
                total = addition.overflow ? Int.max : addition.partialValue
            }
            return TokenActivityPoint(day: day, totalTokens: total)
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
        let snapshotDay = bucketCalendar.startOfDay(for: input.snapshot.updatedAt)
        let bucketEnd = input.provider == .openrouter
            ? bucketCalendar.date(byAdding: .day, value: -1, to: snapshotDay) ?? snapshotDay
            : snapshotDay
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
        guard provider == .mistral || provider == .openrouter else { return displayCalendar }
        // Mistral and OpenRouter label daily buckets and snapshot coverage by UTC day. Map each UTC boundary
        // into the containing local dashboard day instead of reinterpreting the label as a local date.
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
}
