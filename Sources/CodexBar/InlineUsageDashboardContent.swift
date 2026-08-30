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
        let value: Double?
        let accessibilityValue: String
    }

    enum ValueStyle: Equatable {
        case currencyUSD
        case currency(symbol: String)
        case tokens
        case points
    }

    struct QuotaWindow: Equatable, Identifiable {
        let id: String
        let title: String
        let range: String
        let value: String
    }

    let accessibilityLabel: String
    let valueStyle: ValueStyle
    let kpis: [KPI]
    let points: [Point]
    let detailLines: [String]
    /// Codex/Claude weekly quota windows, newest first. Empty for other cost dashboards.
    var quotaWindows: [QuotaWindow] = []
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
            costSummaryInlineEnabled: input.costSummaryInlineEnabled,
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
        let color = ProviderAccentPalette.color(for: provider)
        return Color(red: color.red, green: color.green, blue: color.blue)
    }

    private static func resolveInlineUsageDashboard(input: Input) -> InlineUsageDashboardModel? {
        let menuCard = ProviderDescriptorRegistry.descriptor(for: input.provider).presentation.menuCard
        if menuCard.usesProviderCostHistoryAsPrimaryDashboard,
           input.costSummaryInlineEnabled,
           let tokenSnapshot = primaryCostHistorySnapshot(input: input),
           !tokenSnapshot.daily.isEmpty
        {
            return self.costHistoryInlineDashboard(
                provider: input.provider,
                snapshot: tokenSnapshot,
                comparisonPeriodsEnabled: input.costComparisonPeriodsEnabled,
                preferredCurrencyCode: input.preferredCurrencyCode,
                calendar: input.costUsageBucketCalendar,
                weeklyWindow: input.snapshot?.secondary,
                observedNextResets: input.observedWeeklyNextResets,
                observedResetInstants: Self.redeemedWeeklyResetInstants(from: input.snapshot),
                now: input.now)
        }
        if menuCard.supportsInlineTokenCostDashboard,
           input.costSummaryInlineEnabled,
           let tokenSnapshot = input.tokenSnapshot,
           !tokenSnapshot.daily.isEmpty || tokenSnapshot.meteredCostUSD != nil
        {
            return Self.costHistoryInlineDashboard(
                provider: input.provider,
                snapshot: tokenSnapshot,
                comparisonPeriodsEnabled: input.costComparisonPeriodsEnabled,
                preferredCurrencyCode: input.preferredCurrencyCode,
                calendar: input.costUsageBucketCalendar,
                weeklyWindow: input.snapshot?.secondary,
                observedNextResets: input.observedWeeklyNextResets,
                observedResetInstants: Self.redeemedWeeklyResetInstants(from: input.snapshot),
                now: input.now)
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

    static func showsQuotaWeekCost(for provider: UsageProvider) -> Bool {
        provider == .codex || provider == .claude
    }

    private static func costHistoryInlineDashboard(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        comparisonPeriodsEnabled: Bool,
        preferredCurrencyCode: String,
        calendar: Calendar,
        weeklyWindow: RateWindow?,
        observedNextResets: [Date] = [],
        observedResetInstants: [Date] = [],
        now: Date? = nil) -> InlineUsageDashboardModel
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
        let points = Self.inlineCostHistoryDays(
            snapshot: snapshot,
            historyDays: historyDays,
            preservesCalendarDays: tokenCost.preservesCalendarDaysInCharts,
            calendar: calendar)
            .map { day in
                InlineUsageDashboardModel.Point(
                    id: day.date,
                    label: Self.shortDayLabel(day.date),
                    value: day.costUSD.map(convertedValue),
                    accessibilityValue: "\(day.date): \(day.costUSD.map(convertedString) ?? L("Unknown"))")
            }
        let latest = CostUsageTokenSnapshot.latestEntry(in: snapshot.daily)
        let usesLatestPrimary = tokenCost.primaryValue == .latestDaily
        let primaryCostUSD = usesLatestPrimary ? latest?.costUSD : snapshot.sessionCostUSD
        let quotaWeeks = Self.showsQuotaWeekCost(for: provider) && historyDays >= 7
            ? snapshot.quotaWeekSummaries(
                resetAt: CostUsageTokenSnapshot.quotaWeekReset(from: weeklyWindow),
                windowMinutes: weeklyWindow?.windowMinutes,
                observedNextResets: observedNextResets,
                observedResetInstants: observedResetInstants,
                now: now,
                calendar: calendar)
            : []
        let currentWeek = quotaWeeks.first { $0.isCurrent }
        let insertWeekKPIs = currentWeek != nil && historyDays > 7 && snapshot.last30DaysRequests == nil
        let relabelHistoryAsWeek = currentWeek != nil && historyDays == 7 && snapshot.last30DaysRequests == nil
        let weekCostTitle = L("This week")
        let weekTokenTitle = L("%@ tokens", L("This week"))
        let weekCostValue = currentWeek?.totalCostUSD.map(convertedString) ?? "—"
        let weekTokenValue = currentWeek?.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"

        let quotaWindowRows: [InlineUsageDashboardModel.QuotaWindow] = quotaWeeks.compactMap { week in
            guard week.isCurrent || week.entryCount > 0 else { return nil }
            let cost = week.totalCostUSD.map(convertedString) ?? "—"
            return Self.quotaWindowRow(week: week, cost: cost, calendar: calendar)
        }
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
            accessibilityCostLabel)
        let todayKPI = InlineUsageDashboardModel.KPI(
            title: usesLatestPrimary ? L("Latest") : L("Today"),
            value: primaryCostUSD.map(convertedString) ?? "—",
            emphasis: true)
        let historyCostKPI = InlineUsageDashboardModel.KPI(
            title: relabelHistoryAsWeek ? weekCostTitle : historyTitle,
            value: relabelHistoryAsWeek
                ? weekCostValue
                : snapshot.last30DaysCostUSD.map(convertedString) ?? "—",
            emphasis: relabelHistoryAsWeek)
        let tokenHistoryKPI = InlineUsageDashboardModel.KPI(
            title: relabelHistoryAsWeek ? weekTokenTitle : tokenHistoryTitle,
            value: relabelHistoryAsWeek
                ? weekTokenValue
                : snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—",
            emphasis: false)
        let trailingKPIs = Self.costHistoryTrailingKPIs(snapshot: snapshot, latest: latest)
        var kpis: [InlineUsageDashboardModel.KPI]
        if insertWeekKPIs, let latestTokensKPI = trailingKPIs.first {
            kpis = [
                todayKPI,
                .init(title: weekCostTitle, value: weekCostValue, emphasis: true),
                latestTokensKPI,
                .init(title: weekTokenTitle, value: weekTokenValue, emphasis: false),
                historyCostKPI,
                tokenHistoryKPI,
            ]
        } else {
            kpis = [todayKPI, historyCostKPI]
            if snapshot.last30DaysRequests == nil {
                kpis.append(contentsOf: trailingKPIs)
                kpis.append(tokenHistoryKPI)
            } else {
                kpis.append(tokenHistoryKPI)
                kpis.append(contentsOf: trailingKPIs)
            }
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
            valueStyle: Self.costValueStyle(currencyCode: displayCurrencyCode),
            kpis: kpis,
            points: points,
            detailLines: details)
        model.quotaWindows = quotaWindowRows
        model.currencyCode = displayCurrencyCode
        return model
    }

    private static func redeemedWeeklyResetInstants(from snapshot: UsageSnapshot?) -> [Date] {
        snapshot?.codexResetCredits?.credits.compactMap { credit in
            guard credit.status == .redeemed else { return nil }
            return credit.redeemedAt
        } ?? []
    }

    private static func quotaWindowRow(
        week: CostUsageQuotaWeek,
        cost: String,
        calendar: Calendar) -> InlineUsageDashboardModel.QuotaWindow
    {
        let value: String = if let totalTokens = week.totalTokens {
            "\(cost) · \(UsageFormatter.tokenCountString(totalTokens))"
        } else {
            cost
        }
        return InlineUsageDashboardModel.QuotaWindow(
            id: "\(week.offset)-\(Int(week.start.timeIntervalSince1970))",
            title: Self.quotaWeekHistoryLabel(week: week),
            range: Self.quotaWindowRangeLabel(start: week.start, end: week.end, calendar: calendar),
            value: value)
    }

    static func quotaWindowRangeLabel(
        start: Date,
        end: Date,
        calendar: Calendar,
        locale: Locale = codexBarLocalizedResourceLocale()) -> String
    {
        let startDay = calendar.dateComponents([.year, .month, .day], from: start)
        let endDay = calendar.dateComponents([.year, .month, .day], from: end)
        let sameDay = startDay.year == endDay.year
            && startDay.month == endDay.month
            && startDay.day == endDay.day
        let sameYear = startDay.year == endDay.year
        func formatter(template: String) -> DateFormatter {
            let formatter = DateFormatter()
            formatter.locale = locale
            formatter.calendar = calendar
            formatter.timeZone = calendar.timeZone
            formatter.setLocalizedDateFormatFromTemplate(template)
            return formatter
        }
        if sameDay {
            let startText = formatter(template: "MMMdjmm").string(from: start)
            let endText = formatter(template: "jmm").string(from: end)
            return "\(startText) – \(endText)"
        }
        let template = sameYear ? "MMMdjmm" : "yMMMdjmm"
        let rangeFormatter = formatter(template: template)
        return "\(rangeFormatter.string(from: start)) – \(rangeFormatter.string(from: end))"
    }

    private static func quotaWeekHistoryLabel(week: CostUsageQuotaWeek) -> String {
        switch week.offset {
        case 0:
            return L("This week")
        case 1:
            return week.isNominalWeek ? L("Last week") : L("Previous window")
        default:
            return week.isNominalWeek
                ? L("%d weeks ago", week.offset)
                : L("%d windows ago", week.offset)
        }
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

    private static func inlineCostHistoryDays(
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        preservesCalendarDays: Bool,
        calendar sourceCalendar: Calendar)
        -> [(date: String, costUSD: Double?)]
    {
        let existingDays = snapshot.daily.suffix(historyDays).compactMap { entry -> (String, Double?)? in
            guard let cost = entry.costUSD else { return nil }
            return (entry.date, cost)
        }
        guard preservesCalendarDays else { return existingDays }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = sourceCalendar.timeZone
        let endDate = calendar.startOfDay(for: snapshot.updatedAt)
        guard let startDate = calendar.date(byAdding: .day, value: -(historyDays - 1), to: endDate) else {
            return existingDays
        }

        let entriesByDay = Dictionary(snapshot.daily.map { ($0.date, $0) }, uniquingKeysWith: { _, newer in newer })
        return (0..<historyDays).compactMap { offset in
            guard let date = calendar.date(byAdding: .day, value: offset, to: startDate) else { return nil }
            let dayKey = Self.inlineCostHistoryDayKey(date, calendar: calendar)
            if let entry = entriesByDay[dayKey] {
                return (date: dayKey, costUSD: entry.costUSD)
            }
            // A missing date is zero only after the scan has covered the requested history.
            return (date: dayKey, costUSD: snapshot.historyCoverageIsEstablished ? 0 : nil)
        }
    }

    private static func inlineCostHistoryDayKey(_ date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        return String(
            format: "%04d-%02d-%02d",
            components.year ?? 0,
            components.month ?? 0,
            components.day ?? 0)
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
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel(self.model.accessibilityLabel)
            }
            if !self.model.quotaWindows.isEmpty {
                self.quotaWindows
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

    private var quotaWindows: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(L("Recent windows"))
                .font(.caption2)
                .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
            ForEach(self.model.quotaWindows) { window in
                VStack(alignment: .leading, spacing: 1) {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(window.title)
                            .font(.caption)
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(window.value)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(MenuHighlightStyle.primary(self.isHighlighted))
                            .lineLimit(1)
                            .minimumScaleFactor(0.8)
                            .monospacedDigit()
                    }
                    Text(window.range)
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .accessibilityElement(children: .combine)
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
            let scale = UsageChartScale(values: self.model.points.compactMap(\.value))
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
                    let layout = InlineUsageBarLayout(width: geometry.size.width, count: self.model.points.count)
                    HStack(alignment: .bottom, spacing: layout.spacing) {
                        ForEach(self.model.points) { point in
                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                .fill(self.fill(for: point, scale: scale))
                                .frame(width: layout.barWidth)
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
            guard let value = point.value else { return 1 }
            let ratio = scale.fraction(for: value)
            guard ratio > 0 else { return 1 }
            return max(3, CGFloat(ratio) * available)
        }

        private func fill(for point: InlineUsageDashboardModel.Point, scale: UsageChartScale) -> Color {
            guard let value = point.value else { return .clear }
            let ratio = max(0.18, scale.fraction(for: value))
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

struct InlineUsageBarLayout {
    let spacing: CGFloat
    let barWidth: CGFloat

    init(width: CGFloat, count: Int) {
        let count = max(1, count)
        let width = max(0, width)
        self.spacing = count == 1 ? 0 : min(2, width / CGFloat(count) / 4)
        self.barWidth = max(0, (width - self.spacing * CGFloat(count - 1)) / CGFloat(count))
    }
}
