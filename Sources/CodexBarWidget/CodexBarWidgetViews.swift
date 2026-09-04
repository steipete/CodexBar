import CodexBarCore
import SwiftUI
import WidgetKit

extension WidgetTileSize {
    init(family: WidgetFamily) {
        switch family {
        case .systemSmall: self = .small
        case .systemMedium: self = .medium
        default: self = .large
        }
    }
}

struct CodexBarUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarWidgetEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                UsageTile(entry: providerEntry, size: WidgetTileSize(family: self.family)) {
                    TileHeader(
                        provider: providerEntry.provider,
                        updatedAt: providerEntry.updatedAt,
                        size: WidgetTileSize(family: self.family))
                }
            } else {
                WidgetEmptyState(message: "Usage data will appear once the app refreshes.")
                    .padding(WidgetLayout.tilePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }
}

struct CodexBarHistoryWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarWidgetEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                HistoryView(entry: providerEntry, isLarge: self.family == .systemLarge)
            } else {
                WidgetEmptyState(message: "Usage history will appear after a refresh.")
                    .padding(WidgetLayout.tilePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct CodexBarCompactWidgetView: View {
    let entry: CodexBarCompactEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                CompactMetricView(entry: providerEntry, metric: self.entry.metric)
            } else {
                WidgetEmptyState(message: "Usage data will appear once the app refreshes.")
                    .padding(WidgetLayout.tilePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }
}

struct CodexBarSwitcherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarSwitcherEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        let size = WidgetTileSize(family: self.family)
        Group {
            if let providerEntry {
                UsageTile(entry: providerEntry, size: size) {
                    ProviderPagerHeader(
                        providers: self.entry.availableProviders,
                        selected: self.entry.provider,
                        updatedAt: providerEntry.updatedAt,
                        size: size)
                }
            } else {
                VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
                    ProviderPagerHeader(
                        providers: self.entry.availableProviders,
                        selected: self.entry.provider,
                        updatedAt: Date(),
                        size: size)
                    WidgetEmptyState(message: "Usage data appears after a refresh.")
                }
                .padding(WidgetLayout.tilePadding)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }
}

private struct CompactMetricView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let metric: CompactMetric

    var body: some View {
        let display = CompactMetricFormatter.display(for: self.entry, metric: self.metric)
        VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
            TileHeader(provider: self.entry.provider, updatedAt: self.entry.updatedAt, size: .small)
            Spacer(minLength: 0)
            // This tile carries a single figure, so it gets the full width and sits centred rather
            // than clinging to the header with dead space underneath.
            HeroBlock(
                value: display.value,
                caption: display.label,
                detail: display.detail,
                numberSize: WidgetLayout.compactMetricNumberSize)
            Spacer(minLength: 0)
        }
        .padding(WidgetLayout.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

struct CompactMetricDisplay: Equatable {
    let value: String
    let label: String
    let detail: String?
}

enum CompactMetricFormatter {
    static func display(for entry: WidgetSnapshot.ProviderEntry, metric: CompactMetric) -> CompactMetricDisplay {
        switch metric {
        case .credits:
            if let cost = WidgetBalanceFormatter.extraUsageCost(for: entry) {
                return CompactMetricDisplay(
                    value: WidgetFormat.currency(cost.used, code: cost.currencyCode),
                    label: "Extra usage balance",
                    detail: nil)
            }
            let value = entry.creditsRemaining.map(WidgetFormat.credits) ?? WidgetFormat.unavailable
            return CompactMetricDisplay(
                value: value,
                label: "Credits left",
                detail: Self.unavailableDetail(value: value, entry: entry))
        case .todayCost:
            let value = entry.tokenUsage.map { token in
                token.sessionCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) }
                    ?? WidgetFormat.unavailable
            } ?? WidgetFormat.unavailable
            let detail = entry.tokenUsage?.sessionTokens.map(WidgetFormat.tokenCount)
            let label = entry.tokenUsage.map {
                WidgetFormat.tokenRowTitle(
                    Self.costMetricLabel($0.sessionLabel, provider: entry.provider),
                    summary: $0,
                    entryUpdatedAt: entry.updatedAt)
            } ?? "Today cost"
            return CompactMetricDisplay(value: value, label: label, detail: detail)
        case .last30DaysCost:
            let value = entry.tokenUsage.map { token in
                token.last30DaysCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) }
                    ?? WidgetFormat.unavailable
            } ?? WidgetFormat.unavailable
            let detail = entry.tokenUsage?.last30DaysTokens.map(WidgetFormat.tokenCount)
            let label = entry.tokenUsage.map {
                WidgetFormat.tokenRowTitle(
                    Self.costMetricLabel($0.last30DaysLabel, provider: entry.provider),
                    summary: $0,
                    entryUpdatedAt: entry.updatedAt)
            } ?? "30d cost"
            return CompactMetricDisplay(value: value, label: label, detail: detail)
        }
    }

    /// A tile pinned to a metric its provider never reports would otherwise be a blank square. Name
    /// the provider so the reason is obvious and the widget can be reconfigured.
    static func unavailableDetail(value: String, entry: WidgetSnapshot.ProviderEntry) -> String? {
        guard value == WidgetFormat.unavailable else { return nil }
        let name = entry.provider.firstPartyProvider
            .flatMap { ProviderDefaults.metadata[$0]?.displayName }
            ?? entry.provider.rawValue.capitalized
        return "Not reported by \(name)"
    }

    static func costMetricLabel(_ label: String, provider: ProviderInstanceID) -> String {
        // Provider-specific by design: old Codex widget timelines lack the API-estimate billing disclaimer.
        guard provider == .codex else { return "\(label) cost" }
        // Existing widget timelines may predate the estimate labels. Do not leave a bare
        // dollar value until the app next republishes it.
        guard !label.contains("API est.") else { return label }
        return "\(label) API est. · not billed"
    }
}

