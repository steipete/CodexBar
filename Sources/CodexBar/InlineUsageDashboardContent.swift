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
        case points
    }

    let accessibilityLabel: String
    let valueStyle: ValueStyle
    let kpis: [KPI]
    let points: [Point]
    let detailLines: [String]
    /// Provider branding color used to fill the mini usage bars. When nil the bars fall back to a
    /// neutral palette derived from `valueStyle`.
    var barColor: Color?
    /// ISO 4217 currency code for cost dashboards. When non-nil, `MiniUsageBars` shows a max-cost scale label.
    /// Nil for token/points dashboards.
    var currencyCode: String?
}

extension UsageMenuCardView.Model {
    static func apiProviderUsageNotes(input: Input) -> [String]? {
        let menuCard = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        switch menuCard.usageNotes(context: ProviderUsageNotesContext(
            snapshot: input.snapshot,
            isRefreshing: input.isRefreshing,
            tokenCostInlineDashboardEnabled: input.tokenCostInlineDashboardEnabled,
            showOptionalUsage: input.showOptionalCreditsAndExtraUsage))
        {
        case let .openAIAPI(usage):
            return self.openAIAPIUsageNotes(usage)
        case let .localized(keys):
            return keys.map { L($0) }
        case .unhandled:
            return nil
        }
    }

    static func openAIAPIUsageNotes(_ usage: OpenAIAPIUsageSnapshot) -> [String] {
        let today = usage.currentDay
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
        guard var model = self.resolveInlineUsageDashboard(input: input) else { return nil }
        model.barColor = Self.inlineDashboardBarColor(for: input.provider)
        return model
    }

