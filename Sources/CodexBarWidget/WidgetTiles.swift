import CodexBarCore
import SwiftUI

/// The three macOS tile shapes, decoupled from `WidgetFamily` so layouts can be rendered and
/// reasoned about outside a widget host.
enum WidgetTileSize {
    case small
    case medium
    case large

    var heroNumberSize: CGFloat {
        switch self {
        case .small: 30
        case .medium: 34
        case .large: 42
        }
    }

    var markSize: CGFloat {
        self == .small ? WidgetLayout.markSizeSmall : WidgetLayout.markSizeRegular
    }

    /// How many lanes fit below the headline before the tile starts clipping.
    ///
    /// A cost block costs about one lane of height and the history chart about two, so the budget
    /// has to know what else the tile is drawing — a fixed cap either clips a busy provider or
    /// pages a sparse one for no reason.
    func secondaryLaneCapacity(hasMetrics: Bool, hasChart: Bool) -> Int {
        switch self {
        case .small:
            return 2
        case .medium:
            return hasMetrics ? 2 : 3
        case .large:
            var capacity = 6
            if hasChart { capacity -= 2 }
            if hasMetrics { capacity -= 2 }
            return max(1, capacity)
        }
    }

    /// Small tiles list the remaining lanes as figures only: at 127pt of usable height a 7pt bar
    /// costs as much room as the number it duplicates.
    var showsSecondaryBars: Bool {
        self != .small
    }

    /// Large tiles carry the history chart, but only while the quota lanes leave it enough room to
    /// be a chart: squeezed to a few points it is noise, and the dedicated History widget covers
    /// providers with more lanes than that.
    func showsChart(laneCount: Int, hasHistory: Bool) -> Bool {
        self == .large && hasHistory && laneCount <= 3
    }

    var laneSpacing: CGFloat {
        self == .small ? 5 : WidgetLayout.laneSpacing
    }
}

// MARK: - Tile

/// Shared body for the usage and switcher widgets across all three families.
///
/// One layout means the two widgets cannot drift apart, and every size difference is a value in
/// `WidgetTileSize` rather than a separate near-duplicate view.
struct UsageTile<Header: View>: View {
    @Environment(\.widgetUsageShowsUsed) private var showsUsed
    let entry: WidgetSnapshot.ProviderEntry
    let size: WidgetTileSize
    @ViewBuilder let header: () -> Header

