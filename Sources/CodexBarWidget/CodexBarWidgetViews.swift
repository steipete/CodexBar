import CodexBarCore
import SwiftUI
import WidgetKit

struct CodexBarUsageWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let entry: CodexBarWidgetEntry

    var body: some View {
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider }
        ZStack {
            Color.black.opacity(0.02)
            if let providerEntry {
                self.content(providerEntry: providerEntry)
            } else {
                self.emptyState
            }
        }
        .containerBackground(.fill.tertiary, for: .widget)
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
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider }
        ZStack {
            Color.black.opacity(0.02)
            if let providerEntry {
                HistoryView(entry: providerEntry, isLarge: self.family == .systemLarge)
            } else {
                self.emptyState
            }
        }
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
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider }
        ZStack {
            Color.black.opacity(0.02)
            if let providerEntry {
                CompactMetricView(entry: providerEntry, metric: self.entry.metric)
            } else {
                self.emptyState
            }
        }
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
        let providerEntry = self.entry.snapshot.entries.first { $0.provider == self.entry.provider }
        ZStack {
            Color.black.opacity(0.02)
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
        }
        .containerBackground(.fill.tertiary, for: .widget)
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
        let display = self.display
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

    private var display: (value: String, label: String, detail: String?) {
        switch self.metric {
        case .credits:
            let value = self.entry.creditsRemaining.map(WidgetFormat.credits) ?? "—"
            return (value, "Credits left", nil)
        case .todayCost:
            let value = self.entry.tokenUsage?.sessionCostUSD.map(WidgetFormat.usd) ?? "—"
            let detail = self.entry.tokenUsage?.sessionTokens.map(WidgetFormat.tokenCount)
            return (value, "Today cost", detail)
        case .last30DaysCost:
            let value = self.entry.tokenUsage?.last30DaysCostUSD.map(WidgetFormat.usd) ?? "—"
            let detail = self.entry.tokenUsage?.last30DaysTokens.map(WidgetFormat.tokenCount)
            return (value, "30d cost", detail)
        }
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
            ? WidgetColors.color(for: self.provider).opacity(0.2)
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
        switch self.provider {
        case .codex: "Codex"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .antigravity: "Anti"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .zai: "z.ai"
        case .factory: "Droid"
        case .copilot: "Copilot"
        case .minimax: "MiniMax"
        case .vertexai: "Vertex"
        case .kiro: "Kiro"
        case .augment: "Augment"
        case .jetbrains: "JetBrains"
        case .kimi: "Kimi"
        case .kimik2: "Kimi K2"
        case .amp: "Amp"
        case .synthetic: "Synthetic"
        }
    }
}

private struct SwitcherSmallUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.sessionLabel ?? "Session",
                percentLeft: self.entry.primary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.weeklyLabel ?? "Weekly",
                percentLeft: self.entry.secondary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            if let codeReview = entry.codeReviewRemainingPercent {
                UsageBarRow(
                    title: "Code review",
                    percentLeft: codeReview,
                    color: WidgetColors.color(for: self.entry.provider))
            }
        }
    }
}

private struct SwitcherMediumUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.sessionLabel ?? "Session",
                percentLeft: self.entry.primary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.weeklyLabel ?? "Weekly",
                percentLeft: self.entry.secondary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            if let credits = entry.creditsRemaining {
                ValueLine(title: "Credits", value: WidgetFormat.credits(credits))
            }
            if let token = entry.tokenUsage {
                ValueLine(
                    title: "Today",
                    value: WidgetFormat.costAndTokens(cost: token.sessionCostUSD, tokens: token.sessionTokens))
            }
        }
    }
}

private struct SwitcherLargeUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.sessionLabel ?? "Session",
                percentLeft: self.entry.primary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.weeklyLabel ?? "Weekly",
                percentLeft: self.entry.secondary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
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
                        title: "Today",
                        value: WidgetFormat.costAndTokens(cost: token.sessionCostUSD, tokens: token.sessionTokens))
                    ValueLine(
                        title: "30d",
                        value: WidgetFormat.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens))
                }
            }
            UsageHistoryChart(points: self.entry.dailyUsage, color: WidgetColors.color(for: self.entry.provider))
                .frame(height: 50)
        }
    }
}

private struct SmallUsageView: View {
    let entry: WidgetSnapshot.ProviderEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.sessionLabel ?? "Session",
                percentLeft: self.entry.primary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.weeklyLabel ?? "Weekly",
                percentLeft: self.entry.secondary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            if let codeReview = entry.codeReviewRemainingPercent {
                UsageBarRow(
                    title: "Code review",
                    percentLeft: codeReview,
                    color: WidgetColors.color(for: self.entry.provider))
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
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.sessionLabel ?? "Session",
                percentLeft: self.entry.primary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.weeklyLabel ?? "Weekly",
                percentLeft: self.entry.secondary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            if let credits = entry.creditsRemaining {
                ValueLine(title: "Credits", value: WidgetFormat.credits(credits))
            }
            if let token = entry.tokenUsage {
                ValueLine(
                    title: "Today",
                    value: WidgetFormat.costAndTokens(cost: token.sessionCostUSD, tokens: token.sessionTokens))
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
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.sessionLabel ?? "Session",
                percentLeft: self.entry.primary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
            UsageBarRow(
                title: ProviderDefaults.metadata[self.entry.provider]?.weeklyLabel ?? "Weekly",
                percentLeft: self.entry.secondary?.remainingPercent,
                color: WidgetColors.color(for: self.entry.provider))
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
                        title: "Today",
                        value: WidgetFormat.costAndTokens(cost: token.sessionCostUSD, tokens: token.sessionTokens))
                    ValueLine(
                        title: "30d",
                        value: WidgetFormat.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens))
                }
            }
            UsageHistoryChart(points: self.entry.dailyUsage, color: WidgetColors.color(for: self.entry.provider))
                .frame(height: 50)
        }
        .padding(12)
    }
}

