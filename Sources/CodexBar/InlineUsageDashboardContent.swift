import CodexBarCore
import SwiftUI

struct InlineUsageDashboardModel: Equatable {
    struct KPI: Equatable {
        let title: String
        let value: String
        let emphasis: Bool
    }

    struct Point: Equatable, Identifiable {
        let id: String
        let label: String
        let value: Double
        let accessibilityValue: String
    }

    enum ValueStyle: Equatable {
        case currencyUSD
        case currency(symbol: String)
        case tokens
    }

    let accessibilityLabel: String
    let valueStyle: ValueStyle
    let kpis: [KPI]
    let points: [Point]
    let detailLines: [String]
}

extension UsageMenuCardView.Model {
    static func apiProviderUsageNotes(input: Input) -> [String]? {
        if input.provider == .openai,
           let usage = input.snapshot?.openAIAPIUsage
        {
            return self.openAIAPIUsageNotes(usage)
        }

        if input.provider == .deepgram,
           let usage = input.snapshot?.deepgramUsage
        {
            return usage.displayLines
        }

        if input.provider == .minimax,
           input.showOptionalCreditsAndExtraUsage,
           let billing = input.snapshot?.minimaxUsage?.billingSummary
        {
            return [
                "Today: \(UsageFormatter.tokenCountString(billing.todayTokens)) tokens",
                "Last 30 days: \(UsageFormatter.tokenCountString(billing.last30DaysTokens)) tokens",
            ]
        }

        if input.provider == .ollama,
           input.snapshot?.identity?.loginMethod == "API key"
        {
            return ["API key verified. Ollama does not expose Cloud quota limits through the API."]
        }

        return nil
    }

    static func openAIAPIUsageNotes(_ usage: OpenAIAPIUsageSnapshot) -> [String] {
        let today = usage.latestDay
        let seven = usage.last7Days
        let thirty = usage.last30Days
        let historyLabel = usage.historyWindowLabel
        let todayNote = "Today: \(UsageFormatter.usdString(today.costUSD)) · " +
            "\(UsageFormatter.tokenCountString(today.totalTokens)) tokens"
        let sevenDayNote = "7d: \(UsageFormatter.usdString(seven.costUSD)) · " +
            "\(UsageFormatter.tokenCountString(seven.requests)) requests"
        let thirtyDayNote = "\(historyLabel): \(UsageFormatter.tokenCountString(thirty.totalTokens)) tokens · " +
            "\(UsageFormatter.tokenCountString(thirty.requests)) requests"
        var notes: [String] = [
            todayNote,
            sevenDayNote,
            thirtyDayNote,
        ]
        if let topModel = usage.topModels.first {
            notes.append("Top model: \(topModel.name)")
        }
        return notes
    }

    static func inlineUsageDashboard(input: Input) -> InlineUsageDashboardModel? {
        if let usage = input.snapshot?.openAIAPIUsage {
            return self.openAIAPIInlineDashboard(usage)
        }
        if input.provider == .claude,
           let usage = input.snapshot?.claudeAdminAPIUsage
        {
            return Self.claudeAdminAPIInlineDashboard(usage)
        }
        if input.provider == .openrouter,
           let usage = input.snapshot?.openRouterUsage
        {
            return Self.openRouterInlineDashboard(usage)
        }
        if input.provider == .mistral,
           let usage = input.snapshot?.mistralUsage,
           !usage.daily.isEmpty
        {
            return Self.mistralInlineDashboard(usage)
        }
        if input.provider == .zai,
           let modelUsage = input.snapshot?.zaiUsage?.modelUsage
        {
            return Self.zaiInlineDashboard(modelUsage: modelUsage, now: input.now)
        }
        if input.provider == .minimax,
           input.showOptionalCreditsAndExtraUsage,
           let billing = input.snapshot?.minimaxUsage?.billingSummary,
           !billing.daily.isEmpty
        {
            return Self.minimaxInlineDashboard(billing)
        }
        if [.codex, .claude, .vertexai, .bedrock].contains(input.provider),
           input.tokenCostUsageEnabled,
           let tokenSnapshot = input.tokenSnapshot,
           !tokenSnapshot.daily.isEmpty
        {
            return Self.costHistoryInlineDashboard(provider: input.provider, snapshot: tokenSnapshot)
        }
        return nil
    }