    /// Provider branding color for the inline usage bars, matching the provider's switcher tab and
    /// detailed cost-history chart.
    static func inlineDashboardBarColor(for provider: UsageProvider) -> Color {
        // Grok cost/token history uses Codex teal so it matches Credits/Codex charts.
        if provider == .grok {
            return self.codexStyleChartBarColor
        }
        let color = ProviderDescriptorRegistry.descriptor(for: provider).branding.color
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    /// Codex brand teal — shared cost-chart palette (matches Credits/Codex cost bars).
    static let codexStyleChartBarColor = Color(red: 73 / 255, green: 163 / 255, blue: 176 / 255)

    private static func resolveInlineUsageDashboard(input: Input) -> InlineUsageDashboardModel? {
        let menuCard = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        if menuCard.usesProviderCostHistoryAsPrimaryDashboard,
           let tokenSnapshot = primaryCostHistorySnapshot(input: input),
           !tokenSnapshot.daily.isEmpty
        {
            return self.costHistoryInlineDashboard(
                provider: input.provider,
                snapshot: tokenSnapshot,
                comparisonPeriodsEnabled: input.costComparisonPeriodsEnabled,
                preferredCurrencyCode: input.preferredCurrencyCode)
        }
        if menuCard.supportsInlineTokenCostDashboard,
           input.tokenCostInlineDashboardEnabled,
           let tokenSnapshot = input.tokenSnapshot,
           !tokenSnapshot.daily.isEmpty || tokenSnapshot.meteredCostUSD != nil
        {
            return Self.costHistoryInlineDashboard(
                provider: input.provider,
                snapshot: tokenSnapshot,
                comparisonPeriodsEnabled: input.costComparisonPeriodsEnabled,
                preferredCurrencyCode: input.preferredCurrencyCode)
        }
        return nil
    }

    static func usesProviderCostHistoryAsPrimaryDashboard(_ provider: UsageProvider) -> Bool {
        ProviderDescriptorRegistry.descriptor(for: provider).presentation.menuCard
            .usesProviderCostHistoryAsPrimaryDashboard
    }

    static func primaryCostHistorySnapshot(input: Input) -> CostUsageTokenSnapshot? {
        ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard.primaryCostHistory(
            snapshot: input.snapshot,
            tokenSnapshot: input.tokenSnapshot)
    }

    private static func costHistoryInlineDashboard(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        comparisonPeriodsEnabled: Bool,
        preferredCurrencyCode: String) -> InlineUsageDashboardModel
    {
        let displayCurrencyCode = UsageFormatter.convertedCost(
            0,
            preferredCurrency: preferredCurrencyCode,
            providerCurrency: snapshot.currencyCode).currencyCode
        func convertedValue(_ value: Double) -> Double {
            UsageFormatter.convertedCost(
                value,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode).value
        }
        func convertedString(_ value: Double) -> String {
            UsageFormatter.convertedCostString(
                value,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode)
        }

        let historyDays = max(1, min(365, snapshot.historyDays))
        let defaultHistoryTitle = snapshot.historyLabel
            ?? (historyDays == 1
                ? L("Today")
                : historyDays == 30
                ? L("30d cost")
                : "\(String(format: L("Last %d days"), historyDays)) \(L("Cost"))")
        let codexHistoryPeriod = snapshot.historyLabel
            ?? (historyDays == 1
                ? L("Today")
                : historyDays == 30
                ? "30d"
                : String(format: L("Last %d days"), historyDays))
        let tokenCost = ProviderDescriptorRegistry.descriptor(for: provider).tokenCost
        let historyTitle = tokenCost.historyTitleStyle == .compact ? codexHistoryPeriod : defaultHistoryTitle
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
        let accessibilityCostLabel: String = if let historyLabel = snapshot.historyLabel {
            L("%@ cost", historyLabel)
        } else if historyDays == 30 {
            L("30d cost")
        } else {
            L("%@ cost", historyDays == 1 ? L("Today") : String(format: L("Last %d days"), historyDays))
        }
        // Grok (and sparse-cost histories) plot daily tokens so subscription days without
        // costUsdTicks still appear. Cost remains in KPIs/details.
        let plotTokens = Self.shouldPlotTokensOnInlineCostChart(provider: provider, snapshot: snapshot)
        let points = Self.inlineChartPoints(
            snapshot: snapshot,
            historyDays: historyDays,
            plotTokens: plotTokens,
            preferredCurrencyCode: preferredCurrencyCode)
        let latest = CostUsageTokenSnapshot.latestEntry(in: snapshot.daily)
        let usesLatestPrimary = tokenCost.primaryValue == .latestDaily
        let primaryCostUSD = usesLatestPrimary ? latest?.costUSD : snapshot.sessionCostUSD
        var details: [String] = []
        if comparisonPeriodsEnabled {
            details.append(contentsOf: snapshot.comparisonSummaries().map {
                let label = Self.costHistoryWindowLabel(days: $0.days)
                let cost = $0.totalCostUSD.map(convertedString) ?? "—"
                guard let totalTokens = $0.totalTokens else { return "\(label): \(cost)" }
                return String(
                    format: L("%@: %@ · %@ tokens"),
                    label,
                    cost,
                    UsageFormatter.tokenCountString(totalTokens))
            })
        }
        if let topModel = Self.topCostModel(from: snapshot.daily) {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel))")
        }
        if provider == .grok {
            details.append(contentsOf: Self.grokCostHistoryDetailLines(snapshot: snapshot))
        }
        if snapshot.historyIsIncomplete {
            details.append(L("History incomplete: some large session logs were only partially scanned."))
        }
        let hintLines = Self.tokenUsageHintLines(provider: provider)
        if tokenCost.hintPlacement == .beforeRequestHistory {
            details.append(contentsOf: hintLines)
        }
        if tokenCost.showsRequestHistory {
            if let requestCount = snapshot.last30DaysRequests {
                details
                    .append("\(requestHistoryTitle): \(UsageFormatter.tokenCountString(requestCount)) \(L("requests"))")
            }
            if tokenCost.hintPlacement == .afterRequestHistory {
                if hintLines.isEmpty == false {
                    details.append(contentsOf: hintLines)
                } else {
                    details.append(L("cost_estimate_hint"))
                }
            }
        }
        let providerName = ProviderDefaults.metadata[provider]?.displayName ?? provider.rawValue
        let accessibilityLabel = L(
            "%@: %@",
            providerName,
            plotTokens
                ? (snapshot.historyLabel.map { "\($0) tokens" } ?? L("token usage"))
                : accessibilityCostLabel)
        var kpis = [
            InlineUsageDashboardModel.KPI(
                title: usesLatestPrimary ? L("Latest") : L("Today"),
                value: primaryCostUSD.map(convertedString) ?? "—",
                emphasis: true),
            .init(
                title: historyTitle,
                value: snapshot.last30DaysCostUSD
                    .map(convertedString) ?? "—",
                emphasis: false),
        ]
        if provider == .grok {
            let todayTokens = snapshot.sessionTokens.map(UsageFormatter.tokenCountString) ?? "—"
            kpis.insert(
                .init(title: L("Today tokens"), value: todayTokens, emphasis: true),
                at: 0)
        }
        let tokenHistoryKPI = InlineUsageDashboardModel.KPI(
            title: tokenHistoryTitle,
            value: snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—",
            emphasis: false)
        let trailingKPIs = Self.costHistoryTrailingKPIs(snapshot: snapshot, latest: latest)
        if snapshot.last30DaysRequests == nil {
            kpis.append(contentsOf: trailingKPIs)
            kpis.append(tokenHistoryKPI)
        } else {
            kpis.append(tokenHistoryKPI)
            kpis.append(contentsOf: trailingKPIs)
        }
        if provider == .cursor, let meteredCostUSD = snapshot.meteredCostUSD {
            kpis.insert(
                .init(
                    title: "Cursor-metered",
                    value: convertedString(meteredCostUSD),
                    emphasis: true),
                at: 0)
        }
        var model = InlineUsageDashboardModel(
            accessibilityLabel: accessibilityLabel,
            valueStyle: plotTokens ? .tokens : Self.costValueStyle(currencyCode: displayCurrencyCode),
            kpis: kpis,
            points: points,
            detailLines: details)
        if provider == .grok {
            model.barColor = self.codexStyleChartBarColor
        }
        if !plotTokens {
            model.currencyCode = displayCurrencyCode
        }
        return model
    }

    private static func grokCostHistoryDetailLines(snapshot: CostUsageTokenSnapshot) -> [String] {
        var details: [String] = []
        let input = snapshot.daily.compactMap(\.inputTokens).reduce(0, +)
        let cache = snapshot.daily.compactMap(\.cacheReadTokens).reduce(0, +)
        let output = snapshot.daily.compactMap(\.outputTokens).reduce(0, +)
        if input + cache + output > 0 {
            details.append(String(
                format: L("Uncached %@ · Cache %@ · Output %@"),
                UsageFormatter.tokenCountString(input),
                UsageFormatter.tokenCountString(cache),
                UsageFormatter.tokenCountString(output)))
        }
        let daysWithCost = snapshot.daily.count(where: { ($0.costUSD ?? 0) > 0 })
        details.append(String(
            format: L("Cost reported on %d/%d days"),
            daysWithCost,
            snapshot.daily.count))
        if let topProject = snapshot.projects.first {
            let tokens = topProject.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
            details.append(String(format: L("Top project: %@ · %@"), topProject.name, tokens))
        }
        return details
    }

    /// Prefer token bars when cost history is incomplete (Grok subscription) or absent.
    static func shouldPlotTokensOnInlineCostChart(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot) -> Bool
    {
        if provider == .grok { return true }
        let days = snapshot.daily
        guard !days.isEmpty else { return false }
        let withCost = days.count(where: { ($0.costUSD ?? 0) > 0 })
        return withCost == 0
    }

    /// Continuous daily points for the main-menu mini chart (zero-fill gaps like Codex).
    static func inlineChartPoints(
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        plotTokens: Bool,
        preferredCurrencyCode: String = "auto") -> [InlineUsageDashboardModel.Point]
    {
        let sorted = snapshot.daily.sorted { $0.date < $1.date }
        guard let lastKey = sorted.last?.date else { return [] }
        guard let end = Self.dateFromDayKey(lastKey) else {
            return sorted.suffix(historyDays).compactMap { entry in
                self.inlinePoint(
                    for: entry,
                    plotTokens: plotTokens,
                    providerCurrencyCode: snapshot.currencyCode,
                    preferredCurrencyCode: preferredCurrencyCode)
            }
        }
        let calendar = Calendar.current
        let start = calendar.date(byAdding: .day, value: -(historyDays - 1), to: calendar.startOfDay(for: end))
            ?? calendar.startOfDay(for: end)
        var byDay: [String: CostUsageDailyReport.Entry] = [:]
        for entry in sorted {
            byDay[entry.date] = entry
        }
        var points: [InlineUsageDashboardModel.Point] = []
        var cursor = calendar.startOfDay(for: start)
        let endDay = calendar.startOfDay(for: end)
        while cursor <= endDay {
            let key = Self.dayKey(from: cursor)
            if let entry = byDay[key],
               let point = self.inlinePoint(
                   for: entry,
                   plotTokens: plotTokens,
                   providerCurrencyCode: snapshot.currencyCode,
                   preferredCurrencyCode: preferredCurrencyCode)
            {
                points.append(point)
            } else {
                points.append(InlineUsageDashboardModel.Point(
                    id: key,
                    label: Self.shortDayLabel(key),
                    value: 0,
                    accessibilityValue: "\(key): —"))
            }
            guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
            cursor = next
        }
        return points
    }

    private static func inlinePoint(
        for entry: CostUsageDailyReport.Entry,
        plotTokens: Bool,
        providerCurrencyCode: String,
        preferredCurrencyCode: String) -> InlineUsageDashboardModel.Point?
    {
        if plotTokens {
            let tokens = entry.totalTokens ?? 0
            let costNote: String = {
                guard let cost = entry.costUSD else { return "" }
                let formatted = UsageFormatter.convertedCostString(
                    cost,
                    preferredCurrency: preferredCurrencyCode,
                    providerCurrency: providerCurrencyCode)
                return " · \(formatted)"
            }()
            return InlineUsageDashboardModel.Point(
                id: entry.date,
                label: Self.shortDayLabel(entry.date),
                value: Double(tokens),
                accessibilityValue: "\(entry.date): \(UsageFormatter.tokenCountString(tokens)) tokens\(costNote)")
        }
        guard let cost = entry.costUSD else { return nil }
        let converted = UsageFormatter.convertedCost(
            cost,
            preferredCurrency: preferredCurrencyCode,
            providerCurrency: providerCurrencyCode)
        let costString = UsageFormatter.convertedCostString(
            cost,
            preferredCurrency: preferredCurrencyCode,
            providerCurrency: providerCurrencyCode)
        return InlineUsageDashboardModel.Point(
            id: entry.date,
            label: Self.shortDayLabel(entry.date),
            value: converted.value,
            accessibilityValue: "\(entry.date): \(costString)")
    }

    private static func dateFromDayKey(_ key: String) -> Date? {
        let parts = key.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2]) else { return nil }
        var comps = DateComponents()
        comps.calendar = Calendar.current
        comps.year = year
        comps.month = month
        comps.day = day
        comps.hour = 12
        return comps.date
    }

    private static func dayKey(from date: Date) -> String {
        let comps = Calendar.current.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", comps.year ?? 1970, comps.month ?? 1, comps.day ?? 1)
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

    private static func topMistralModel(from entries: [MistralDailyUsageBucket]) -> String? {
        var tokens: [String: Int] = [:]
        for entry in entries {
            for model in entry.models {
                tokens[model.name, default: 0] += model.totalTokens
            }
        }
        return tokens.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key
    }

    private static func costString(_ value: Double, currencyCode: String) -> String {
        UsageFormatter.currencyString(value, currencyCode: currencyCode)
    }

    private static func costValueStyle(currencyCode: String) -> InlineUsageDashboardModel.ValueStyle {
        if currencyCode == "USD" {
            return .currencyUSD
        }
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currencyCode
        formatter.locale = Locale(identifier: "en_US")
        let symbol = formatter.currencySymbol ?? currencyCode
        return .currency(symbol: symbol)
    }

    static func shortDayLabel(_ day: String) -> String {
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
            if $0.value.cost == $1.value.cost {
                return $0.value.tokens < $1.value.tokens
            }
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
            if !self.model.points.isEmpty {
                MiniUsageBars(model: self.model)
                    .frame(height: 58)
                    .accessibilityLabel(self.model.accessibilityLabel)
            }
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
            let scale = UsageChartScale(values: self.model.points.map(\.value))
            VStack(alignment: .trailing, spacing: 2) {
                if let currencyCode = self.model.currencyCode, scale.maximum > 0 {
                    Text(UsageFormatter.compactCurrencyString(scale.maximum, currencyCode: currencyCode))
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .monospacedDigit()
                        .lineLimit(1)
                        .allowsTightening(true)
                }
                GeometryReader { geometry in
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(self.model.points) { point in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(self.fill(for: point, scale: scale))
                                .frame(maxWidth: .infinity)
                                .frame(height: self.height(for: point, scale: scale, available: geometry.size.height))
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
            }
        }

        private func height(
            for point: InlineUsageDashboardModel.Point,
            scale: UsageChartScale,
            available: CGFloat) -> CGFloat
        {
            let ratio = scale.fraction(for: point.value)
            guard ratio > 0 else { return 1 }
            return max(3, CGFloat(ratio) * available)
        }

        private func fill(for point: InlineUsageDashboardModel.Point, scale: UsageChartScale) -> Color {
            let ratio = max(0.18, scale.fraction(for: point.value))
            if self.isHighlighted {
                return Color.white.opacity(0.55 + ratio * 0.35)
            }
            return self.baseColor.opacity(0.42 + ratio * 0.58)
        }

        private var baseColor: Color {
            if let barColor = self.model.barColor {
                return barColor
            }
            switch self.model.valueStyle {
            case .currencyUSD, .currency:
                return Color(red: 0.81, green: 0.56, blue: 0.24)
            case .tokens:
                return Color(red: 0.48, green: 0.41, blue: 0.86)
            case .points:
                return Color(red: 0.16, green: 0.62, blue: 0.36)
            }
        }
    }
}