private struct HistoryView: View {
    let entry: WidgetSnapshot.ProviderEntry
    let isLarge: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HeaderView(provider: self.entry.provider, updatedAt: self.entry.updatedAt)
            UsageHistoryChart(points: self.entry.dailyUsage, color: WidgetColors.color(for: self.entry.provider))
                .frame(height: self.isLarge ? 90 : 60)
            if let token = entry.tokenUsage {
                ValueLine(
                    title: "Today",
                    value: WidgetFormat.costAndTokens(cost: token.sessionCostUSD, tokens: token.sessionTokens))
                ValueLine(
                    title: "30d",
                    value: WidgetFormat.costAndTokens(cost: token.last30DaysCostUSD, tokens: token.last30DaysTokens))
            }
        }
        .padding(12)
    }
}

private struct HeaderView: View {
    let provider: UsageProvider
    let updatedAt: Date

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(ProviderDefaults.metadata[self.provider]?.displayName ?? self.provider.rawValue.capitalized)
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
    let title: String
    let percentLeft: Double?
    let color: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(self.title)
                    .font(.caption)
                Spacer()
                Text(WidgetFormat.percent(self.percentLeft))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            GeometryReader { proxy in
                let width = max(0, min(1, (percentLeft ?? 0) / 100)) * proxy.size.width
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
            Text(self.value)
                .font(.caption)
        }
    }
}

private struct UsageHistoryChart: View {
    let points: [WidgetSnapshot.DailyUsagePoint]
    let color: Color

    var body: some View {
        let values = self.points.map { point -> Double in
            if let cost = point.costUSD { return cost }
            return Double(point.totalTokens ?? 0)
        }
        let maxValue = values.max() ?? 0
        HStack(alignment: .bottom, spacing: 2) {
            ForEach(values.indices, id: \.self) { index in
                let value = values[index]
                let height = maxValue > 0 ? CGFloat(value / maxValue) : 0
                RoundedRectangle(cornerRadius: 2)
                    .fill(self.color.opacity(0.85))
                    .frame(maxWidth: .infinity)
                    .scaleEffect(x: 1, y: height, anchor: .bottom)
                    .animation(.easeOut(duration: 0.2), value: height)
            }
        }
    }
}

enum WidgetColors {
    static func color(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .claude:
            Color(red: 204 / 255, green: 124 / 255, blue: 94 / 255)
        case .gemini:
            Color(red: 171 / 255, green: 135 / 255, blue: 234 / 255)
        case .antigravity:
            Color(red: 96 / 255, green: 186 / 255, blue: 126 / 255)
        case .cursor:
            Color(red: 0 / 255, green: 191 / 255, blue: 165 / 255) // #00BFA5 - Cursor teal
        case .opencode:
            Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
        case .zai:
            Color(red: 232 / 255, green: 90 / 255, blue: 106 / 255)
        case .factory:
            Color(red: 255 / 255, green: 107 / 255, blue: 53 / 255) // Factory orange
        case .copilot:
            Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255) // Purple
        case .minimax:
            Color(red: 254 / 255, green: 96 / 255, blue: 60 / 255)
        case .vertexai:
            Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255) // Google Blue
        case .kiro:
            Color(red: 255 / 255, green: 153 / 255, blue: 0 / 255) // AWS orange
        case .augment:
            Color(red: 99 / 255, green: 102 / 255, blue: 241 / 255) // Augment purple
        case .jetbrains:
            Color(red: 255 / 255, green: 51 / 255, blue: 153 / 255) // JetBrains pink
        case .kimi:
            Color(red: 254 / 255, green: 96 / 255, blue: 60 / 255) // Kimi orange
        case .kimik2:
            Color(red: 76 / 255, green: 0 / 255, blue: 255 / 255) // Kimi K2 purple
        case .amp:
            Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255) // Amp red
        case .synthetic:
            Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255) // Synthetic charcoal
        }
    }
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

    static func costAndTokens(cost: Double?, tokens: Int?) -> String {
        let costText = cost.map(self.usd) ?? "—"
        if let tokens {
            return "\(costText) · \(self.tokenCount(tokens))"
        }
        return costText
    }

    static func usd(_ value: Double) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = "USD"
        formatter.maximumFractionDigits = 2
        formatter.minimumFractionDigits = 2
        return formatter.string(from: NSNumber(value: value)) ?? String(format: "$%.2f", value)
    }

    static func tokenCount(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let raw = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(raw) tokens"
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