/// Header for the switcher widget: the selected provider spelled out in full, plus a pager to
/// move through the others.
///
/// A widget cannot open a menu or a picker, so paging is the control that fits: it costs one line
/// instead of a whole chip row, and the provider whose numbers are on screen is always named.
private struct ProviderPagerHeader: View {
    let providers: [UsageProvider]
    let selected: UsageProvider
    let updatedAt: Date
    let size: WidgetTileSize

    var body: some View {
        let pager = ProviderPager.make(providers: self.providers, selected: self.selected)
        HStack(spacing: 7) {
            ProviderMark(provider: self.selected, isSelected: true, size: self.size.markSize)
            Text(ProviderTitle.text(for: self.selected, size: self.size))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.75)
                .layoutPriority(2)
            if self.size != .small {
                FreshnessLabel(updatedAt: self.updatedAt)
                    .layoutPriority(0)
            }
            Spacer(minLength: 4)
            if let pager, pager.isPageable {
                ProviderPagerControls(pager: pager, size: self.size)
                    .layoutPriority(1)
            }
        }
    }
}

private struct ProviderPagerControls: View {
    let pager: ProviderPager
    let size: WidgetTileSize

    var body: some View {
        HStack(spacing: 3) {
            if self.size != .small {
                ProviderPageButton(provider: self.pager.previous, symbol: "chevron.left", size: self.size)
                Text(self.pager.positionText)
                    .font(.caption2.weight(.medium))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .fixedSize()
            }
            ProviderPageButton(provider: self.pager.next, symbol: "chevron.right", size: self.size)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text("Provider \(self.pager.positionText)"))
    }
}

private struct ProviderPageButton: View {
    let provider: UsageProvider
    let symbol: String
    let size: WidgetTileSize

    var body: some View {
        if let choice = ProviderChoice(provider: self.provider) {
            Button(intent: SwitchWidgetProviderIntent(provider: choice)) {
                self.glyph
            }
            .buttonStyle(.plain)
            .accessibilityLabel(Text(ProviderPageButtonLabel.text(for: self.provider)))
        } else {
            self.glyph.opacity(0.4)
        }
    }

