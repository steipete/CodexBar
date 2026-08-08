import CodexBarCore
import SwiftUI
import WidgetKit

extension EnvironmentValues {
    @Entry fileprivate var widgetUsageShowsUsed: Bool = false
}

struct CodexBarUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarWidgetEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        Group {
            if let providerEntry {
                self.content(providerEntry: providerEntry)
            } else {
                self.emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }

    @ViewBuilder
    private func content(providerEntry: WidgetSnapshot.ProviderEntry) -> some View {
        switch self.family {
        case .systemSmall:
            SmallUsageView(entry: providerEntry)
        case .systemMedium:
            MediumUsageView(entry: providerEntry)
        default:
            LargeUsageView(entry: providerEntry)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open CodexBar")
                .font(.body)
                .fontWeight(.semibold)
            Text("Usage data will appear once the app refreshes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
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
                self.emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open CodexBar")
                .font(.body)
                .fontWeight(.semibold)
            Text("Usage history will appear after a refresh.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
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
                self.emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open CodexBar")
                .font(.body)
                .fontWeight(.semibold)
            Text("Usage data will appear once the app refreshes.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(12)
    }
}

struct CodexBarSwitcherWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarSwitcherEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider.instanceID }
        VStack(alignment: .leading, spacing: 10) {
            ProviderSwitcherRow(
                providers: self.entry.availableProviders,
                selected: self.entry.provider,
                updatedAt: providerEntry?.updatedAt ?? Date(),
                compact: self.family == .systemSmall,
                showsTimestamp: self.family != .systemSmall)
            if let providerEntry {
                self.content(providerEntry: providerEntry)
            } else {
                self.emptyState
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .containerBackground(.fill.tertiary, for: .widget)
        .environment(\.widgetUsageShowsUsed, self.entry.snapshot.usageBarsShowUsed)
    }

    @ViewBuilder
    private func content(providerEntry: WidgetSnapshot.ProviderEntry) -> some View {
        switch self.family {
        case .systemSmall:
            SwitcherSmallUsageView(entry: providerEntry)
        case .systemMedium:
            SwitcherMediumUsageView(entry: providerEntry)
        default:
            SwitcherLargeUsageView(entry: providerEntry)
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Open CodexBar")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Usage data appears after a refresh.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct CompactMetricView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let metric: CompactMetric

    var body: some View {
        let display = CompactMetricFormatter.display(for: self.entry, metric: self.metric)
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            VStack(alignment: .leading, spacing: 2) {
                Text(display.value)
                    .font(.title2)
                    .fontWeight(.semibold)
                Text(display.label)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                if let detail = display.detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
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
            let value = entry.creditsRemaining.map(WidgetFormat.credits) ?? "—"
            return CompactMetricDisplay(value: value, label: "Credits left", detail: nil)
        case .todayCost:
            let value = entry.tokenUsage.map { token in
                token.sessionCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) } ?? "—"
            } ?? "—"
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
                token.last30DaysCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) } ?? "—"
            } ?? "—"
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

    static func costMetricLabel(_ label: String, provider: ProviderInstanceID) -> String {
        // Provider-specific by design: old Codex widget timelines lack the API-estimate billing disclaimer.
        guard provider == .codex else { return "\(label) cost" }
        // Existing widget timelines may predate the estimate labels. Do not leave a bare
        // dollar value until the app next republishes it.
        guard !label.contains("API est.") else { return label }
        return "\(label) API est. · not billed"
    }
}

private struct ProviderSwitcherRow: View {
    let providers: [UsageProvider]
    let selected: UsageProvider
    let updatedAt: Date
    let compact: Bool
    let showsTimestamp: Bool

    var body: some View {
        HStack(spacing: self.compact ? 4 : 6) {
            ForEach(self.providers, id: \.self) { provider in
                ProviderSwitchChip(
                    provider: provider,
                    selected: provider == self.selected,
                    compact: self.compact)
            }
            if self.showsTimestamp {
                Spacer(minLength: 6)
                Text(WidgetFormat.relativeDate(self.updatedAt))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

private struct ProviderSwitchChip: View {
    let provider: UsageProvider
    let selected: Bool
    let compact: Bool

    var body: some View {
        let label = self.compact ? self.shortLabel : self.longLabel
        let background = self.selected
            ? WidgetColors.color(for: self.provider.instanceID).opacity(0.2)
            : Color.primary.opacity(0.08)

        if let choice = ProviderChoice(provider: self.provider) {
            Button(intent: SwitchWidgetProviderIntent(provider: choice)) {
                Text(label)
                    .font(self.compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                    .foregroundStyle(self.selected ? Color.primary : Color.secondary)
                    .padding(.horizontal, self.compact ? 6 : 8)
                    .padding(.vertical, self.compact ? 3 : 4)
                    .background(Capsule().fill(background))
            }
            .buttonStyle(.plain)
        } else {
            Text(label)
                .font(self.compact ? .caption2.weight(.semibold) : .caption.weight(.semibold))
                .foregroundStyle(self.selected ? Color.primary : Color.secondary)
                .padding(.horizontal, self.compact ? 6 : 8)
                .padding(.vertical, self.compact ? 3 : 4)
                .background(Capsule().fill(background))
        }
    }

    private var longLabel: String {
        ProviderDefaults.metadata[self.provider]?.displayName ?? self.provider.rawValue.capitalized
    }

    private var shortLabel: String {
        ProviderDefaults.metadata[self.provider]?.shortDisplayName ?? self.provider.rawValue.capitalized
    }
}

private struct SwitcherSmallUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(WidgetUsageRow.rows(
                for: self.entry,
                limit: WidgetUsageRow.smallWidgetRowLimit(for: self.entry)))
            { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let codeReview = entry.codeReviewRemainingPercent {
                UsageBarRow(
                    title: "Code review",
                    percentLeft: codeReview,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let token = WidgetUsageRow.compactTokenUsage(for: self.entry) {
                ValueLine(
                    title: WidgetFormat.tokenRowTitle(
                        token.sessionLabel,
                        summary: token,
                        entryUpdatedAt: self.entry.updatedAt),
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
            }
            if let balance = extraUsageBalanceLine(for: entry) {
                balance
            }
        }
    }
}

private struct SwitcherMediumUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(WidgetUsageRow.rows(
                for: self.entry,
                limit: WidgetUsageRow.mediumWidgetRowLimit(for: self.entry)))
            { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let credits = entry.creditsRemaining {
                ValueLine(title: "Credits", value: WidgetFormat.credits(credits))
            }
            if let token = entry.tokenUsage {
                ValueLine(
                    title: WidgetFormat.tokenRowTitle(
                        token.sessionLabel,
                        summary: token,
                        entryUpdatedAt: self.entry.updatedAt),
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
            }
            if let balance = extraUsageBalanceLine(for: entry) {
                balance
            }
        }
    }
}

private struct SwitcherLargeUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(WidgetUsageRow.rows(for: self.entry)) { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let codeReview = entry.codeReviewRemainingPercent {
                UsageBarRow(
                    title: "Code review",
                    percentLeft: codeReview,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let credits = entry.creditsRemaining {
                ValueLine(title: "Credits", value: WidgetFormat.credits(credits))
            }
            if let token = entry.tokenUsage {
                VStack(alignment: .leading, spacing: 4) {
                    ValueLine(
                        title: WidgetFormat.tokenRowTitle(
                            token.sessionLabel,
                            summary: token,
                            entryUpdatedAt: self.entry.updatedAt),
                        value: WidgetFormat.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode))
                    ValueLine(
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
            if let balance = extraUsageBalanceLine(for: entry) {
                balance
            }
            UsageHistoryChart(
                points: self.entry.dailyUsage,
                color: WidgetColors.color(for: self.entry.provider),
                currencyCode: self.entry.tokenUsage?.currencyCode)
                .frame(height: 50)
        }
    }
}

private struct SmallUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            ForEach(WidgetUsageRow.rows(
                for: self.entry,
                limit: WidgetUsageRow.smallWidgetRowLimit(for: self.entry)))
            { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let codeReview = entry.codeReviewRemainingPercent {
                UsageBarRow(
                    title: "Code review",
                    percentLeft: codeReview,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let token = WidgetUsageRow.compactTokenUsage(for: self.entry) {
                ValueLine(
                    title: WidgetFormat.tokenRowTitle(
                        token.sessionLabel,
                        summary: token,
                        entryUpdatedAt: self.entry.updatedAt),
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
            }
            if let balance = extraUsageBalanceLine(for: entry) {
                balance
            }
        }
        .padding(12)
    }
}

private struct MediumUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            ForEach(WidgetUsageRow.rows(
                for: self.entry,
                limit: WidgetUsageRow.mediumWidgetRowLimit(for: self.entry)))
            { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let credits = entry.creditsRemaining {
                ValueLine(title: "Credits", value: WidgetFormat.credits(credits))
            }
            if let token = entry.tokenUsage {
                ValueLine(
                    title: WidgetFormat.tokenRowTitle(
                        token.sessionLabel,
                        summary: token,
                        entryUpdatedAt: self.entry.updatedAt),
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
            }
            if let balance = extraUsageBalanceLine(for: entry) {
                balance
            }
        }
        .padding(12)
    }
}

private struct LargeUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            ForEach(WidgetUsageRow.rows(for: self.entry)) { row in
                UsageBarRow(
                    title: row.title,
                    percentLeft: row.percentLeft,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let codeReview = entry.codeReviewRemainingPercent {
                UsageBarRow(
                    title: "Code review",
                    percentLeft: codeReview,
                    color: WidgetColors.color(for: self.entry.provider))
            }
            if let credits = entry.creditsRemaining {
                ValueLine(title: "Credits", value: WidgetFormat.credits(credits))
            }
            if let token = entry.tokenUsage {
                VStack(alignment: .leading, spacing: 4) {
                    ValueLine(
                        title: WidgetFormat.tokenRowTitle(
                            token.sessionLabel,
                            summary: token,
                            entryUpdatedAt: self.entry.updatedAt),
                        value: WidgetFormat.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode))
                    ValueLine(
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
            if let balance = extraUsageBalanceLine(for: entry) {
                balance
            }
            UsageHistoryChart(
                points: self.entry.dailyUsage,
                color: WidgetColors.color(for: self.entry.provider),
                currencyCode: self.entry.tokenUsage?.currencyCode)
                .frame(height: 50)
        }
        .padding(12)
    }
}

struct WidgetUsageRow: Identifiable, Equatable {
    let id: String
    let title: String
    let percentLeft: Double?

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
                WidgetUsageRow(
                    id: row.id,
                    title: row.title,
                    percentLeft: row.window?.remainingPercent ?? row.percentLeft)
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
                    percentLeft: entry.primary?.remainingPercent),
                WidgetUsageRow(
                    id: "secondary",
                    title: metadata?.weeklyLabel ?? "Weekly",
                    percentLeft: entry.secondary?.remainingPercent),
            ]
            if metadata?.supportsOpus == true {
                defaultRows.append(WidgetUsageRow(
                    id: "tertiary",
                    title: metadata?.opusLabel ?? "Opus",
                    percentLeft: entry.tertiary?.remainingPercent))
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
            return WidgetUsageRow(id: row.id, title: row.title, percentLeft: 0)
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
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            UsageHistoryChart(
                points: self.entry.dailyUsage,
                color: WidgetColors.color(for: self.entry.provider),
                currencyCode: self.entry.tokenUsage?.currencyCode)
                .frame(height: self.isLarge ? 90 : 60)
            if let token = entry.tokenUsage {
                ValueLine(
                    title: WidgetFormat.tokenRowTitle(
                        token.sessionLabel,
                        summary: token,
                        entryUpdatedAt: self.entry.updatedAt),
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
                ValueLine(
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
        .padding(12)
    }
}

private struct HeaderView: View {
    let provider: ProviderInstanceID
    let updatedAt: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(self.provider.firstPartyProvider.flatMap { ProviderDefaults.metadata[$0]?.displayName }
                ?? self.provider.rawValue.capitalized)
                .font(.body)
                .fontWeight(.semibold)
            Spacer()
            Text(WidgetFormat.relativeDate(self.updatedAt))
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
    }
}

private struct UsageBarRow: View {
    @Environment(\.widgetUsageShowsUsed) private var showUsed
    let title: String
    let percentLeft: Double?
    let color: Color

    var body: some View {
        let percent = WidgetUsageDisplay.percent(fromRemaining: self.percentLeft, showUsed: self.showUsed)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(self.title)
                    .font(.caption)
                Spacer()
                Text(WidgetFormat.percent(percent))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = max(0, min(1, (percent ?? 0) / 100)) * proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule().fill(self.color).frame(width: width)
                }
            }
            .frame(height: 6)
        }
    }
}

private struct ValueLine: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 6) {
            Text(self.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(minWidth: 0, maxWidth: .infinity, alignment: .leading)
            Text(self.value)
                .font(.caption)
                .monospacedDigit()
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .allowsTightening(true)
                .layoutPriority(1)
        }
    }
}

private struct UsageHistoryChart: View {
    let points: [WidgetSnapshot.DailyUsagePoint]
    let color: Color
    let currencyCode: String?

    var body: some View {
        let isCostMode = UsageHistoryChartMode.isCostMode(self.points)
        let values = self.points.map { point -> Double in
            if isCostMode {
                return point.costUSD ?? 0
            }
            return Double(point.totalTokens ?? 0)
        }
        let scale = UsageChartScale(values: values)
        VStack(alignment: .trailing, spacing: 2) {
            if isCostMode,
               let currencyCode = self.currencyCode,
               scale.maximum > 0
            {
                Text(UsageFormatter.compactCurrencyString(scale.maximum, currencyCode: currencyCode))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .allowsTightening(true)
            }
            GeometryReader { geometry in
                HStack(alignment: .bottom, spacing: 2) {
                    ForEach(values.indices, id: \.self) { index in
                        let fraction = scale.fraction(for: values[index])
                        RoundedRectangle(cornerRadius: 2)
                            .fill(self.color.opacity(0.85))
                            .frame(maxWidth: .infinity)
                            .frame(height: max(fraction > 0 ? 2 : 0, CGFloat(fraction) * geometry.size.height))
                            .animation(.easeOut(duration: 0.2), value: fraction)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            }
        }
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
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.widgetColor
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

private func extraUsageBalanceLine(for entry: WidgetSnapshot.ProviderEntry) -> ValueLine? {
    guard let line = WidgetBalanceFormatter.extraUsageBalance(for: entry) else { return nil }
    return ValueLine(title: line.title, value: line.value)
}

enum WidgetFormat {
    static func percent(_ value: Double?) -> String {
        guard let value else { return "—" }
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
        let costText = cost.map { self.currency($0, code: currencyCode) } ?? "—"
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
