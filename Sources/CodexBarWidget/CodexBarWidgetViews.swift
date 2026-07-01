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
            let value = self.entry.tokenUsage.map { token in
                token.sessionCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) } ?? "—"
            } ?? "—"
            let detail = self.entry.tokenUsage?.sessionTokens.map(WidgetFormat.tokenCount)
            let label = self.entry.tokenUsage.map { "\($0.sessionLabel) cost" } ?? "Today cost"
            return (value, label, detail)
        case .last30DaysCost:
            let value = self.entry.tokenUsage.map { token in
                token.last30DaysCostUSD.map { WidgetFormat.currency($0, code: token.currencyCode) } ?? "—"
            } ?? "—"
            let detail = self.entry.tokenUsage?.last30DaysTokens.map(WidgetFormat.tokenCount)
            let label = self.entry.tokenUsage.map { "\($0.last30DaysLabel) cost" } ?? "30d cost"
            return (value, label, detail)
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
        case .openai: "OpenAI"
        case .azureopenai: "Azure OpenAI"
        case .claude: "Claude"
        case .gemini: "Gemini"
        case .antigravity: "Anti"
        case .cursor: "Cursor"
        case .opencode: "OpenCode"
        case .opencodego: "OpenCode Go"
        case .alibaba: "Alibaba"
        case .alibabatokenplan: "Token Plan"
        case .zai: "z.ai"
        case .factory: "Droid"
        case .copilot: "Copilot"
        case .devin: "Devin"
        case .minimax: "MiniMax"
        case .manus: "Manus"
        case .vertexai: "Vertex"
        case .kilo: "Kilo"
        case .kiro: "Kiro"
        case .augment: "Augment"
        case .jetbrains: "JetBrains"
        case .kimi: "Kimi"
        case .kimik2: "Kimi K2"
        case .moonshot: "Moonshot"
        case .amp: "Amp"
        case .t3chat: "T3 Chat"
        case .ollama: "Ollama"
        case .synthetic: "Synthetic"
        case .openrouter: "OpenRouter"
        case .elevenlabs: "ElevenLabs"
        case .warp: "Warp"
        case .windsurf: "Windsurf"
        case .perplexity: "Pplx"
        case .mimo: "MiMo"
        case .doubao: "Doubao"
        case .sakana: "Sakana"
        case .abacus: "Abacus"
        case .mistral: "Mistral"
        case .deepseek: "DeepSeek"
        case .codebuff: "Codebuff"
        case .crof: "Crof"
        case .venice: "Venice"
        case .commandcode: "Command Code"
        case .stepfun: "StepFun"
        case .bedrock: "Bedrock"
        case .grok: "Grok"
        case .groq: "Groq"
        case .llmproxy: "LLM Proxy"
        case .litellm: "LiteLLM"
        case .deepgram: "Deepgram"
        case .poe: "Poe"
        case .chutes: "Chutes"
        case .zed: "Zed"
        }
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
                    title: token.sessionLabel,
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
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
                    title: token.sessionLabel,
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
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
                        title: token.sessionLabel,
                        value: WidgetFormat.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode))
                    ValueLine(
                        title: token.last30DaysLabel,
                        value: WidgetFormat.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens,
                            currencyCode: token.currencyCode))
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
                    title: token.sessionLabel,
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
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
                    title: token.sessionLabel,
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
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
                        title: token.sessionLabel,
                        value: WidgetFormat.costAndTokens(
                            cost: token.sessionCostUSD,
                            tokens: token.sessionTokens,
                            currencyCode: token.currencyCode))
                    ValueLine(
                        title: token.last30DaysLabel,
                        value: WidgetFormat.costAndTokens(
                            cost: token.last30DaysCostUSD,
                            tokens: token.last30DaysTokens,
                            currencyCode: token.currencyCode))
                }
            }
            UsageHistoryChart(points: self.entry.dailyUsage, color: WidgetColors.color(for: self.entry.provider))
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
        self.antigravityQuotaSummaryRowLimit(for: entry, limit: 2)
    }

    static func mediumWidgetRowLimit(for entry: WidgetSnapshot.ProviderEntry) -> Int? {
        self.antigravityQuotaSummaryRowLimit(for: entry, limit: 3)
    }

    private static func antigravityQuotaSummaryRowLimit(
        for entry: WidgetSnapshot.ProviderEntry,
        limit: Int) -> Int?
    {
        guard entry.provider == .antigravity,
              entry.usageRows?.contains(where: {
                  $0.id.hasPrefix("antigravity-quota-summary-")
              }) == true
        else {
            return nil
        }
        return limit
    }

    static func rows(for entry: WidgetSnapshot.ProviderEntry, limit: Int? = nil) -> [WidgetUsageRow] {
        let rows: [WidgetUsageRow]
        if let usageRows = entry.usageRows {
            rows = usageRows.map { row in
                WidgetUsageRow(id: row.id, title: row.title, percentLeft: row.percentLeft)
            }
        } else {
            let metadata = ProviderDefaults.metadata[entry.provider]
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
            UsageHistoryChart(points: self.entry.dailyUsage, color: WidgetColors.color(for: self.entry.provider))
                .frame(height: self.isLarge ? 90 : 60)
            if let token = entry.tokenUsage {
                ValueLine(
                    title: token.sessionLabel,
                    value: WidgetFormat.costAndTokens(
                        cost: token.sessionCostUSD,
                        tokens: token.sessionTokens,
                        currencyCode: token.currencyCode))
                ValueLine(
                    title: token.last30DaysLabel,
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
    // swiftlint:disable:next cyclomatic_complexity
    static func color(for provider: UsageProvider) -> Color {
        switch provider {
        case .codex:
            Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)
        case .openai:
            Color(red: 15 / 255, green: 130 / 255, blue: 110 / 255)
        case .azureopenai:
            Color(red: 0, green: 120 / 255, blue: 212 / 255)
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
        case .opencodego:
            Color(red: 59 / 255, green: 130 / 255, blue: 246 / 255)
        case .alibaba, .alibabatokenplan:
            Color(red: 1.0, green: 106 / 255, blue: 0)
        case .zai:
            Color(red: 232 / 255, green: 90 / 255, blue: 106 / 255)
        case .factory:
            Color(red: 255 / 255, green: 107 / 255, blue: 53 / 255) // Factory orange
        case .copilot:
            Color(red: 168 / 255, green: 85 / 255, blue: 247 / 255) // Purple
        case .devin:
            Color(red: 70 / 255, green: 180 / 255, blue: 130 / 255)
        case .minimax:
            Color(red: 254 / 255, green: 96 / 255, blue: 60 / 255)
        case .manus:
            Color(red: 24 / 255, green: 24 / 255, blue: 24 / 255)
        case .vertexai:
            Color(red: 66 / 255, green: 133 / 255, blue: 244 / 255) // Google Blue
        case .kilo:
            Color(red: 242 / 255, green: 112 / 255, blue: 39 / 255) // Kilo orange
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
        case .moonshot:
            Color(red: 32 / 255, green: 93 / 255, blue: 235 / 255)
        case .amp:
            Color(red: 220 / 255, green: 38 / 255, blue: 38 / 255) // Amp red
        case .t3chat:
            Color(red: 245 / 255, green: 102 / 255, blue: 71 / 255)
        case .ollama:
            Color(red: 32 / 255, green: 32 / 255, blue: 32 / 255) // Ollama charcoal
        case .synthetic:
            Color(red: 20 / 255, green: 20 / 255, blue: 20 / 255) // Synthetic charcoal
        case .openrouter:
            Color(red: 111 / 255, green: 66 / 255, blue: 193 / 255) // OpenRouter purple
        case .elevenlabs:
            Color(red: 235 / 255, green: 235 / 255, blue: 230 / 255)
        case .warp:
            Color(red: 147 / 255, green: 139 / 255, blue: 180 / 255)
        case .windsurf:
            Color(red: 52 / 255, green: 232 / 255, blue: 187 / 255) // Windsurf #34e8bb
        case .perplexity:
            Color(red: 32 / 255, green: 178 / 255, blue: 170 / 255) // Perplexity teal
        case .mimo:
            Color(red: 1.0, green: 105 / 255, blue: 0)
        case .doubao:
            Color(red: 45 / 255, green: 136 / 255, blue: 255 / 255) // Doubao blue
        case .sakana:
            Color(red: 41 / 255, green: 117 / 255, blue: 219 / 255)
        case .abacus:
            Color(red: 56 / 255, green: 189 / 255, blue: 248 / 255)
        case .mistral:
            Color(red: 255 / 255, green: 80 / 255, blue: 15 / 255) // Mistral orange
        case .deepseek:
            Color(red: 82 / 255, green: 125 / 255, blue: 240 / 255)
        case .codebuff:
            Color(red: 68 / 255, green: 255 / 255, blue: 0 / 255) // Codebuff lime
        case .crof:
            Color(red: 46 / 255, green: 171 / 255, blue: 148 / 255)
        case .venice:
            Color(red: 51 / 255, green: 153 / 255, blue: 1.0)
        case .commandcode:
            Color(red: 0, green: 0, blue: 0)
        case .stepfun:
            Color(red: 255 / 255, green: 140 / 255, blue: 0 / 255) // StepFun orange
        case .bedrock:
            Color(red: 255 / 255, green: 153 / 255, blue: 0 / 255) // AWS orange
        case .grok:
            Color(red: 16 / 255, green: 163 / 255, blue: 127 / 255) // Grok teal
        case .groq:
            Color(red: 245 / 255, green: 104 / 255, blue: 68 / 255)
        case .llmproxy:
            Color(red: 36 / 255, green: 180 / 255, blue: 126 / 255)
        case .litellm:
            Color(red: 76 / 255, green: 137 / 255, blue: 240 / 255)
        case .deepgram:
            Color(red: 10 / 255, green: 18 / 255, blue: 27 / 255)
        case .poe:
            Color(red: 0.15, green: 0.68, blue: 0.38)
        case .chutes:
            Color(red: 24 / 255, green: 160 / 255, blue: 88 / 255)
        case .zed:
            Color(red: 64 / 255, green: 156 / 255, blue: 255 / 255)
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
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        let raw = formatter.string(from: NSNumber(value: value)) ?? "\(value)"
        return "\(raw) tokens"
    }

    static func relativeDate(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: "en_US")
        formatter.unitsStyle = .short
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
