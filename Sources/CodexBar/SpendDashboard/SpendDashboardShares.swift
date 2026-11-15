import CodexBarCore
import SwiftUI

/// Each row's share of one collection, and the metric those shares measure.
struct SpendDashboardShares<ID: Hashable>: Equatable {
    let basis: SpendModelRanking.Basis
    let values: [ID: Double]

    var basisTitle: String {
        self.basis == .cost ? L("Estimated spend") : L("Tracked tokens")
    }
}

/// A collection uses one complete metric so every bar has the same denominator.
/// Unknown, partial, or overflowing totals cannot establish a share. Tokens only compare within one
/// provider, whose rows share a tokenizer family, matching `SpendModelRanking`; a mixed-provider
/// collection without complete spend gets no shares.
func spendDashboardShares<Row: Identifiable>(
    _ rows: [Row],
    cost: KeyPath<Row, Double?>,
    tokens: KeyPath<Row, Int?>,
    provider: KeyPath<Row, UsageProvider>) -> SpendDashboardShares<Row.ID>?
{
    let costs = rows.compactMap { SpendDashboardModel.validCost($0[keyPath: cost]) }
    if costs.count == rows.count {
        guard let total = SpendDashboardModel.safeCostSum(costs), total > 0 else { return nil }
        return SpendDashboardShares(
            basis: .cost,
            values: Dictionary(uniqueKeysWithValues: zip(rows, costs).map { row, value in
                (row.id, value / total)
            }))
    }

    guard Set(rows.map { $0[keyPath: provider] }).count == 1 else { return nil }
    let counts = rows.compactMap { $0[keyPath: tokens] }.filter { $0 >= 0 }
    guard counts.count == rows.count,
          let total = CheckedSum.integers(counts), total > 0
    else { return nil }
    return SpendDashboardShares(
        basis: .tokens,
        values: Dictionary(uniqueKeysWithValues: zip(rows, counts).map { row, value in
            (row.id, Double(value) / Double(total))
        }))
}

extension SpendDashboardModel.ProjectRow {
    /// A floor total would understate this project's share, so it cannot set a denominator.
    var completeCost: Double? {
        self.costIsLowerBound ? nil : self.totalCost
    }

    var completeTokens: Int? {
        self.tokensAreLowerBound ? nil : self.totalTokens
    }
}

func spendDashboardProjectShares(_ rows: [SpendDashboardModel.ProjectRow]) -> SpendDashboardShares<String>? {
    spendDashboardShares(rows, cost: \.completeCost, tokens: \.completeTokens, provider: \.provider)
}

/// Names the metric a collection's share bars measure, like the Models list's column header.
struct SpendShareBasisHeader: View {
    let title: String

    var body: some View {
        HStack {
            Spacer()
            Text(self.title)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.bottom, 2)
    }
}