    private var glyph: some View {
        let side = self.size.markSize - 2
        return Image(systemName: self.symbol)
            .font(.system(size: side * 0.44, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(width: side, height: side)
            .background(
                RoundedRectangle(cornerRadius: side * 0.3, style: .continuous)
                    .fill(Color.primary.opacity(0.07)))
    }
}

enum ProviderPageButtonLabel {
    static func text(for provider: UsageProvider) -> String {
        let name = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue.capitalized
        return "Switch to \(name)"
    }
}

struct WidgetUsageRow: Identifiable, Equatable {
    let id: String
    let title: String
    let percentLeft: Double?
    /// Carried through from the row's rate window so tiles can show when the lane frees up; the
    /// snapshot has always had it and the widgets used to drop it.
    var resetsAt: Date?
    var resetDescription: String?

    private enum AntigravityQuotaFamily {
        case gemini
        case claudeGPT
    }

    static func smallWidgetRowLimit(for entry: WidgetSnapshot.ProviderEntry) -> Int? {
        self.widgetRowLimit(for: entry, family: .small)
    }

    static func mediumWidgetRowLimit(for entry: WidgetSnapshot.ProviderEntry) -> Int? {
        self.widgetRowLimit(for: entry, family: .medium)
    }

    private static func widgetRowLimit(
        for entry: WidgetSnapshot.ProviderEntry,
        family: ProviderWidgetFamily) -> Int?
    {
        guard let provider = entry.provider.firstPartyProvider else { return nil }
        return ProviderDescriptorRegistry.descriptor(for: provider).presentation.widgetRowLimit(
            rows: entry.usageRows,
            family: family)
    }

    static func rows(
        for entry: WidgetSnapshot.ProviderEntry,
        limit: Int? = nil,
        now: Date = Date()) -> [WidgetUsageRow]
    {
        let rows: [WidgetUsageRow]
        if let usageRows = entry.usageRows {
            let resolvedSnapshots = usageRows.map { row in
                guard row.window == nil,
                      let window = self.legacyCodexRateWindow(for: row.id, entry: entry)
                else {
                    return row
                }
                return WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: row.id,
                    title: row.title,
                    percentLeft: row.percentLeft,
                    window: window)
            }
            let sourceRows = resolvedSnapshots.map { row in
                // The generic snapshot writer stores only a percentage for the primary/secondary/
                // tertiary slots and leaves their reset on the entry's own windows, so recover it
                // here. Without this the reset caption is present for Codex and absent for every
                // other provider. Resolved reset only — the row keeps its own percentage.
                let reset = row.window ?? self.slotWindow(for: row.id, entry: entry)
                return WidgetUsageRow(
                    id: row.id,
                    title: row.title,
                    percentLeft: row.window?.remainingPercent ?? row.percentLeft,
                    resetsAt: reset?.resetsAt,
                    resetDescription: reset?.resetDescription)
            }
            rows = self.applyingCodexWeeklyCap(
                sourceRows,
                snapshots: resolvedSnapshots,
                provider: entry.provider,
                now: now)
        } else {
            let metadata = entry.provider.firstPartyProvider.flatMap { ProviderDefaults.metadata[$0] }
            var defaultRows = [
                WidgetUsageRow(
                    id: "primary",
                    title: metadata?.sessionLabel ?? "Session",
                    percentLeft: entry.primary?.remainingPercent,
                    resetsAt: entry.primary?.resetsAt,
                    resetDescription: entry.primary?.resetDescription),
                WidgetUsageRow(
                    id: "secondary",
                    title: metadata?.weeklyLabel ?? "Weekly",
                    percentLeft: entry.secondary?.remainingPercent,
                    resetsAt: entry.secondary?.resetsAt,
                    resetDescription: entry.secondary?.resetDescription),
            ]
            if metadata?.supportsOpus == true {
                defaultRows.append(WidgetUsageRow(
                    id: "tertiary",
                    title: metadata?.opusLabel ?? "Opus",
                    percentLeft: entry.tertiary?.remainingPercent,
                    resetsAt: entry.tertiary?.resetsAt,
                    resetDescription: entry.tertiary?.resetDescription))
            }
            rows = defaultRows.filter { $0.percentLeft != nil }
        }
        guard let limit else { return rows }
        // Provider-specific by design: Antigravity medium widgets select one constrained row per model family.
        if entry.provider == .antigravity,
           limit >= 2,
           rows.contains(where: { $0.id.hasPrefix("antigravity-quota-summary-") })
        {
            var selected = [AntigravityQuotaFamily.gemini, .claudeGPT].compactMap { family in
                rows
                    .filter { self.antigravityQuotaFamily(for: $0) == family }
                    .min(by: self.isMoreConstrained)
            }
            let selectedIDs = Set(selected.map(\.id))
            let fallbackRows = rows.enumerated()
                .filter { !selectedIDs.contains($0.element.id) }
                .sorted { lhs, rhs in
                    switch (lhs.element.percentLeft, rhs.element.percentLeft) {
                    case let (.some(left), .some(right)):
                        left == right ? lhs.offset < rhs.offset : left < right
                    case (.some, .none):
                        true
                    case (.none, .some):
                        false
                    case (.none, .none):
                        lhs.offset < rhs.offset
                    }
                }
                .map(\.element)
            selected.append(contentsOf: fallbackRows.prefix(max(0, limit - selected.count)))
            return selected
        }
        return Array(rows.prefix(max(0, limit)))
    }

    private static func applyingCodexWeeklyCap(
        _ rows: [WidgetUsageRow],
        snapshots: [WidgetSnapshot.WidgetUsageRowSnapshot],
        provider: ProviderInstanceID,
        now: Date) -> [WidgetUsageRow]
    {
        // Provider-specific by design: Codex weekly exhaustion suppresses its paired legacy session widget row.
        guard provider == .codex,
              let weekly = snapshots.first(where: { $0.id == "weekly" })?.window,
              weekly.remainingPercent <= 0,
              weekly.resetsAt.map({ $0 > now }) ?? true
        else {
            return rows
        }
        return rows.map { row in
            guard row.id == "session" else { return row }
            return WidgetUsageRow(
                id: row.id,
                title: row.title,
                percentLeft: 0,
                resetsAt: weekly.resetsAt,
                resetDescription: weekly.resetDescription)
        }
    }

    /// Reset metadata for the slot IDs the generic snapshot writer emits. Deliberately narrow:
    /// provider-specific row IDs carry their own window when the writer has one.
    static func slotWindow(for rowID: String, entry: WidgetSnapshot.ProviderEntry) -> RateWindow? {
        switch rowID {
        case "primary": entry.primary
        case "secondary": entry.secondary
        case "tertiary": entry.tertiary
        default: nil
        }
    }

    private static func legacyCodexRateWindow(
        for rowID: String,
        entry: WidgetSnapshot.ProviderEntry) -> RateWindow?
    {
        // Provider-specific by design: old Codex timelines reconstruct session/weekly windows by duration.
        guard entry.provider == .codex else { return nil }
        let candidates = [(entry.primary, "session"), (entry.secondary, "weekly")]
        for (window, fallbackID) in candidates {
            guard let window else { continue }
            let classifiedID = switch window.windowMinutes {
            case 300: "session"
            case 10080: "weekly"
            default: fallbackID
            }
            if classifiedID == rowID {
                return window
            }
        }
        return nil
    }

    static func compactTokenUsage(
        for entry: WidgetSnapshot.ProviderEntry) -> WidgetSnapshot.TokenUsageSummary?
    {
        guard self.rows(for: entry).isEmpty,
              entry.codeReviewRemainingPercent == nil
        else {
            return nil
        }
        return entry.tokenUsage
    }

    private static func antigravityQuotaFamily(for row: WidgetUsageRow) -> AntigravityQuotaFamily? {
        // Provider-specific by design: Antigravity IDs/titles classify Gemini versus third-party quota families.
        guard row.id.hasPrefix("antigravity-quota-summary-") else { return nil }
        let id = row.id.lowercased()
        if id.contains("gemini") {
            return .gemini
        }
        if id.contains("3p") || id.contains("third-party") {
            return .claudeGPT
        }

        let title = row.title.lowercased()
        if title.contains("gemini") {
            return .gemini
        }
        if title.contains("claude") || title.contains("gpt") {
            return .claudeGPT
        }
        return nil
    }

    private static func isMoreConstrained(_ lhs: WidgetUsageRow, than rhs: WidgetUsageRow) -> Bool {
        switch (lhs.percentLeft, rhs.percentLeft) {
        case let (.some(left), .some(right)):
            left < right
        case (.some, .none):
            true
        case (.none, .some):
            false
        case (.none, .none):
            false
        }
    }
}

enum WidgetUsageDisplay {
    static func percent(fromRemaining remaining: Double?, showUsed: Bool) -> Double? {
        guard let remaining else { return nil }
        let clamped = max(0, min(100, remaining))
        return showUsed ? 100 - clamped : clamped
    }
}

private struct HistoryView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let isLarge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: WidgetLayout.sectionSpacing) {
            TileHeader(
                provider: self.entry.provider,
                updatedAt: self.entry.updatedAt,
                size: self.isLarge ? .large : .medium)
            UsageHistoryChart(
                points: self.entry.dailyUsage,
                color: WidgetColors.color(for: self.entry.provider),
                currencyCode: self.entry.tokenUsage?.currencyCode)
                .frame(minHeight: self.isLarge ? 110 : 58, maxHeight: .infinity)
            if let token = entry.tokenUsage {
                VStack(alignment: .leading, spacing: 4) {
                    WidgetSeparator().padding(.bottom, 2)
                    MetricLine(
                        title: WidgetFormat.tokenRowTitle(
                            token.sessionLabel,
                            summary: token,
                            entryUpdatedAt: self.entry.updatedAt),
                        value: WidgetFormat.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode),
                        isProminent: true)
                    MetricLine(
                        title: WidgetFormat.tokenRowTitle(
                            token.last30DaysLabel,
                            summary: token,
                            entryUpdatedAt: self.entry.updatedAt),
                        value: WidgetFormat.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens,
                            currencyCode: token.currencyCode))
                }
            }
        }
        .padding(WidgetLayout.tilePadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
}