    fileprivate static func openAIAPIInlineDashboard(_ usage: OpenAIAPIUsageSnapshot) -> InlineUsageDashboardModel {
        let today = usage.latestDay
        let last7 = usage.last7Days
        let last30 = usage.last30Days
        let historyLabel = usage.historyWindowLabel
        let points = usage.daily.suffix(usage.historyDays).map {
            InlineUsageDashboardModel.Point(
                id: $0.day,
                label: Self.shortDayLabel($0.day),
                value: $0.costUSD,
                accessibilityValue: "\($0.day): \(UsageFormatter.usdString($0.costUSD))")
        }
        var details = [
            "\(historyLabel): \(UsageFormatter.tokenCountString(last30.totalTokens)) tokens · " +
                "\(UsageFormatter.tokenCountString(last30.requests)) requests",
        ]
        if let topModel = usage.topModels.first {
            details.append("Top model: \(Self.shortModelName(topModel.name))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: "OpenAI API \(usage.historyDays) day spend trend",
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: "Today", value: UsageFormatter.usdString(today.costUSD), emphasis: true),
                .init(title: "7d spend", value: UsageFormatter.usdString(last7.costUSD), emphasis: false),
                .init(
                    title: "\(historyLabel) spend",
                    value: UsageFormatter.usdString(last30.costUSD),
                    emphasis: false),
                .init(title: "Today req", value: UsageFormatter.tokenCountString(today.requests), emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func costHistoryInlineDashboard(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot) -> InlineUsageDashboardModel
    {
        let historyDays = max(1, min(365, snapshot.historyDays))
        let periodLabel = historyDays == 1 ? "today" : "\(historyDays) day"
        let points = snapshot.daily.suffix(historyDays).compactMap { entry -> InlineUsageDashboardModel.Point? in
            guard let cost = entry.costUSD else { return nil }
            return InlineUsageDashboardModel.Point(
                id: entry.date,
                label: Self.shortDayLabel(entry.date),
                value: cost,
                accessibilityValue: "\(entry.date): \(UsageFormatter.usdString(cost))")
        }
        let latest = snapshot.daily.max { lhs, rhs in lhs.date < rhs.date }
        var details: [String] = []
        if let topModel = Self.topCostModel(from: snapshot.daily) {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel))")
        }
        if provider == .bedrock {
            details.append("AWS Cost Explorer billing can lag.")
        } else if provider == .claude {
            details.append(UsageFormatter.costEstimateHint(provider: provider))
        } else {
            details.append(L("cost_estimate_hint"))
        }
        let providerName = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
        return InlineUsageDashboardModel(
            accessibilityLabel: "\(providerName) \(periodLabel) cost trend",
            valueStyle: .currencyUSD,
            kpis: [
                .init(
                    title: provider == .bedrock ? L("Latest") : L("Today"),
                    value: latest?.costUSD.map(UsageFormatter.usdString) ?? "—",
                    emphasis: true),
                .init(
                    title: historyDays == 30
                        ? L("30d cost")
                        : "\(String(format: L("Last %d days"), historyDays)) \(L("Cost"))",
                    value: snapshot.last30DaysCostUSD.map(UsageFormatter.usdString) ?? "—",
                    emphasis: false),
                .init(
                    title: historyDays == 30
                        ? L("30d tokens")
                        : "\(String(format: L("Last %d days"), historyDays)) tokens",
                    value: snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—",
                    emphasis: false),
                .init(
                    title: L("Latest tokens"),
                    value: latest?.totalTokens.map(UsageFormatter.tokenCountString) ?? "—",
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    fileprivate static func claudeAdminAPIInlineDashboard(_ usage: ClaudeAdminAPIUsageSnapshot)
        -> InlineUsageDashboardModel
    {
        let today = usage.latestDay
        let last7 = usage.last7Days
        let last30 = usage.last30Days
        let points = usage.daily.suffix(30).map {
            InlineUsageDashboardModel.Point(
                id: $0.day,
                label: Self.shortDayLabel($0.day),
                value: $0.costUSD,
                accessibilityValue: "\($0.day): \(UsageFormatter.usdString($0.costUSD))")
        }
        var details = [
            "30d: \(UsageFormatter.tokenCountString(last30.totalTokens)) tokens",
            "Cache read: \(UsageFormatter.tokenCountString(last30.cacheReadInputTokens)) tokens",
        ]
        if let topModel = usage.topModels.first {
            details.append("Top model: \(Self.shortModelName(topModel.name))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: "Claude Admin API 30 day spend trend",
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: "Today", value: UsageFormatter.usdString(today.costUSD), emphasis: true),
                .init(title: "7d spend", value: UsageFormatter.usdString(last7.costUSD), emphasis: false),
                .init(
                    title: "30d spend",
                    value: UsageFormatter.usdString(last30.costUSD),
                    emphasis: false),
                .init(
                    title: "Today tokens",
                    value: UsageFormatter.tokenCountString(today.totalTokens),
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func openRouterInlineDashboard(_ usage: OpenRouterUsageSnapshot) -> InlineUsageDashboardModel? {
        let periodValues: [(String, String, Double?)] = [
            ("day", "Today", usage.keyUsageDaily),
            ("week", "Week", usage.keyUsageWeekly),
            ("month", "Month", usage.keyUsageMonthly),
        ]
        let points = periodValues.compactMap { id, label, value -> InlineUsageDashboardModel.Point? in
            guard let value else { return nil }
            return InlineUsageDashboardModel.Point(
                id: id,
                label: label,
                value: value,
                accessibilityValue: "\(label): \(Self.openRouterCurrencyString(value))")
        }
        guard !points.isEmpty else { return nil }
        var details: [String] = []
        if let rate = usage.rateLimit {
            details.append("Rate limit: \(rate.requests) / \(rate.interval)")
        }
        switch usage.keyQuotaStatus {
        case .available:
            if let remaining = usage.keyRemaining {
                details.append("Key remaining: \(Self.openRouterCurrencyString(remaining))")
            }
        case .noLimitConfigured:
            details.append("No limit set for the API key")
        case .unavailable:
            details.append("API key limit unavailable right now")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: "OpenRouter API key spend trend",
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: "Balance", value: Self.openRouterCurrencyString(usage.balance), emphasis: true),
                .init(
                    title: "Today",
                    value: usage.keyUsageDaily.map(Self.openRouterCurrencyString) ?? "—",
                    emphasis: false),
                .init(
                    title: "Week",
                    value: usage.keyUsageWeekly.map(Self.openRouterCurrencyString) ?? "—",
                    emphasis: false),
                .init(
                    title: "Month",
                    value: usage.keyUsageMonthly.map(Self.openRouterCurrencyString) ?? "—",
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func mistralInlineDashboard(_ usage: MistralUsageSnapshot) -> InlineUsageDashboardModel {
        let points = usage.daily.suffix(30).map {
            InlineUsageDashboardModel.Point(
                id: $0.day,
                label: Self.shortDayLabel($0.day),
                value: $0.cost,
                accessibilityValue: "\($0.day): \(Self.mistralCurrencyString($0.cost, symbol: usage.currencySymbol))")
        }
        let latest = usage.daily.last
        let totalTokens = usage.totalInputTokens + usage.totalCachedTokens + usage.totalOutputTokens
        var details = ["This month: \(UsageFormatter.tokenCountString(totalTokens)) tokens"]
        if let topModel = Self.topMistralModel(from: usage.daily) {
            details.append("Top model: \(Self.shortModelName(topModel))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: "Mistral API spend trend",
            valueStyle: .currency(symbol: usage.currencySymbol),
            kpis: [
                .init(
                    title: "Latest",
                    value: latest.map { Self.mistralCurrencyString($0.cost, symbol: usage.currencySymbol) } ?? "—",
                    emphasis: true),
                .init(
                    title: "Month",
                    value: Self.mistralCurrencyString(usage.totalCost, symbol: usage.currencySymbol),
                    emphasis: false),
                .init(title: "Models", value: "\(usage.modelCount)", emphasis: false),
                .init(
                    title: "Latest tokens",
                    value: latest.map { UsageFormatter.tokenCountString($0.totalTokens) } ?? "—",
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func zaiInlineDashboard(modelUsage: ZaiModelUsageData, now: Date) -> InlineUsageDashboardModel? {
        let bars = ZaiHourlyBars.from(modelData: modelUsage, range: .last24h, now: now)
        guard !bars.isEmpty else { return nil }
        let total = bars.reduce(0) { $0 + $1.totalTokens }
        let latest = bars.last
        let peak = bars.max { $0.totalTokens < $1.totalTokens }
        let points = bars.enumerated().map { index, bar in
            InlineUsageDashboardModel.Point(
                id: "\(index)-\(bar.label)",
                label: bar.label,
                value: Double(bar.totalTokens),
                accessibilityValue: "\(bar.label): \(UsageFormatter.tokenCountString(bar.totalTokens)) tokens")
        }
        let topModel = Self.topZaiModel(from: bars)
        return InlineUsageDashboardModel(
            accessibilityLabel: "z.ai hourly token trend",
            valueStyle: .tokens,
            kpis: [
                .init(title: "24h tokens", value: UsageFormatter.tokenCountString(total), emphasis: true),
                .init(
                    title: "Latest hour",
                    value: latest.map { UsageFormatter.tokenCountString($0.totalTokens) } ?? "—",
                    emphasis: false),
                .init(
                    title: "Peak hour",
                    value: peak.map { UsageFormatter.tokenCountString($0.totalTokens) } ?? "—",
                    emphasis: false),
                .init(title: "Models", value: "\(modelUsage.modelNames.count)", emphasis: false),
            ],
            points: points,
            detailLines: topModel.map { ["Top model: \(Self.shortModelName($0))"] } ?? [])
    }

    private static func minimaxInlineDashboard(_ billing: MiniMaxBillingSummary) -> InlineUsageDashboardModel {
        let points = billing.daily.suffix(30).map {
            InlineUsageDashboardModel.Point(
                id: $0.day,
                label: Self.shortDayLabel($0.day),
                value: Double($0.tokens),
                accessibilityValue: "\($0.day): \(UsageFormatter.tokenCountString($0.tokens)) tokens")
        }
        var details = ["30d billing history from MiniMax web session"]
        if let topModel = billing.topModels.first {
            details.append("Top model: \(Self.shortModelName(topModel.name))")
        }
        if let topMethod = billing.topMethods.first {
            details.append("Top method: \(Self.shortModelName(topMethod.name))")
        }
        if let cash = billing.last30DaysCash {
            details.append("30d cash: \(Self.minimaxCashString(cash))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: "MiniMax 30 day token usage trend",
            valueStyle: .tokens,
            kpis: [
                .init(
                    title: "Today",
                    value: UsageFormatter.tokenCountString(billing.todayTokens),
                    emphasis: true),
                .init(
                    title: "30d tokens",
                    value: UsageFormatter.tokenCountString(billing.last30DaysTokens),
                    emphasis: false),
                .init(
                    title: "Today cash",
                    value: billing.todayCash.map(Self.minimaxCashString) ?? "—",
                    emphasis: false),
                .init(
                    title: "Models",
                    value: "\(billing.topModels.count)",
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func topMistralModel(from entries: [MistralDailyUsageBucket]) -> String? {
        var tokens: [String: Int] = [:]
        for entry in entries {
            for model in entry.models {
                tokens[model.name, default: 0] += model.totalTokens
            }
        }
        return tokens.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }?.key
    }

    private static func topZaiModel(from bars: [ZaiHourlyBar]) -> String? {
        var tokens: [String: Int] = [:]
        for bar in bars {
            for segment in bar.segments {
                tokens[segment.model, default: 0] += segment.tokens
            }
        }
        return tokens.max {
            if $0.value == $1.value { return $0.key > $1.key }
            return $0.value < $1.value
        }?.key
    }

    private static func mistralCurrencyString(_ value: Double, symbol: String) -> String {
        "\(symbol)\(String(format: "%.4f", max(0, value)))"
    }

    private static func openRouterCurrencyString(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func minimaxCashString(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    private static func shortDayLabel(_ day: String) -> String {
        let pieces = day.split(separator: "-")
        guard pieces.count == 3, let rawDay = Int(pieces[2]) else { return day }
        return "\(rawDay)"
    }

    private static func shortModelName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > 26 else { return trimmed }
        return String(trimmed.prefix(25)) + "…"
    }

    private static func topCostModel(from entries: [CostUsageDailyReport.Entry]) -> String? {
        var scores: [String: (cost: Double, tokens: Int)] = [:]
        for entry in entries {
            for model in entry.modelBreakdowns ?? [] {
                var score = scores[model.modelName] ?? (0, 0)
                score.cost += model.costUSD ?? 0
                score.tokens += model.totalTokens ?? 0
                scores[model.modelName] = score
            }
        }
        return scores.max {
            if $0.value.cost == $1.value.cost { return $0.value.tokens < $1.value.tokens }
            return $0.value.cost < $1.value.cost
        }?.key
    }
}

struct InlineUsageDashboardContent: View {
    private let model: InlineUsageDashboardModel
    @Environment(\.menuItemHighlighted) private var isHighlighted

    init(snapshot: OpenAIAPIUsageSnapshot) {
        self.model = UsageMenuCardView.Model.openAIAPIInlineDashboard(snapshot)
    }

    init(model: InlineUsageDashboardModel) {
        self.model = model
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            self.kpis
            MiniUsageBars(model: self.model)
                .frame(height: 58)
                .accessibilityLabel(self.model.accessibilityLabel)
            self.detailLines
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var kpis: some View {
        LazyVGrid(
            columns: [
                GridItem(.flexible(minimum: 118), alignment: .leading),
                GridItem(.flexible(minimum: 100), alignment: .leading),
            ],
            alignment: .leading,
            spacing: 6)
        {
            ForEach(Array(self.model.kpis.enumerated()), id: \.offset) { _, kpi in
                KPIBlock(title: kpi.title, value: kpi.value, emphasis: kpi.emphasis)
            }
        }
    }

    private var detailLines: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(self.model.detailLines.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
            }
        }
    }

    private struct KPIBlock: View {
        let title: String
        let value: String
        let emphasis: Bool
        @Environment(\.menuItemHighlighted) private var isHighlighted

        var body: some View {
            VStack(alignment: .leading, spacing: 1) {
                Text(self.title)
                    .font(.caption2)
                    .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                    .lineLimit(1)
                Text(self.value)
                    .font(self.emphasis ? .headline : .subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                    .lineLimit(1)
                    .minimumScaleFactor(0.72)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private struct MiniUsageBars: View {
        let model: InlineUsageDashboardModel
        @Environment(\.menuItemHighlighted) private var isHighlighted

        var body: some View {
            let maxValue = max(self.model.points.map(\.value).max() ?? 0, 1)
            HStack(alignment: .bottom, spacing: 2) {
                ForEach(self.model.points) { point in
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(self.fill(for: point, maxValue: maxValue))
                        .frame(maxWidth: .infinity)
                        .frame(height: self.height(for: point, maxValue: maxValue))
                        .accessibilityLabel(point.accessibilityValue)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
            .overlay(alignment: .bottomLeading) {
                Rectangle()
                    .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                    .frame(height: 1)
            }
        }

        private func height(for point: InlineUsageDashboardModel.Point, maxValue: Double) -> CGFloat {
            let ratio = point.value / maxValue
            guard ratio > 0 else { return 1 }
            return CGFloat(max(3, min(58, ratio * 58)))
        }

        private func fill(for point: InlineUsageDashboardModel.Point, maxValue: Double) -> Color {
            let ratio = max(0.18, min(1, point.value / maxValue))
            if self.isHighlighted {
                return Color.white.opacity(0.55 + ratio * 0.35)
            }
            switch self.model.valueStyle {
            case .currencyUSD, .currency:
                return Color(red: 0.81, green: 0.56, blue: 0.24).opacity(0.42 + ratio * 0.58)
            case .tokens:
                return Color(red: 0.48, green: 0.41, blue: 0.86).opacity(0.42 + ratio * 0.58)
            }
        }
    }
}
