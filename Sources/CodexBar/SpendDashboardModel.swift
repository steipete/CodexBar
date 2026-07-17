import CodexBarCore
import Foundation

struct SpendDashboardModel: Equatable, Sendable {
    struct ProviderInput: Sendable {
        let id: String
        let provider: UsageProvider
        let displayName: String
        let modelProviderName: String
        let snapshot: CostUsageTokenSnapshot

        init(
            id: String? = nil,
            provider: UsageProvider,
            displayName: String,
            modelProviderName: String? = nil,
            snapshot: CostUsageTokenSnapshot)
        {
            self.id = id ?? provider.rawValue
            self.provider = provider
            self.displayName = displayName
            self.modelProviderName = modelProviderName ?? displayName
            self.snapshot = snapshot
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
    }

    let requestedDays: Int
    let groups: [CurrencyGroup]

    static func build(
        inputs: [ProviderInput],
        requestedDays: Int,
        now: Date,
        calendar: Calendar = .current) -> Self
    {
        let days = max(1, min(30, requestedDays))
        let calculationCalendar = Self.gregorianCalendar(timeZone: calendar.timeZone)
        let classifiedInputs = inputs.compactMap { input -> (currencyCode: String, input: ProviderInput)? in
            guard let currencyCode = Self.currencyCode(input.snapshot.currencyCode) else { return nil }
            return (currencyCode, input)
        }
        let groups = Dictionary(grouping: classifiedInputs, by: { $0.currencyCode })
            .map { currencyCode, inputs in
                Self.buildCurrencyGroup(
                    currencyCode: currencyCode,
                    inputs: inputs.map(\.input),
                    days: days,
                    now: now,
                    calendar: calculationCalendar)
            }
            .sorted { $0.currencyCode < $1.currencyCode }
        return Self(requestedDays: days, groups: groups)
    }

    private struct InputSummary {
        let input: ProviderInput
        let entries: [WindowEntry]
        let totalTokens: Int?
        let totalCost: Double?
        let coveredInterval: ClosedRange<Date>?
        let coveredDayCount: Int
        let hasInvalidCostHistory: Bool
    }

    private struct WindowEntry {
        let day: Date
        let entry: CostUsageDailyReport.Entry
    }

    private struct ModelKey: Hashable {
        let provider: UsageProvider
        let modelName: String
    }

    private struct ModelAccumulator {
        let providerName: String
        var tokens: Int?
        var cost: Double?
        var sawTokens = false
        var sawCost = false
        var invalidTokens = false
        var invalidCost = false
        var overflowedTokens = false
        var overflowedCost = false
    }

    private struct ModelSummary {
        let rows: [ModelRow]
        let completeness: ModelHistoryCompleteness
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

    private static func buildCurrencyGroup(
        currencyCode: String,
        inputs: [ProviderInput],
        days: Int,
        now: Date,
        calendar: Calendar) -> CurrencyGroup
    {
        let bounds = Self.bounds(days: days, now: now, calendar: calendar)
        let summaries = inputs.map { input in
            Self.inputSummary(input: input, bounds: bounds, calendar: calendar)
        }
        let providers = Self.providerRows(summaries)
        let modelSummary = Self.modelSummary(summaries: summaries)
        let modelHistoryCompleteness = summaries.contains(where: { $0.totalCost == nil })
            ? ModelHistoryCompleteness.incomplete
            : modelSummary.completeness
        let dailyPoints = Self.dailyPoints(summaries: summaries)
        return CurrencyGroup(
            currencyCode: currencyCode,
            providers: providers,
            models: modelHistoryCompleteness == .complete ? modelSummary.rows : [],
            dailyPoints: dailyPoints,
            totalTokens: Self.completeIntSum(providers.map(\.totalTokens)),
            totalCost: Self.completeCostSum(providers.map(\.totalCost)),
            coveredDayCount: Self.commonCoverageDayCount(summaries: summaries, calendar: calendar),
            chartDomain: Self.chartDomain(bounds: bounds, calendar: calendar),
            modelHistoryCompleteness: modelHistoryCompleteness)
    }