/// Daily cost or token history. The chart now labels its peak and its date range, and the most
/// recent day is drawn at full strength so "where am I today" is answerable at a glance.
struct UsageHistoryChart: View {
    let points: [WidgetSnapshot.DailyUsagePoint]
    let color: Color
    let currencyCode: String?

    var body: some View {
        let isCostMode = UsageHistoryChartMode.isCostMode(self.points)
        let values = self.points.map { point -> Double in
            isCostMode ? (point.costUSD ?? 0) : Double(point.totalTokens ?? 0)
        }
        let scale = UsageChartScale(values: values)
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(UsageHistoryChartCopy.title(dayCount: self.points.count))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer(minLength: 4)
                if let peak = UsageHistoryChartCopy.peak(
                    maximum: scale.maximum,
                    isCostMode: isCostMode,
                    currencyCode: self.currencyCode)
                {
                    Text(peak)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                        .lineLimit(1)
                        .allowsTightening(true)
                }
            }
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 3) {
                    ForEach(values.indices, id: \.self) { index in
                        let fraction = scale.fraction(for: values[index])
                        RoundedRectangle(cornerRadius: 2.5, style: .continuous)
                            .fill(self.color.opacity(index == values.indices.last ? 1 : 0.55))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(fraction > 0 ? 2 : 0, CGFloat(fraction) * geometry.size.height))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
            .frame(maxHeight: .infinity)
            Rectangle()
                .fill(Color.primary.opacity(WidgetLayout.separatorOpacity))
                .frame(height: 1)
            if let range = UsageHistoryChartCopy.range(points: self.points) {
                HStack(spacing: 4) {
                    Text(range.start)
                    Spacer(minLength: 4)
                    Text(range.end)
                }
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
            }
        }
    }
}

