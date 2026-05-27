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
                String(format: L("Today: %@ tokens"), UsageFormatter.tokenCountString(billing.todayTokens)),
                String(
                    format: L("Last 30 days: %@ tokens"),
                    UsageFormatter.tokenCountString(billing.last30DaysTokens)),
            ]
        }

        if input.provider == .deepseek,
           input.showOptionalCreditsAndExtraUsage,
           let usage = input.snapshot?.deepseekUsage
        {
            let symbol = usage.currency == "CNY" ? "¥" : "$"
            let todayCostStr = usage.todayCost.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
            return [
                String(
                    format: L("Today: %@ · %@ tokens"),
                    todayCostStr,
                    UsageFormatter.tokenCountString(usage.todayTokens)),
                String(format: L("This month: %@ tokens"), UsageFormatter.tokenCountString(usage.currentMonthTokens)),
            ]
        }

        if input.provider == .ollama,
           input.snapshot?.identity?.loginMethod == "API key"
        {
            return [L("API key verified. Ollama does not expose Cloud quota limits through the API.")]
        }

        return nil
    }

    static func openAIAPIUsageNotes(_ usage: OpenAIAPIUsageSnapshot) -> [String] {
        let today = usage.latestDay
        let seven = usage.last7Days
        let thirty = usage.last30Days
        let historyLabel = usage.historyWindowLabel
        let todayNote = String(
            format: L("Today: %@ · %@ tokens"),
            UsageFormatter.usdString(today.costUSD),
            UsageFormatter.tokenCountString(today.totalTokens))
        let sevenDayNote = "7d: \(UsageFormatter.usdString(seven.costUSD)) · " +
            "\(UsageFormatter.tokenCountString(seven.requests)) \(L("requests"))"
        let thirtyDayNote =
            "\(historyLabel): \(UsageFormatter.tokenCountString(thirty.totalTokens)) \(L("tokens")) · " +
            "\(UsageFormatter.tokenCountString(thirty.requests)) \(L("requests"))"
        var notes: [String] = [
            todayNote,
            sevenDayNote,
            thirtyDayNote,
        ]
        if let topModel = usage.topModels.first {
            notes.append("\(L("Top model")): \(topModel.name)")
        }
        return notes
    }

    static func inlineUsageDashboard(input: Input) -> InlineUsageDashboardModel? {
        if self.usesProviderCostHistoryAsPrimaryDashboard(input.provider),
           let tokenSnapshot = primaryCostHistorySnapshot(input: input),
           !tokenSnapshot.daily.isEmpty
        {
            return self.costHistoryInlineDashboard(provider: input.provider, snapshot: tokenSnapshot)
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
        if input.provider == .deepseek,
           input.showOptionalCreditsAndExtraUsage,
           let usage = input.snapshot?.deepseekUsage,
           !usage.daily.isEmpty
        {
            return Self.deepseekInlineDashboard(usage)
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

    static func usesProviderCostHistoryAsPrimaryDashboard(_ provider: UsageProvider) -> Bool {
        provider == .openai || provider == .mistral
    }

    static func primaryCostHistorySnapshot(input: Input) -> CostUsageTokenSnapshot? {
        switch input.provider {
        case .openai:
            if let projected = input.snapshot?.openAIAPIUsage?.toCostUsageTokenSnapshot() {
                return projected
            }
            return input.snapshot == nil ? input.tokenSnapshot : nil
        case .mistral:
            if let projected = input.snapshot?.mistralUsage?.toCostUsageTokenSnapshot() {
                return projected
            }
            return input.snapshot == nil ? input.tokenSnapshot : nil
        default:
            return input.tokenSnapshot
        }
    }

    private static func costHistoryInlineDashboard(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot) -> InlineUsageDashboardModel
    {
        let historyDays = max(1, min(365, snapshot.historyDays))
        let historyTitle = snapshot.historyLabel
            ?? (historyDays == 1
                ? L("Today")
                : historyDays == 30
                ? L("30d cost")
                : "\(String(format: L("Last %d days"), historyDays)) \(L("Cost"))")
        let tokenHistoryTitle = snapshot.historyLabel.map { "\($0) \(L("tokens"))" }
            ?? (historyDays == 1
                ? L("Today tokens")
                : historyDays == 30
                ? L("30d tokens")
                : String(format: L("%@ tokens"), String(format: L("Last %d days"), historyDays)))
        let requestHistoryTitle = snapshot.historyLabel.map { "\($0) \(L("requests"))" }
            ?? (historyDays == 1
                ? L("Today requests")
                : historyDays == 30
                ? L("30d requests")
                : String(format: L("%@ requests"), String(format: L("Last %d days"), historyDays)))
        let periodLabel = snapshot.historyLabel?.lowercased()
            ?? (historyDays == 1 ? "today" : "\(historyDays) day")
        let points = snapshot.daily.suffix(historyDays).compactMap { entry -> InlineUsageDashboardModel.Point? in
            guard let cost = entry.costUSD else { return nil }
            return InlineUsageDashboardModel.Point(
                id: entry.date,
                label: Self.shortDayLabel(entry.date),
                value: cost,
                accessibilityValue: "\(entry.date): \(Self.costString(cost, currencyCode: snapshot.currencyCode))")
        }
        let latest = snapshot.daily.max { lhs, rhs in lhs.date < rhs.date }
        var details: [String] = []
        if let topModel = Self.topCostModel(from: snapshot.daily) {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel))")
        }
        if let requestCount = snapshot.last30DaysRequests {
            details.append("\(requestHistoryTitle): \(UsageFormatter.tokenCountString(requestCount)) \(L("requests"))")
        }
        if let hint = Self.tokenUsageHint(provider: provider) {
            details.append(hint)
        } else {
            details.append(L("cost_estimate_hint"))
        }
        let providerName = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
        return InlineUsageDashboardModel(
            accessibilityLabel: "\(providerName) \(periodLabel) cost trend",
            valueStyle: Self.costValueStyle(currencyCode: snapshot.currencyCode),
            kpis: [
                .init(
                    title: provider == .bedrock || provider == .mistral ? L("Latest") : L("Today"),
                    value: latest?.costUSD.map { Self.costString($0, currencyCode: snapshot.currencyCode) } ?? "—",
                    emphasis: true),
                .init(
                    title: historyTitle,
                    value: snapshot.last30DaysCostUSD
                        .map { Self.costString($0, currencyCode: snapshot.currencyCode) } ?? "—",
                    emphasis: false),
                .init(
                    title: tokenHistoryTitle,
                    value: snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—",
                    emphasis: false),
            ] + Self.costHistoryTrailingKPIs(snapshot: snapshot, latest: latest),
            points: points,
            detailLines: details)
    }

    private static func costHistoryTrailingKPIs(
        snapshot: CostUsageTokenSnapshot,
        latest: CostUsageDailyReport.Entry?)
        -> [InlineUsageDashboardModel.KPI]
    {
        if let requests = snapshot.last30DaysRequests {
            return [
                .init(
                    title: L("Requests"),
                    value: UsageFormatter.tokenCountString(requests),
                    emphasis: false),
            ]
        }
        return [
            .init(
                title: L("Latest tokens"),
                value: latest?.totalTokens.map(UsageFormatter.tokenCountString) ?? "—",
                emphasis: false),
        ]
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
            "30d: \(UsageFormatter.tokenCountString(last30.totalTokens)) \(L("tokens"))",
            "\(L("Cache read")): \(UsageFormatter.tokenCountString(last30.cacheReadInputTokens)) \(L("tokens"))",
        ]
        if let topModel = usage.topModels.first {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel.name))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: L("Claude Admin API 30 day spend trend"),
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: L("Today"), value: UsageFormatter.usdString(today.costUSD), emphasis: true),
                .init(title: L("7d spend"), value: UsageFormatter.usdString(last7.costUSD), emphasis: false),
                .init(
                    title: L("30d spend"),
                    value: UsageFormatter.usdString(last30.costUSD),
                    emphasis: false),
                .init(
                    title: L("Today tokens"),
                    value: UsageFormatter.tokenCountString(today.totalTokens),
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func openRouterInlineDashboard(_ usage: OpenRouterUsageSnapshot) -> InlineUsageDashboardModel? {
        let periodValues: [(String, String, Double?)] = [
            ("day", L("Today"), usage.keyUsageDaily),
            ("week", L("Week"), usage.keyUsageWeekly),
            ("month", L("Month"), usage.keyUsageMonthly),
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
            details.append(String(format: L("Rate limit: %d / %@"), rate.requests, rate.interval))
        }
        switch usage.keyQuotaStatus {
        case .available:
            if let remaining = usage.keyRemaining {
                details.append("\(L("Key remaining")): \(Self.openRouterCurrencyString(remaining))")
            }
        case .noLimitConfigured:
            details.append(L("No limit set for the API key"))
        case .unavailable:
            details.append(L("API key limit unavailable right now"))
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: L("OpenRouter API key spend trend"),
            valueStyle: .currencyUSD,
            kpis: [
                .init(title: L("Balance"), value: Self.openRouterCurrencyString(usage.balance), emphasis: true),
                .init(
                    title: L("Today"),
                    value: usage.keyUsageDaily.map(Self.openRouterCurrencyString) ?? "—",
                    emphasis: false),
                .init(
                    title: L("Week"),
                    value: usage.keyUsageWeekly.map(Self.openRouterCurrencyString) ?? "—",
                    emphasis: false),
                .init(
                    title: L("Month"),
                    value: usage.keyUsageMonthly.map(Self.openRouterCurrencyString) ?? "—",
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
                accessibilityValue: "\(bar.label): \(UsageFormatter.tokenCountString(bar.totalTokens)) \(L("tokens"))")
        }
        let topModel = Self.topZaiModel(from: bars)
        return InlineUsageDashboardModel(
            accessibilityLabel: L("z.ai hourly token trend"),
            valueStyle: .tokens,
            kpis: [
                .init(title: L("24h tokens"), value: UsageFormatter.tokenCountString(total), emphasis: true),
                .init(
                    title: L("Latest hour"),
                    value: latest.map { UsageFormatter.tokenCountString($0.totalTokens) } ?? "—",
                    emphasis: false),
                .init(
                    title: L("Peak hour"),
                    value: peak.map { UsageFormatter.tokenCountString($0.totalTokens) } ?? "—",
                    emphasis: false),
                .init(title: L("Models"), value: "\(modelUsage.modelNames.count)", emphasis: false),
            ],
            points: points,
            detailLines: topModel.map { ["\(L("Top model")): \(Self.shortModelName($0))"] } ?? [])
    }

    private static func minimaxInlineDashboard(_ billing: MiniMaxBillingSummary) -> InlineUsageDashboardModel {
        let points = billing.daily.suffix(30).map {
            InlineUsageDashboardModel.Point(
                id: $0.day,
                label: Self.shortDayLabel($0.day),
                value: Double($0.tokens),
                accessibilityValue: "\($0.day): \(UsageFormatter.tokenCountString($0.tokens)) \(L("tokens"))")
        }
        var details = [L("30d billing history from MiniMax web session")]
        if let topModel = billing.topModels.first {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel.name))")
        }
        if let topMethod = billing.topMethods.first {
            details.append("\(L("Top method")): \(Self.shortModelName(topMethod.name))")
        }
        if let cash = billing.last30DaysCash {
            details.append("\(L("30d cash")): \(Self.minimaxCashString(cash))")
        }
        return InlineUsageDashboardModel(
            accessibilityLabel: L("MiniMax 30 day token usage trend"),
            valueStyle: .tokens,
            kpis: [
                .init(
                    title: L("Today"),
                    value: UsageFormatter.tokenCountString(billing.todayTokens),
                    emphasis: true),
                .init(
                    title: L("30d tokens"),
                    value: UsageFormatter.tokenCountString(billing.last30DaysTokens),
                    emphasis: false),
                .init(
                    title: L("Today cash"),
                    value: billing.todayCash.map(Self.minimaxCashString) ?? "—",
                    emphasis: false),
                .init(
                    title: L("Models"),
                    value: "\(billing.topModels.count)",
                    emphasis: false),
            ],
            points: points,
            detailLines: details)
    }

    private static func deepseekInlineDashboard(_ usage: DeepSeekUsageSummary) -> InlineUsageDashboardModel {
        let symbol = usage.currency == "CNY" ? "¥" : "$"
        let points = usage.daily.suffix(30).map {
            InlineUsageDashboardModel.Point(
                id: $0.date,
                label: Self.shortDayLabel($0.date),
                value: Double($0.totalTokens),
                accessibilityValue: "\($0.date): \(UsageFormatter.tokenCountString($0.totalTokens)) \(L("tokens"))")
        }
        var details: [String] = []
        if let topModel = usage.topModel {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel))")
        }
        if let cacheHit = usage.categoryBreakdown.first(where: { $0.category == .promptCacheHitToken }) {
            details.append("\(L("cache-hit input")): \(UsageFormatter.tokenCountString(cacheHit.tokens))")
        }
        if let cacheMiss = usage.categoryBreakdown.first(where: { $0.category == .promptCacheMissToken }) {
            details.append("\(L("cache-miss input")): \(UsageFormatter.tokenCountString(cacheMiss.tokens))")
        }
        if let output = usage.categoryBreakdown.first(where: { $0.category == .responseToken }) {
            details.append("\(L("output")): \(UsageFormatter.tokenCountString(output.tokens))")
        }
        details.append("\(L("requests")): \(usage.currentMonthRequestCount)")

        let todayCostStr = usage.todayCost.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
        let monthCostStr = usage.currentMonthCost.map { "\(symbol)\(String(format: "%.4f", max(0, $0)))" } ?? "—"
        let monthTokensStr = UsageFormatter.tokenCountString(usage.currentMonthTokens)

        return InlineUsageDashboardModel(
            accessibilityLabel: L("DeepSeek 30 day token usage trend"),
            valueStyle: .tokens,
            kpis: [
                .init(
                    title: L("Today"),
                    value: "\(todayCostStr) · \(UsageFormatter.tokenCountString(usage.todayTokens))",
                    emphasis: true),
                .init(
                    title: L("This month"),
                    value: "\(monthCostStr) · \(monthTokensStr)",
                    emphasis: false),
                .init(
                    title: L("Models"),
                    value: usage.topModel.map { Self.shortModelName($0) } ?? "—",
                    emphasis: false),
                .init(
                    title: L("Requests"),
                    value: "\(usage.currentMonthRequestCount)",
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

    private static func openRouterCurrencyString(_ value: Double) -> String {
        String(format: "$%.2f", value)
    }

    private static func minimaxCashString(_ value: Double) -> String {
        String(format: "%.2f", max(0, value))
    }

    private static func costString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: currencyCode)
    }

    private static func costValueStyle(currencyCode: String) -> InlineUsageDashboardModel.ValueStyle {
        if currencyCode == "USD" { return .currencyUSD }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: "en_US")
        let symbol = formatter.currencySymbol ?? currencyCode
        return .currency(symbol: symbol)
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
