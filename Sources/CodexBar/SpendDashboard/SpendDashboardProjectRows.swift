import CodexBarCore
import Foundation

extension SpendDashboardModel {
    /// Rolls per-project daily entries up to window-scoped rows, mirroring the proven-zero
    /// discipline of provider totals: only days inside the window and the source's established
    /// coverage interval count, and one unknown day makes that project's aggregate unknown.
    /// Projects with no attributable day in the window are dropped rather than shown as zero.
    static func projectRows(
        summaries: [InputSummary],
        bounds: ClosedRange<Date>,
        calendar: Calendar) -> [ProjectRow]
    {
        struct Key: Hashable {
            let sourceID: String
            let identity: String
        }

        struct Accumulator {
            var name: String
            let provider: UsageProvider
            let providerName: String
            let path: String?
            var isProjectless: Bool
            var tokens: Int?
            var cost: Double?
            var sawTokens = false
            var sawCost = false
            var invalidTokens = false
            var invalidCost = false
            var overflowedTokens = false
            var overflowedCost = false
            var costIsLowerBound = false
            var tokensAreLowerBound = false
        }

        var aggregates: [Key: Accumulator] = [:]
        for summary in summaries {
            let input = summary.input
            for project in input.snapshot.projects {
                let name = project.name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !name.isEmpty else { continue }
                let key = Key(sourceID: input.id, identity: project.path.map { "path:\($0)" } ?? "name:\(name)")
                var aggregate = aggregates[key] ?? Accumulator(
                    name: name,
                    provider: input.provider,
                    providerName: input.modelProviderName,
                    path: project.path,
                    isProjectless: project.isProjectless,
                    tokens: 0,
                    cost: 0)
                // An identical ledger path is an independent chat only when every record agrees.
                if aggregate.isProjectless, !project.isProjectless {
                    aggregate.name = name
                }
                aggregate.isProjectless = aggregate.isProjectless && project.isProjectless
                if summary.historyScanIsPartial {
                    aggregate.costIsLowerBound = true
                    aggregate.tokensAreLowerBound = true
                }
                for entry in project.daily {
                    guard let day = Self.day(entry.date, provider: input.provider, displayCalendar: calendar),
                          bounds.contains(day),
                          summary.coveredInterval?.contains(day) == true
                    else { continue }
                    if entry.incompleteRequestCount > 0 {
                        aggregate.costIsLowerBound = true
                        aggregate.tokensAreLowerBound = true
                    }
                    if (entry.unpricedRequestCount ?? 0) > 0 {
                        aggregate.costIsLowerBound = true
                    }
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
                    projectName: value.name,
                    path: value.path,
                    totalTokens: value.sawTokens && !value.invalidTokens && !value.overflowedTokens
                        ? value.tokens
                        : nil,
                    totalCost: value.sawCost && !value.invalidCost && !value.overflowedCost
                        ? value.cost
                        : nil,
                    isProjectless: value.isProjectless,
                    costIsLowerBound: value.costIsLowerBound,
                    tokensAreLowerBound: value.tokensAreLowerBound)
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
                    if lhs.projectName != rhs.projectName {
                        return lhs.projectName < rhs.projectName
                    }
                    return lhs.id < rhs.id
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
                    totalCost: row.totalCost,
                    isProjectless: row.isProjectless,
                    costIsLowerBound: row.costIsLowerBound,
                    tokensAreLowerBound: row.tokensAreLowerBound)
            }
    }
}