enum UsageHistoryChartCopy {
    static func title(dayCount: Int) -> String {
        dayCount > 0 ? "Last \(dayCount) days" : "Daily usage"
    }

    static func peak(maximum: Double, isCostMode: Bool, currencyCode: String?) -> String? {
        guard maximum > 0 else { return nil }
        if isCostMode, let currencyCode {
            return "Peak \(UsageFormatter.compactCurrencyString(maximum, currencyCode: currencyCode))"
        }
        guard !isCostMode else { return nil }
        return "Peak \(UsageFormatter.tokenCountString(Int(maximum)))"
    }

    static func range(points: [WidgetSnapshot.DailyUsagePoint]) -> (start: String, end: String)? {
        guard let first = points.first?.dayKey,
              let last = points.last?.dayKey,
              let start = WidgetFormat.dayLabel(first),
              let end = WidgetFormat.dayLabel(last),
              start != end
        else { return nil }
        return (start, end)
    }
}

enum UsageHistoryChartMode {
    static func isCostMode(_ points: [WidgetSnapshot.DailyUsagePoint]) -> Bool {
        !points.isEmpty && points.allSatisfy { $0.costUSD != nil }
    }
}

enum WidgetColors {
    static func color(for instanceID: ProviderInstanceID) -> Color {
        guard let provider = instanceID.firstPartyProvider else { return .secondary }
        // The widget cannot read ~/.codexbar/config.json, so it resolves the user override from the
        // copy the app mirrors into the App Group.
        let color = ProviderAccentColors.sharedOverride(for: instanceID)
            ?? ProviderDescriptorRegistry.descriptor(for: provider).branding.widgetColor
        return Color(red: color.red, green: color.green, blue: color.blue)
    }
}