    var body: some View {
        let color = WidgetColors.color(for: self.entry.provider)
        // The provider's compact row cap curates what a tile may LIST; it must not decide which
        // lane is binding. Headline and overflow are computed against the full set.
        let allLanes = WidgetTileLane.lanes(for: self.entry)
        let displayLanes = self.laneLimit == nil
            ? allLanes
            : WidgetTileLane.lanes(for: self.entry, limit: self.laneLimit)
        let hasChart = self.size.showsChart(
            laneCount: allLanes.count,
            hasHistory: !self.entry.dailyUsage.isEmpty)
        let fallback = allLanes.isEmpty ? WidgetFallbackHero.make(for: self.entry) : nil
        let metrics = WidgetMetricRows.rows(
            for: self.entry,
            size: self.size,
            secondaryLaneCount: max(0, allLanes.count - 1),
            excluding: fallback?.consumedMetricID)
        let plan = WidgetTilePlan.make(
            lanes: allLanes,
            displayCandidates: displayLanes,
            maxSecondaryLanes: self.size.secondaryLaneCapacity(
                hasMetrics: !metrics.isEmpty,
                hasChart: hasChart),
            reservesOverflowRow: self.size != .large)

        VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
            self.header()
            // Medium splits into columns only when there are lanes to fill the right one. A
            // single-lane provider in two columns leaves a void beside the headline; down one
            // column it gets the full width for its bar instead.
            if self.size == .medium, !plan.lanes.isEmpty {
                HStack(alignment: .top, spacing: 14) {
                    self.hero(plan: plan, fallback: fallback, color: color, spreads: !metrics.isEmpty)
                        .frame(width: 104, alignment: .leading)
                    VStack(alignment: .leading, spacing: WidgetLayout.laneSpacing) {
                        self.lanes(plan: plan, color: color)
                        if !metrics.isEmpty {
                            Spacer(minLength: 2)
                            self.metrics(metrics)
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }
                .frame(maxHeight: .infinity)
            } else {
                self.hero(plan: plan, fallback: fallback, color: color, spreads: false)
                VStack(alignment: .leading, spacing: self.size.laneSpacing) {
                    self.lanes(plan: plan, color: color)
                }
                self.metrics(metrics)
                if hasChart {
                    UsageHistoryChart(
                        points: self.entry.dailyUsage,
                        color: color,
                        currencyCode: self.entry.tokenUsage?.currencyCode)
                        .frame(minHeight: 66, maxHeight: .infinity)
                } else {
                    Spacer(minLength: 0)
                }
            }
        }
        .padding(WidgetLayout.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    /// Providers cap how many lanes a compact tile may show; large tiles take everything and page
    /// the excess behind a "+N more" line.
    private var laneLimit: Int? {
        switch self.size {
        case .small: WidgetUsageRow.smallWidgetRowLimit(for: self.entry)
        case .medium: WidgetUsageRow.mediumWidgetRowLimit(for: self.entry)
        case .large: nil
        }
    }

    // MARK: Headline

    @ViewBuilder
    private func hero(
        plan: WidgetTilePlan,
        fallback: WidgetFallbackHeroContent?,
        color: Color,
        spreads: Bool) -> some View
    {
        if let lane = plan.hero {
            let displayed = WidgetUsageDisplay.percent(
                fromRemaining: lane.remainingPercent,
                showUsed: self.showsUsed)
            HeroBlock(
                value: WidgetFormat.percent(displayed),
                caption: WidgetLaneCopy.caption(title: lane.title, showUsed: self.showsUsed),
                detail: WidgetLaneCopy.resetText(
                    resetsAt: lane.resetsAt,
                    resetDescription: lane.resetDescription),
                barPercent: displayed ?? 0,
                isLow: QuotaSeverity.isLow(remaining: lane.remainingPercent),
                color: color,
                numberSize: self.size.heroNumberSize,
                spreads: spreads)
        } else if let fallback {
            HeroBlock(
                value: fallback.value,
                caption: fallback.caption,
                detail: fallback.detail,
                numberSize: self.size.heroNumberSize)
        }
    }

    // MARK: Lanes

    @ViewBuilder
    private func lanes(plan: WidgetTilePlan, color: Color) -> some View {
        ForEach(plan.lanes) { lane in
            QuotaLaneView(
                title: lane.title,
                percent: WidgetUsageDisplay.percent(
                    fromRemaining: lane.remainingPercent,
                    showUsed: self.showsUsed),
                remainingPercent: lane.remainingPercent,
                color: color,
                showsBar: self.size.showsSecondaryBars)
        }
        if plan.overflowCount > 0 {
            Text("+\(plan.overflowCount) more")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: Cost and credit rows

    @ViewBuilder
    private func metrics(_ lines: [WidgetMetricRow]) -> some View {
        if !lines.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if self.size != .small {
                    WidgetSeparator().padding(.bottom, 2)
                }
                ForEach(lines) { line in
                    MetricLine(title: line.title, value: line.value, isProminent: line.isProminent)
                }
            }
        }
    }
}

// MARK: - Metric rows

struct WidgetMetricRow: Identifiable, Equatable {
    let id: String
    let title: String
    let value: String
    var isProminent: Bool = false
}

enum WidgetMetricRows {
    /// Cost, credit and balance lines, trimmed to what each tile can show without clipping.
    static func rows(
        for entry: WidgetSnapshot.ProviderEntry,
        size: WidgetTileSize,
        secondaryLaneCount: Int = 0,
        excluding excludedID: String? = nil) -> [WidgetMetricRow]
    {
        let rows = self.allRows(for: entry, size: size, secondaryLaneCount: secondaryLaneCount)
            .filter { $0.id != excludedID }
        return Array(rows.prefix(self.rowCapacity(for: size)))
    }

    /// Hard ceiling per tile so an unusual provider (credits *and* costs *and* a balance) cannot
    /// push the lanes off the tile.
    private static func rowCapacity(for size: WidgetTileSize) -> Int {
        switch size {
        case .small: 1
        case .medium: 2
        case .large: 3
        }
    }

    private static func allRows(
        for entry: WidgetSnapshot.ProviderEntry,
        size: WidgetTileSize,
        secondaryLaneCount: Int) -> [WidgetMetricRow]
    {
        var rows: [WidgetMetricRow] = []
        if size == .small {
            // A small tile spends its height on quota lanes. With none below the headline the room
            // is there, so a single-lane provider gets its cost line instead of empty space.
            guard secondaryLaneCount == 0,
                  let token = entry.tokenUsage ?? WidgetUsageRow.compactTokenUsage(for: entry)
            else {
                return self.balanceRows(for: entry)
            }
            rows.append(self.sessionRow(token: token, entry: entry, isProminent: true, compact: true))
            return rows + self.balanceRows(for: entry)
        }

        if let credits = entry.creditsRemaining {
            rows.append(WidgetMetricRow(id: "credits", title: "Credits", value: WidgetFormat.credits(credits)))
        }
        if let token = entry.tokenUsage {
            rows.append(self.sessionRow(token: token, entry: entry, isProminent: true))
            if size == .large {
                rows.append(WidgetMetricRow(
                    id: "last30",
                    title: WidgetFormat.tokenRowTitle(
                        token.last30DaysLabel,
                        summary: token,
                        entryUpdatedAt: entry.updatedAt),
                    value: WidgetFormat.costAndTokens(
                        cost: token.last30DaysCostUSD,
                        tokens: token.last30DaysTokens,
                        currencyCode: token.currencyCode)))
            }
        }
        return rows + self.balanceRows(for: entry)
    }

    private static func sessionRow(
        token: WidgetSnapshot.TokenUsageSummary,
        entry: WidgetSnapshot.ProviderEntry,
        isProminent: Bool,
        compact: Bool = false) -> WidgetMetricRow
    {
        // "$1.56 · 1.1M tokens" does not fit beside its label on a 127pt tile — the label loses and
        // renders as "T…". Small tiles carry the money only.
        let value = compact
            ? (token.sessionCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) }
                ?? WidgetFormat.unavailable)
            : WidgetFormat.costAndTokens(
                cost: token.sessionCostUSD,
                tokens: token.sessionTokens,
                currencyCode: token.currencyCode)
        return WidgetMetricRow(
            id: "session-cost",
            title: WidgetFormat.tokenRowTitle(
                token.sessionLabel,
                summary: token,
                entryUpdatedAt: entry.updatedAt),
            value: value,
            isProminent: isProminent)
    }

    private static func balanceRows(for entry: WidgetSnapshot.ProviderEntry) -> [WidgetMetricRow] {
        guard let balance = WidgetBalanceFormatter.extraUsageBalance(for: entry) else { return [] }
        return [WidgetMetricRow(id: "extra-usage", title: balance.title, value: balance.value)]
    }
}

// MARK: - Headline fallback

struct WidgetFallbackHeroContent: Equatable {
    let value: String
    let caption: String
    let detail: String?
    /// The metric row this headline was built from. The tile drops it from the list below so the
    /// same figure is not printed twice.
    let consumedMetricID: String
}

enum WidgetFallbackHero {
    /// Balance-only and credit-only providers report no quota lanes, so the headline falls back to
    /// the figure those tiles do have instead of leaving the tile blank.
    static func make(for entry: WidgetSnapshot.ProviderEntry) -> WidgetFallbackHeroContent? {
        if let cost = WidgetBalanceFormatter.extraUsageCost(for: entry) {
            return WidgetFallbackHeroContent(
                value: WidgetFormat.currency(cost.used, code: cost.currencyCode),
                caption: "Extra usage balance",
                detail: nil,
                consumedMetricID: "extra-usage")
        }
        if let credits = entry.creditsRemaining {
            return WidgetFallbackHeroContent(
                value: WidgetFormat.credits(credits),
                caption: "Credits left",
                detail: nil,
                consumedMetricID: "credits")
        }
        guard let token = entry.tokenUsage, let cost = token.sessionCostUSD else { return nil }
        return WidgetFallbackHeroContent(
            value: WidgetFormat.currency(cost, code: token.currencyCode),
            caption: token.sessionLabel,
            detail: token.sessionTokens.map(WidgetFormat.tokenCount),
            consumedMetricID: "session-cost")
    }
}
