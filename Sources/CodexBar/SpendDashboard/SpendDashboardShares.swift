import CodexBarCore

/// A collection uses one complete metric so every bar has the same denominator.
/// Unknown or overflowing totals cannot establish a share.
func spendDashboardShares<Row: Identifiable>(
    _ rows: [Row],
    cost: KeyPath<Row, Double?>,
    tokens: KeyPath<Row, Int?>) -> [Row.ID: Double]
{
    let costs = rows.compactMap { SpendDashboardModel.validCost($0[keyPath: cost]) }
    if costs.count == rows.count {
        guard let total = SpendDashboardModel.safeCostSum(costs), total > 0 else { return [:] }
        return Dictionary(uniqueKeysWithValues: zip(rows, costs).map { row, value in
            (row.id, value / total)
        })
    }

    let counts = rows.compactMap { $0[keyPath: tokens] }.filter { $0 >= 0 }
    guard counts.count == rows.count,
          let total = CheckedSum.integers(counts), total > 0
    else { return [:] }
    return Dictionary(uniqueKeysWithValues: zip(rows, counts).map { row, value in
        (row.id, Double(value) / Double(total))
    })
}