struct WidgetBalanceLine: Equatable {
    let title: String
    let value: String
}

enum WidgetBalanceFormatter {
    static func extraUsageCost(for entry: WidgetSnapshot.ProviderEntry) -> ProviderCostSnapshot? {
        // Provider-specific by design: Devin encodes its extra-usage balance as a named provider-cost period.
        guard entry.provider == .devin,
              let cost = entry.providerCost,
              cost.period == "Extra usage balance"
        else { return nil }
        return cost
    }

    static func extraUsageBalance(for entry: WidgetSnapshot.ProviderEntry) -> WidgetBalanceLine? {
        guard let cost = self.extraUsageCost(for: entry) else { return nil }
        return WidgetBalanceLine(
            title: "Extra usage",
            value: "Balance: \(WidgetFormat.currency(cost.used, code: cost.currencyCode))")
    }
}

enum WidgetFormat {
    /// Shown when a provider does not report a figure at all.
    static let unavailable = "—"

    static func percent(_ value: Double?) -> String {
        guard let value else { return self.unavailable }
        return String(format: "%.0f%%", value)
    }

    static func credits(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 0
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "%.2f", value)
    }

    static func costAndTokens(cost: Double?, tokens: Int?, currencyCode: String = "USD") -> String {
        let costText = cost.map { self.currency($0, code: currencyCode) } ?? self.unavailable
        if let tokens {
            return "\(costText) · \(self.tokenCount(tokens))"
        }
        return costText
    }

    static func currency(_ value: Double, code: String) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = code
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? "\(code) \(String(format: "%.2f", value))"
    }

    static func tokenCount(_ value: Int) -> String {
        "\(UsageFormatter.tokenCountString(value)) tokens"
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Freshness for the tile header. Abbreviated units keep it to a fixed short string so it can
    /// never crowd out the provider name the way "5 days ago" did.
    ///
    /// Anything under a minute collapses to "Now": gallery placeholders are stamped with the render
    /// time, and the formatter renders that instant as "in 0s", which reads as a future time.
    static func shortRelativeDate(_ date: Date, relativeTo now: Date = Date()) -> String {
        guard now.timeIntervalSince(date) >= 60 else { return "Now" }
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: now)
    }

    private static let dayKeyFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter
    }()

    private static let dayLabelFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.setLocalizedDateFormatFromTemplate("MMMd")
        return formatter
    }()

    /// "2026-08-12" to "Aug 12". Returns nil for keys the chart cannot date.
    static func dayLabel(_ dayKey: String) -> String? {
        guard let date = self.dayKeyFormatter.date(from: dayKey) else { return nil }
        return self.dayLabelFormatter.string(from: date)
    }

    /// Suffixes the title with the token snapshot's own age once it lags the entry's
    /// freshness signal past `TokenUsageSummary.staleLagThreshold`.
    static func tokenRowTitle(
        _ base: String,
        summary: WidgetSnapshot.TokenUsageSummary,
        entryUpdatedAt: Date) -> String
    {
        guard summary.isStale(comparedTo: entryUpdatedAt), let updatedAt = summary.updatedAt else { return base }
        return "\(base) · \(self.relativeDate(updatedAt))"
    }
}