    private static func inputSummary(
        input: ProviderInput,
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
            : Self.completeCostSum(entries.map { Self.validCost($0.entry.costUSD) })
        return InputSummary(
            input: input,
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

    private static func modelSummary(summaries: [InputSummary]) -> ModelSummary {
        var aggregates: [ModelKey: ModelAccumulator] = [:]
        var completeness = ModelHistoryCompleteness.complete
        for summary in summaries {
            let input = summary.input
            let hasCompleteTokenHistory = summary.totalTokens != nil && summary.entries.allSatisfy {
                Self.hasCompleteModelTokenCoverage($0.entry)
            }
            for windowEntry in summary.entries {
                let entry = windowEntry.entry
                let breakdowns = entry.modelBreakdowns ?? []
                if !Self.hasCompleteModelCostCoverage(entry) {
                    completeness = .incomplete
                }
                for breakdown in breakdowns {
                    let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !name.isEmpty else { continue }
                    let key = ModelKey(provider: input.provider, modelName: name)
                    var aggregate = aggregates[key] ?? ModelAccumulator(
                        providerName: input.modelProviderName,
                        tokens: 0,
                        cost: 0)
                    if hasCompleteTokenHistory,
                       let tokens = Self.nonnegative(breakdown.totalTokens)
                    {
                        aggregate.sawTokens = true
                        aggregate.tokens = Self.add(
                            tokens,
                            to: aggregate.tokens,
                            overflowed: &aggregate.overflowedTokens)
                    } else {
                        aggregate.invalidTokens = true
                    }
                    if let cost = Self.validCost(breakdown.costUSD) {
                        aggregate.sawCost = true
                        aggregate.cost = Self.add(cost, to: aggregate.cost, overflowed: &aggregate.overflowedCost)
                    } else {
                        aggregate.invalidCost = true
                    }
                    aggregates[key] = aggregate
                }
            }
        }
        if aggregates.values.contains(where: {
            !$0.sawCost || $0.invalidCost || $0.overflowedCost || $0.cost == nil
        }) {
            completeness = .incomplete
        }

        let rows = aggregates.map { key, value in
            ModelRow(
                rank: 0,
                provider: key.provider,
                providerName: value.providerName,
                modelName: key.modelName,
                totalTokens: value.sawTokens && !value.invalidTokens && !value.overflowedTokens ? value.tokens : nil,
                totalCost: value.sawCost && !value.invalidCost && !value.overflowedCost ? value.cost : nil)
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
                return lhs.modelName < rhs.modelName
            }
        }
        .enumerated()
        .map { rank, row in
            ModelRow(
                rank: rank + 1,
                provider: row.provider,
                providerName: row.providerName,
                modelName: row.modelName,
                totalTokens: row.totalTokens,
                totalCost: row.totalCost)
        }
        return ModelSummary(rows: rows, completeness: completeness)
    }

    private static func hasProvenZeroCost(_ entry: CostUsageDailyReport.Entry) -> Bool {
        self.validCost(entry.costUSD) == 0
            && (entry.modelBreakdowns?.allSatisfy(self.hasProvenZeroCost) ?? true)
    }

    private static func hasProvenZeroCost(_ breakdown: CostUsageDailyReport.ModelBreakdown) -> Bool {
        let optionalCosts = [breakdown.standardCostUSD, breakdown.priorityCostUSD]
        return Self.validCost(breakdown.costUSD) == 0
            && optionalCosts.allSatisfy { value in
                value == nil || Self.validCost(value) == 0
            }
    }

    private static func hasProvenZeroTokens(_ entry: CostUsageDailyReport.Entry) -> Bool {
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

    private static func hasProvenZeroTokens(_ breakdown: CostUsageDailyReport.ModelBreakdown) -> Bool {
        let optionalTokens = [breakdown.standardTokens, breakdown.priorityTokens]
        return Self.nonnegative(breakdown.totalTokens) == 0
            && optionalTokens.allSatisfy { $0 == nil || Self.nonnegative($0) == 0 }
    }

    private static func hasCompleteModelCostCoverage(_ entry: CostUsageDailyReport.Entry) -> Bool {
        var totalCost = 0.0
        var sawNamedBreakdown = false
        for breakdown in entry.modelBreakdowns ?? [] {
            let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                guard Self.hasProvenZeroCost(breakdown) else { return false }
                continue
            }
            sawNamedBreakdown = true
            guard let cost = Self.validCost(breakdown.costUSD) else { return false }
            totalCost += cost
            guard totalCost.isFinite else { return false }
        }

        guard sawNamedBreakdown else { return Self.hasProvenZeroCost(entry) }
        guard let entryCost = Self.validCost(entry.costUSD) else { return false }
        return Self.costsMatch(entryCost, totalCost)
    }

    private static func hasCompleteModelTokenCoverage(_ entry: CostUsageDailyReport.Entry) -> Bool {
        var totalTokens = 0
        var sawNamedBreakdown = false
        for breakdown in entry.modelBreakdowns ?? [] {
            let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                guard Self.hasProvenZeroTokens(breakdown) else { return false }
                continue
            }
            sawNamedBreakdown = true
            guard let tokens = Self.nonnegative(breakdown.totalTokens) else { return false }
            let addition = totalTokens.addingReportingOverflow(tokens)
            guard !addition.overflow else { return false }
            totalTokens = addition.partialValue
        }

        guard sawNamedBreakdown else { return Self.hasProvenZeroTokens(entry) }
        guard let entryTokens = Self.nonnegative(entry.totalTokens) else { return false }
        return entryTokens == totalTokens
    }

    private static func costsMatch(_ lhs: Double, _ rhs: Double) -> Bool {
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
                if let cost = Self.validCost(entry.costUSD) {
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

    private static func validCost(_ value: Double?) -> Double? {
        guard let value, value.isFinite, value >= 0 else { return nil }
        return value
    }

    private static func nonnegative(_ value: Int?) -> Int? {
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

    private static func add(_ value: Int, to current: Int?, overflowed: inout Bool) -> Int? {
        guard !overflowed, let current else { return nil }
        let addition = current.addingReportingOverflow(value)
        if addition.overflow {
            overflowed = true
            return nil
        }
        return addition.partialValue
    }

    private static func add(_ value: Double, to current: Double?, overflowed: inout Bool) -> Double? {
        guard !overflowed, let current else { return nil }
        let result = current + value
        guard result.isFinite else {
            overflowed = true
            return nil
        }
        return result
    }
}
