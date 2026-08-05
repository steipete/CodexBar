import CodexBarCore
import Foundation

/// Per-model breakdown aggregation and the completeness policy that decides whether
/// model rows are trustworthy enough to display, rank, or retain as a partial view.
extension SpendDashboardModel {
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

    struct ModelSummary {
        let rows: [ModelRow]
        let completeness: ModelHistoryCompleteness
    }

    static func modelSummary(summaries: [InputSummary]) -> ModelSummary {
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
                    if let cost = Self.validCost(breakdown.costUSD).map({ $0 * summary.costMultiplier }) {
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

    static func canRetainPartialCodexModelHistory(_ summary: InputSummary) -> Bool {
        guard summary.input.provider == .codex else { return false }
        return summary.entries.allSatisfy { windowEntry in
            let entry = windowEntry.entry
            return Self.hasCompleteModelCostCoverage(entry) ||
                Self.hasRetainablePartialCodexModelCostCoverage(entry)
        }
    }

    static func canRetainTokenOnlyModelHistory(_ summary: InputSummary) -> Bool {
        var sawTokenOnlyModel = false
        for windowEntry in summary.entries {
            let entry = windowEntry.entry
            guard self.validCost(entry.costUSD) != nil else { return false }
            guard entry.modelBreakdowns?.isEmpty == false else {
                continue
            }
            guard self.hasCompleteModelTokenCoverage(entry),
                  entry.modelBreakdowns?.allSatisfy({ breakdown in
                      !breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                          && breakdown.costUSD == nil
                  }) == true
            else {
                return false
            }
            sawTokenOnlyModel = true
        }
        return sawTokenOnlyModel
    }

    private static func hasRetainablePartialCodexModelCostCoverage(
        _ entry: CostUsageDailyReport.Entry) -> Bool
    {
        // A model-less day can still have a trustworthy aggregate cost. There is no model row
        // to retain, but allowing it preserves priced rows from other days in the same source.
        guard entry.modelBreakdowns?.isEmpty == false else {
            return self.validCost(entry.costUSD) != nil
        }

        guard let entryCost = validCost(entry.costUSD) else { return false }
        var pricedCost = 0.0
        var sawPricedBreakdown = false
        for breakdown in entry.modelBreakdowns ?? [] {
            let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                guard Self.hasProvenZeroCost(breakdown) else { return false }
                continue
            }
            if let cost = Self.validCost(breakdown.costUSD) {
                pricedCost += cost
                guard pricedCost.isFinite else { return false }
                sawPricedBreakdown = true
            } else {
                // Only an absent cost is an unpriced routing row. A present but malformed
                // cost must fail closed instead of being silently treated as unpriced.
                guard breakdown.costUSD == nil,
                      Self.nonnegative(breakdown.totalTokens) != nil
                else {
                    return false
                }
            }
        }
        return sawPricedBreakdown && Self.costsMatch(entryCost, pricedCost)
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
}
