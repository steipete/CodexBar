import CodexBarCore
import SwiftUI

/// Cross-provider model ranking for one currency group, with each model's share of the whole.
///
/// Shares always divide by every model in the group, never by the visible rows, so collapsing the
/// list cannot inflate a percentage. Spend is the basis only when every model is priced: one
/// unpriced model would make a cost share claim more than it knows, so the ranking falls back to
/// tracked tokens and says so in its column header. Tokens only compare within one provider, whose
/// models share a tokenizer family; a mixed-provider group without full pricing gets no shares. When
/// neither metric covers every model, the
/// rows keep the group's order and their own values, without shares, rather than hiding history.
/// When some of the group's usage has no model attribution, the named models are only part of the
/// whole, so rows keep their order and values but carry no shares, and the view marks them partial.
struct SpendModelRanking: Equatable {
    enum Basis: Equatable {
        case cost
        case tokens
    }

    struct Row: Identifiable, Equatable {
        let model: SpendDashboardModel.ModelRow
        let value: Double
        let share: Double?

        var id: String {
            self.model.id
        }
    }

    /// `nil` when no metric covers every model; rows are then listed without shares.
    let basis: Basis?
    let rows: [Row]
    var isPartial = false

    static let collapsedRowCount = 5

    /// Short lists show every row; a "Show all" control that reveals one more row is noise.
    static func visibleRowCount(total: Int, showsAll: Bool) -> Int {
        showsAll || total <= self.collapsedRowCount + 1 ? total : self.collapsedRowCount
    }

    static func make(_ group: SpendDashboardModel.CurrencyGroup) -> SpendModelRanking? {
        guard let ranking = self.make(group.models) else { return nil }
        let completeness = ranking.basis == .tokens
            ? group.modelTokenAttributionCompleteness
            : group.modelHistoryCompleteness
        guard completeness == .incomplete else { return ranking }
        return SpendModelRanking(
            basis: ranking.basis,
            rows: ranking.rows.map { Row(model: $0.model, value: $0.value, share: nil) },
            isPartial: true)
    }

    static func make(_ models: [SpendDashboardModel.ModelRow]) -> SpendModelRanking? {
        guard !models.isEmpty else { return nil }
        let costs = models.compactMap { $0.totalCost.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        if costs.count == models.count, let ranking = Self.rank(models, basis: .cost, value: { $0.totalCost }) {
            return ranking
        }
        if Set(models.map(\.provider)).count == 1,
           let ranking = Self.rank(models, basis: .tokens, value: { $0.totalTokens.map(Double.init) })
        {
            return ranking
        }
        return SpendModelRanking(basis: nil, rows: models.map { Row(model: $0, value: 0, share: nil) })
    }

    private static func rank(
        _ models: [SpendDashboardModel.ModelRow],
        basis: Basis,
        value: (SpendDashboardModel.ModelRow) -> Double?) -> SpendModelRanking?
    {
        let values = models.map { value($0).flatMap { $0.isFinite && $0 >= 0 ? $0 : nil } }
        guard !values.contains(where: { $0 == nil }) else { return nil }
        let total = values.reduce(0) { $0 + ($1 ?? 0) }
        guard total > 0, total.isFinite else { return nil }
        let rows = zip(models, values).map { model, value in
            Row(model: model, value: value ?? 0, share: (value ?? 0) / total)
        }
        .enumerated()
        .sorted { lhs, rhs in
            lhs.element.value == rhs.element.value ? lhs.offset < rhs.offset : lhs.element.value > rhs.element.value
        }
        .map(\.element)
        return SpendModelRanking(basis: basis, rows: rows)
    }
}

func spendDashboardShareText(_ share: Double) -> String {
    let style = FloatingPointFormatStyle<Double>.Percent()
        .precision(.fractionLength(share > 0 && share < 0.01 ? 1 : 0))
        .locale(codexBarLocalizedResourceLocale())
    return share.formatted(style)
}

struct SpendModelRankingRows: View {
    let group: SpendDashboardModel.CurrencyGroup
    @State private var showsAllRows = false

    var body: some View {
        if let ranking = SpendModelRanking.make(self.group) {
            VStack(alignment: .leading, spacing: 0) {
                if ranking.basis != nil || ranking.isPartial {
                    HStack {
                        if ranking.isPartial {
                            Label(L("Partial model breakdown"), systemImage: "exclamationmark.triangle")
                        }
                        Spacer()
                        if let basis = ranking.basis {
                            Text(basis == .cost ? L("Estimated spend") : L("Tracked tokens"))
                        }
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)
                }
                let visibleCount = SpendModelRanking.visibleRowCount(
                    total: ranking.rows.count,
                    showsAll: self.showsAllRows)
                ForEach(Array(ranking.rows.prefix(visibleCount).enumerated()), id: \.element.id) { index, row in
                    if index > 0 {
                        Divider()
                    }
                    SpendModelRankingRow(row: row, basis: ranking.basis, currencyCode: self.group.currencyCode)
                }
                if ranking.rows.count > visibleCount || self.showsAllRows {
                    SpendPanelExpandButton(
                        rowCount: ranking.rows.count,
                        collapsedRowCount: SpendModelRanking.collapsedRowCount,
                        showsAllRows: self.$showsAllRows)
                }
            }
        } else {
            Text(L("No model-level history"))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SpendModelRankingRow: View {
    let row: SpendModelRanking.Row
    let basis: SpendModelRanking.Basis?
    let currencyCode: String

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            ProviderMarkChip(provider: self.row.model.provider)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(self.row.model.modelName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(self.row.model.modelName)
                    Text(self.row.model.providerName)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    if let share = self.row.share {
                        Text(spendDashboardShareText(share))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Text(self.valueText)
                        .frame(minWidth: 76, alignment: .trailing)
                }
                if let share = self.row.share {
                    SpendShareBar(share: share, color: Color.primary.opacity(0.8))
                }
            }
        }
        .monospacedDigit()
        .padding(.vertical, 7)
        .accessibilityElement(children: .combine)
    }

    private var valueText: String {
        let isLowerBound = self.row.model.incompleteRequestCount > 0
        let text = switch self.basis {
        case .cost: UsageFormatter.currencyString(self.row.value, currencyCode: self.currencyCode)
        // Format the original count: a ranking value near Int.max does not round-trip through Double.
        case .tokens: self.row.model.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
        case nil:
            // Unranked rows show whatever each model has, like the provider breakdown does.
            spendDashboardMetricText(
                cost: self.row.model.totalCost,
                tokens: self.row.model.totalTokens,
                currencyCode: self.currencyCode,
                incompleteRequestCount: self.row.model.incompleteRequestCount)
        }
        return self.basis == nil ? text : spendDashboardLowerBoundText(text, isLowerBound: isLowerBound)
    }
}

private struct SpendShareBar: View {
    let share: Double
    let color: Color

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(self.color)
                    .frame(width: max(proxy.size.width * min(max(self.share, 0), 1), self.share > 0 ? 3 : 0))
            }
        }
        .frame(height: 4)
        .accessibilityHidden(true)
    }
}
