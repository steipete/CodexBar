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
        var mix = CostUsageTokenMix()
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
                    aggregate.mix.merge(CostUsageTokenMix(
                        inputTokens: breakdown.inputTokens,
                        outputTokens: breakdown.outputTokens,
                        cacheReadTokens: breakdown.cacheReadTokens,
                        cacheCreationTokens: breakdown.cacheCreationTokens,
                        reasoningTokens: breakdown.reasoningTokens))
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
                totalCost: value.sawCost && !value.invalidCost && !value.overflowedCost ? value.cost : nil,
                tokenMix: value.mix)
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
                totalCost: row.totalCost,
                tokenMix: row.tokenMix)
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

    /// Unpriced named models still belong in the breakdown list. Malformed costs and model-less
    /// gaps stay fail-closed so the list cannot present a lower bound as if it were complete.
    static func canRetainUnpricedModelHistory(_ summary: InputSummary) -> Bool {
        guard summary.totalCost == nil else { return false }
        return summary.entries.contains(where: { Self.hasRetainableUnpricedModelRows($0.entry) })
            && summary.entries.allSatisfy { windowEntry in
                let entry = windowEntry.entry
                return Self.hasRetainableUnpricedModelRows(entry) ||
                    Self.hasCompleteModelCostCoverage(entry) ||
                    Self.hasProvenZeroCost(entry)
            }
    }

    private static func hasRetainableUnpricedModelRows(_ entry: CostUsageDailyReport.Entry) -> Bool {
        guard let breakdowns = entry.modelBreakdowns, !breakdowns.isEmpty else { return false }
        var sawNamedUnpriced = false
        for breakdown in breakdowns {
            let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                guard Self.hasProvenZeroCost(breakdown) else { return false }
                continue
            }
            if Self.validCost(breakdown.costUSD) != nil {
                continue
            }
            guard breakdown.costUSD == nil,
                  Self.nonnegative(breakdown.totalTokens) != nil
            else {
                return false
            }
            sawNamedUnpriced = true
        }
        return sawNamedUnpriced
    }

    private static func hasRetainablePartialCodexModelCostCoverage(
        _ entry: CostUsageDailyReport.Entry) -> Bool
    {
        // A model-less day can still have a trustworthy aggregate cost. There is no model row
        // to retain, but allowing it preserves priced rows from other days in the same source.
        guard entry.modelBreakdowns?.isEmpty == false else {
            return self.validCost(entry.costUSD) != nil
        }

        guard let entryCost = validCost(entry.costUSD) else {
            return self.hasExplicitlyUnpriceableCodexCost(entry)
        }
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

    static func hasExplicitlyUnpriceableCodexCost(_ entry: CostUsageDailyReport.Entry) -> Bool {
        guard entry.costUSD == nil,
              let breakdowns = entry.modelBreakdowns,
              !breakdowns.isEmpty
        else { return false }

        return breakdowns.allSatisfy { breakdown in
            !breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && breakdown.costUSD == nil
                && Self.nonnegative(breakdown.totalTokens) != nil
        }
    }

    /// Provider-specific by design: Cursor usage events can omit totalCents without voiding priced rows.
    static func hasExplicitlyUnpriceableLedgerCost(
        _ provider: UsageProvider,
        _ entry: CostUsageDailyReport.Entry) -> Bool
    {
        switch provider {
        case .codex, .cursor:
            self.hasExplicitlyUnpriceableCodexCost(entry)
        default:
            false
        }
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
        var sawBreakdownTokens = false
        var missingBreakdownTokens = false
        for breakdown in entry.modelBreakdowns ?? [] {
            let name = breakdown.modelName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty else {
                guard Self.hasProvenZeroTokens(breakdown) else { return false }
                continue
            }
            sawNamedBreakdown = true
            guard let tokens = Self.nonnegative(breakdown.totalTokens) else {
                if breakdown.totalTokens != nil {
                    return false
                }
                missingBreakdownTokens = true
                continue
            }
            sawBreakdownTokens = true
            let addition = totalTokens.addingReportingOverflow(tokens)
            guard !addition.overflow else { return false }
            totalTokens = addition.partialValue
        }

        guard sawNamedBreakdown else { return Self.hasProvenZeroTokens(entry) }
        guard let entryTokens = Self.nonnegative(entry.totalTokens) else { return sawBreakdownTokens }
        if missingBreakdownTokens {
            return totalTokens <= entryTokens
        }
        return entryTokens == totalTokens
    }
}
