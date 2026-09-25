import CodexBarCore
import SwiftUI

struct InlineUsageDashboardModel: Equatable {
    struct HoverDetail: Equatable {
        let dateLabel: String
        let cost: Double?
        let tokenCount: Int?
        let currencyCode: String
        var incompleteRequestCount: Int = 0
        var tokensOnly = false

        var summary: String {
            let cost = self.cost.map { UsageFormatter.currencyString($0, currencyCode: self.currencyCode) } ?? "—"
            let tokens = self.tokenCount.map(UsageFormatter.tokenCountString) ?? "—"
            if self.tokensOnly {
                return L("%@: %@", self.dateLabel, L("%@ tokens", tokens))
                    + UsageFormatter.incompleteUsageSuffix(self.incompleteRequestCount)
            }
            return L("%@: %@ · %@ tokens", self.dateLabel, cost, tokens)
                + UsageFormatter.incompleteUsageSuffix(self.incompleteRequestCount)
        }
    }

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
        var hoverDetail: HoverDetail?
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
        var note: String?
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
            return self.costHistoryInlineDashboard(input: input, snapshot: tokenSnapshot)
        }
        if menuCard.supportsInlineTokenCostDashboard,
           input.costSummaryInlineEnabled,
           let tokenSnapshot = input.tokenSnapshot,
           !tokenSnapshot.daily.isEmpty || tokenSnapshot.meteredCostUSD != nil
        {
            return Self.costHistoryInlineDashboard(input: input, snapshot: tokenSnapshot)
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
        self.menuCardPresentation(for: provider).showsQuotaWeekCost
    }

    static func menuCardPresentation(for provider: UsageProvider) -> ProviderMenuCardPresentation {
        ProviderDescriptorRegistry.descriptor(for: provider).presentation.menuCard
    }

    private static func weeklyQuotaWindow(from input: Input) -> RateWindow? {
        guard let snapshot = input.snapshot else { return nil }
        return ProviderDescriptorRegistry.descriptor(for: input.provider)
            .presentation.semanticWindows(snapshot: snapshot).weekly
    }

    private struct CostHistoryQuotaPresentation {
        let rows: [InlineUsageDashboardModel.QuotaWindow]
        let insertsKPIs: Bool
        let relabelsHistory: Bool
        let boundariesAreEstimated: Bool
        let costValue: String
        let tokenValue: String
    }

    private static func costHistoryQuotaPresentation(
        input: Input,
        snapshot: CostUsageTokenSnapshot,
        historyDays: Int,
        convertedString: (Double) -> String) -> CostHistoryQuotaPresentation
    {
        let weeklyWindow = Self.weeklyQuotaWindow(from: input)
        // A provider whose surfaced reset is not one stable account-wide quota cannot derive past
        // boundaries from observed resets: those instants belong to different quotas. Nominal
        // weekly strides from the live reset remain correct, so only the observations are dropped.
        let ignoresObservedResets = Self.menuCardPresentation(for: input.provider)
            .ignoresObservedQuotaResetBoundaries
        var observations = ignoresObservedResets ? [] : input.observedWeeklyResets
        if !ignoresObservedResets,
           let resetAt = CostUsageTokenSnapshot.quotaWeekReset(from: weeklyWindow),
           let capturedAt = input.snapshot?.updatedAt
        {
            observations.append(.init(capturedAt: capturedAt, resetsAt: resetAt))
        }
        let quotaWeeks = Self.showsQuotaWeekCost(for: input.provider) && historyDays >= 7
            ? snapshot.quotaWeekSummaries(
                resetAt: CostUsageTokenSnapshot.quotaWeekReset(from: weeklyWindow),
                windowMinutes: weeklyWindow?.windowMinutes,
                observedResetInstants: ignoresObservedResets
                    ? [] : Self.redeemedWeeklyResetInstants(from: input.snapshot),
                resetObservations: observations,
                now: input.now,
                calendar: input.costUsageBucketCalendar)
            : []
        let currentWeek = quotaWeeks.first { $0.isCurrent }
        let rows = quotaWeeks.compactMap { week -> InlineUsageDashboardModel.QuotaWindow? in
            guard week.isCurrent || week.entryCount > 0 else { return nil }
            return Self.quotaWindowRow(
                week: week,
                cost: week.totalCostUSD.map(convertedString) ?? "—",
                calendar: input.costUsageBucketCalendar)
        }
        return CostHistoryQuotaPresentation(
            rows: rows,
            insertsKPIs: currentWeek != nil && historyDays > 7 && snapshot.last30DaysRequests == nil,
            relabelsHistory: currentWeek != nil && historyDays == 7 && snapshot.last30DaysRequests == nil,
            boundariesAreEstimated: currentWeek?.boundariesAreEstimated == true,
            costValue: Self.quotaMetricValue(
                currentWeek?.totalCostUSD.map(convertedString), complete: currentWeek?.costIsComplete == true),
            tokenValue: Self.quotaMetricValue(
                currentWeek?.totalTokens.map(UsageFormatter.tokenCountString),
                complete: currentWeek?.tokensAreComplete == true))
    }

    private static func costHistoryDetailLines(
        input: Input,
        snapshot: CostUsageTokenSnapshot,
        requestHistoryTitle: String,
        displayCurrencyCode: String) -> [String]
    {
        let incompleteCount = CostUsageIncompleteRequests.sum(snapshot.daily.map(\.incompleteRequestCount))
        let unpricedCount = snapshot.daily.reduce(0) { $0 + max(0, $1.unpricedRequestCount ?? 0) }
        var details: [String] = []
        if input.costComparisonPeriodsEnabled {
            details.append(contentsOf: snapshot.comparisonSummaries(calendar: input.costUsageBucketCalendar).map {
                Self.costWindowLine(
                    summary: $0,
                    currencyCode: displayCurrencyCode,
                    sourceCurrencyCode: snapshot.currencyCode)
            })
        }
        if let coverage = Self.tokenHistoryCoverageHint(snapshot) { details.append(coverage) }
        if unpricedCount > 0 { details.append("\(L("Partial estimate")) · \(L("Unpriced")) \(unpricedCount)") }
        if let note = UsageFormatter.incompleteUsageNote(incompleteCount) { details.append(note) }
        if let topModel = Self.topCostModel(from: snapshot.daily) {
            details.append("\(L("Top model")): \(Self.shortModelName(topModel))")
        }
        let tokenCost = ProviderDescriptorRegistry.descriptor(for: input.provider).tokenCost
        let hintLines = Self.tokenUsageHintLines(provider: input.provider)
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
        return details
    }

    private static func costHistoryInlineDashboard(
        input: Input,
        snapshot: CostUsageTokenSnapshot) -> InlineUsageDashboardModel
    {
        if ProviderDescriptorRegistry.descriptor(for: input.provider).tokenCost.presentation == .tokensOnly {
            return self.tokenHistoryInlineDashboard(
                provider: input.provider,
                snapshot: snapshot,
                comparisonPeriodsEnabled: input.costComparisonPeriodsEnabled,
                calendar: input.costUsageBucketCalendar)
        }
        let displayCurrencyCode = UsageFormatter.convertedCost(
            0,
            preferredCurrency: input.preferredCurrencyCode,
            providerCurrency: snapshot.currencyCode).currencyCode
        func convertedValue(_ value: Double) -> Double {
            UsageFormatter.convertedCost(
                value,
                preferredCurrency: input.preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode).value
        }
        func convertedString(_ value: Double) -> String {
            UsageFormatter.convertedCostString(
                value,
                preferredCurrency: input.preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode)
        }

        let historyDays = snapshot.displayHistoryDays(calendar: input.costUsageBucketCalendar)
        let explicitLabel = snapshot.historyLabel.map { L($0) }
        let period = explicitLabel ?? (historyDays == 1 ? L("Today") : String(format: L("Last %d days"), historyDays))
        let legacyMonth = explicitLabel == nil && historyDays == 30
        let tokenCost = ProviderDescriptorRegistry.descriptor(for: input.provider).tokenCost
        let historyTitle = tokenCost.historyTitleStyle == .compact
            ? (legacyMonth ? "30d" : period)
            :
            (explicitLabel ??
                (legacyMonth ? L("30d cost") : historyDays == 1 ? L("Today") : "\(period) \(L("Cost"))"))
        let tokenHistoryTitle = legacyMonth ? L("30d tokens") : String(format: L("%@ tokens"), period)
        let requestHistoryTitle = legacyMonth ? L("30d requests") : String(format: L("%@ requests"), period)
        let accessibilityCostLabel = legacyMonth ? L("30d cost") : L("%@ cost", period)
        let points = Self.inlineCostHistoryPoints(
            days: Self.inlineCostHistoryDays(
                snapshot: snapshot,
                historyDays: historyDays,
                preservesCalendarDays: tokenCost.preservesCalendarDaysInCharts,
                calendar: input.costUsageBucketCalendar),
            displayCurrencyCode: displayCurrencyCode,
            convertedValue: convertedValue)
        let latest = CostUsageTokenSnapshot.latestEntry(in: snapshot.daily)
        let usesLatestPrimary = tokenCost.primaryValue == .latestDaily
        let primaryCostUSD = usesLatestPrimary ? latest?.costUSD : snapshot.sessionCostUSD
        let incompleteCount = CostUsageIncompleteRequests.sum(snapshot.daily.map(\.incompleteRequestCount))
        let primaryIncompleteCount = usesLatestPrimary ? latest?.incompleteRequestCount ?? 0
            : snapshot.summary(forLastDays: 1, calendar: input.costUsageBucketCalendar).incompleteRequestCount
        let primarySuffix = UsageFormatter.incompleteUsageSuffix(primaryIncompleteCount)
        let historySuffix = UsageFormatter.incompleteUsageSuffix(incompleteCount)
        let quota = Self.costHistoryQuotaPresentation(
            input: input,
            snapshot: snapshot,
            historyDays: historyDays,
            convertedString: convertedString)
        let weekCostTitle = quota.boundariesAreEstimated ? L("Estimated: %@", L("Current window")) : L("Current window")
        let rawTokenTitle = L("%@ tokens", L("Current window"))
        let weekTokenTitle = quota.boundariesAreEstimated ? L("Estimated: %@", rawTokenTitle) : rawTokenTitle
        var details = Self.costHistoryDetailLines(
            input: input,
            snapshot: snapshot,
            requestHistoryTitle: requestHistoryTitle,
            displayCurrencyCode: displayCurrencyCode)
        if !quota.rows.isEmpty, let note = menuCardPresentation(for: input.provider).quotaWindowNote {
            details.append(L(note))
        }
        let providerName = ProviderDefaults.metadata[input.provider]?.displayName ?? input.provider.rawValue
        let accessibilityLabel = L(
            "%@: %@",
            providerName,
            accessibilityCostLabel)
        let todayKPI = InlineUsageDashboardModel.KPI(
            title: usesLatestPrimary ? L("Latest") : L("Today"),
            value: (primaryCostUSD.map(convertedString) ?? "—") + primarySuffix,
            emphasis: true)
        let historyCostKPI = InlineUsageDashboardModel.KPI(
            title: quota.relabelsHistory ? weekCostTitle : historyTitle,
            value: quota.relabelsHistory
                ? quota.costValue
                : (snapshot.last30DaysCostUSD.map(convertedString) ?? "—") + historySuffix,
            emphasis: quota.relabelsHistory)
        let tokenHistoryKPI = InlineUsageDashboardModel.KPI(
            title: quota.relabelsHistory ? weekTokenTitle : tokenHistoryTitle,
            value: quota.relabelsHistory
                ? quota.tokenValue
                : (snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—") + historySuffix,
            emphasis: false)
        let trailingKPIs = Self.costHistoryTrailingKPIs(snapshot: snapshot, latest: latest)
        var kpis: [InlineUsageDashboardModel.KPI]
        if quota.insertsKPIs, let latestTokensKPI = trailingKPIs.first {
            kpis = [
                todayKPI,
                .init(title: weekCostTitle, value: quota.costValue, emphasis: true),
                latestTokensKPI,
                .init(title: weekTokenTitle, value: quota.tokenValue, emphasis: false),
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
        if input.provider == .cursor, let meteredCostUSD = snapshot.meteredCostUSD {
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
        model.quotaWindows = quota.rows
        model.currencyCode = displayCurrencyCode
        return model
    }

    private static func redeemedWeeklyResetInstants(from snapshot: UsageSnapshot?) -> [Date] {
        snapshot?.codexResetCredits?.credits.compactMap { credit in
            guard credit.status == .redeemed else { return nil }
            return credit.redeemedAt
        } ?? []
    }

    static func quotaMetricValue(_ value: String?, complete: Bool) -> String {
        guard let value else { return "—" }
        return complete ? value : "≥ \(value)"
    }

    static func quotaWindowRow(
        week: CostUsageQuotaWeek,
        cost: String,
        calendar: Calendar) -> InlineUsageDashboardModel.QuotaWindow
    {
        let costValue = Self.quotaMetricValue(week.totalCostUSD == nil ? nil : cost, complete: week.costIsComplete)
        let tokenValue = Self.quotaMetricValue(
            week.totalTokens.map(UsageFormatter.tokenCountString), complete: week.tokensAreComplete)
        let value: String = if week.totalTokens != nil {
            "\(costValue) · \(tokenValue)"
        } else {
            costValue
        }
        let range = Self.quotaWindowRangeLabel(start: week.start, end: week.end, calendar: calendar)
        return InlineUsageDashboardModel.QuotaWindow(
            id: "\(week.offset)-\(Int(week.start.timeIntervalSince1970))",
            title: Self.quotaWeekHistoryLabel(week: week),
            range: week.boundariesAreEstimated ? L("Estimated: %@", range) : range,
            value: value,
            note: (!week.costIsComplete && week.totalCostUSD != nil)
                || (!week.tokensAreComplete && week.totalTokens != nil) ? L("Partial estimate") : nil)
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
            L("Current window")
        case 1:
            L("Previous window")
        default:
            L("%d windows ago", week.offset)
        }
    }

    private static func tokenHistoryInlineDashboard(
        provider: UsageProvider,
        snapshot: CostUsageTokenSnapshot,
        comparisonPeriodsEnabled: Bool,
        calendar: Calendar) -> InlineUsageDashboardModel
    {
        let config = ProviderDescriptorRegistry.descriptor(for: provider).tokenCost
        let historyDays = snapshot.displayHistoryDays(calendar: calendar)
        let historyLabel = snapshot.historyLabel.map { L($0) } ?? Self.costHistoryWindowLabel(days: historyDays)
        var kpis = [InlineUsageDashboardModel.KPI(
            title: L("Today"),
            value: L("%@ tokens", snapshot.sessionTokens.map(UsageFormatter.tokenCountString) ?? "—"),
            emphasis: true)]
        if historyDays > 1 {
            kpis.append(.init(
                title: historyLabel,
                value: L("%@ tokens", snapshot.last30DaysTokens.map(UsageFormatter.tokenCountString) ?? "—"),
                emphasis: false))
        }
        var details = Self.tokenUsageHintLines(provider: provider)
        if details.isEmpty { details.append(L("Local token history · dollar costs unavailable")) }
        if let coverage = Self.tokenHistoryCoverageHint(snapshot) { details.append(coverage) }
        if comparisonPeriodsEnabled {
            details.append(contentsOf: snapshot.comparisonSummaries(calendar: calendar).map {
                Self.tokenWindowLine(label: Self.costHistoryWindowLabel(days: $0.days), tokens: $0.totalTokens)
            })
        }
        let points = Self.inlineCostHistoryPoints(
            days: Self.inlineCostHistoryDays(
                snapshot: snapshot,
                historyDays: historyDays,
                preservesCalendarDays: config.preservesCalendarDaysInCharts,
                calendar: calendar),
            displayCurrencyCode: "USD",
            convertedValue: { $0 },
            tokensOnly: true)
        let name = ProviderDescriptorRegistry.descriptor(for: provider).metadata.displayName
        return InlineUsageDashboardModel(
            accessibilityLabel: L("%@: %@", name, L("Token history")),
            valueStyle: .tokens,
            kpis: kpis,
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
                value: (latest?.totalTokens.map(UsageFormatter.tokenCountString) ?? "—")
                    + UsageFormatter.incompleteUsageSuffix(latest?.incompleteRequestCount ?? 0),
                emphasis: false),
        ]
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
        -> [(date: String, costUSD: Double?, totalTokens: Int?, incompleteRequestCount: Int)]
    {
        let existingDays = snapshot.daily.suffix(historyDays)
            .compactMap { entry -> (date: String, costUSD: Double?, totalTokens: Int?, incompleteRequestCount: Int)? in
                guard entry.costUSD != nil || entry.totalTokens != nil || entry.incompleteRequestCount > 0
                else { return nil }
                return (entry.date, entry.costUSD, entry.totalTokens, entry.incompleteRequestCount)
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
                return (
                    date: dayKey,
                    costUSD: entry.costUSD,
                    totalTokens: entry.totalTokens,
                    incompleteRequestCount: entry.incompleteRequestCount)
            }
            // A missing date is zero only after the scan has covered the requested history.
            return (
                date: dayKey,
                costUSD: snapshot.historyIsFullyScanned ? 0 : nil,
                totalTokens: snapshot.historyIsFullyScanned ? 0 : nil,
                incompleteRequestCount: 0)
        }
    }

    private static func inlineCostHistoryPoints(
        days: [(date: String, costUSD: Double?, totalTokens: Int?, incompleteRequestCount: Int)],
        displayCurrencyCode: String,
        convertedValue: (Double) -> Double,
        tokensOnly: Bool = false) -> [InlineUsageDashboardModel.Point]
    {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.timeZone = TimeZone(secondsFromGMT: 0)
        parser.dateFormat = "yyyy-MM-dd"
        let formatter = DateFormatter()
        formatter.locale = codexBarLocalizedLocale()
        formatter.timeZone = parser.timeZone
        formatter.setLocalizedDateFormatFromTemplate("yMMMd")
        return days.map { day in
            let dateLabel = parser.date(from: day.date).map(formatter.string(from:)) ?? day.date
            let costUSD = tokensOnly ? nil : day.costUSD.flatMap { $0 >= 0 ? $0 : nil }
            let tokenCount = day.totalTokens.flatMap { $0 >= 0 ? $0 : nil }
            let convertedCost = costUSD.map(convertedValue)
            let hoverDetail: InlineUsageDashboardModel.HoverDetail? = if costUSD != nil || tokenCount != nil || day
                .incompleteRequestCount > 0
            {
                .init(
                    dateLabel: dateLabel,
                    cost: convertedCost,
                    tokenCount: tokenCount,
                    currencyCode: displayCurrencyCode,
                    incompleteRequestCount: day.incompleteRequestCount,
                    tokensOnly: tokensOnly)
            } else {
                nil
            }
            return InlineUsageDashboardModel.Point(
                id: day.date,
                label: Self.shortDayLabel(day.date),
                value: tokensOnly ? tokenCount.map(Double.init) : convertedCost,
                accessibilityValue: hoverDetail?.summary ?? "\(dateLabel): \(L("Unknown"))",
                hoverDetail: hoverDetail)
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
        guard entries.allSatisfy({
            $0.incompleteRequestCount == 0
                && $0.coverageCounts.unpriced == 0
                && $0.coverageCounts.unmetered == 0
        }) else { return nil }
        var scores: [String: (cost: Double, tokens: Int)] = [:]
        for entry in entries {
            for model in entry.modelBreakdowns ?? [] {
                var score = scores[model.modelName] ?? (0, 0)
                score.cost += model.costUSD ?? 0
                let addition = score.tokens.addingReportingOverflow(model.totalTokens ?? 0)
                guard !addition.overflow else { return nil }
                score.tokens = addition.partialValue
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
                    if let note = window.note {
                        Text(note)
                            .font(.caption2)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .fixedSize(horizontal: false, vertical: true)
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
        @Environment(\.layoutDirection) private var layoutDirection
        @State private var selectedPointID: String?

        var body: some View {
            let scale = UsageChartScale(values: self.model.points.compactMap(\.value))
            let hoverDetail = self.model.points
                .first(where: { $0.id == self.selectedPointID })?
                .hoverDetail
            VStack(alignment: .trailing, spacing: 2) {
                if let currencyCode = self.model.currencyCode {
                    let scaleLabel = scale.maximum > 0
                        ? UsageFormatter.compactCurrencyString(scale.maximum, currencyCode: currencyCode)
                        : " "
                    Text(hoverDetail?.summary ?? scaleLabel)
                        .font(.caption2)
                        .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.72)
                        .allowsTightening(true)
                        .frame(maxWidth: .infinity, alignment: hoverDetail == nil ? .trailing : .leading)
                        .opacity(hoverDetail != nil || scale.maximum > 0 ? 1 : 0)
                        .accessibilityHidden(hoverDetail != nil)
                }
                GeometryReader { geometry in
                    let layout = InlineUsageBarLayout(width: geometry.size.width, count: self.model.points.count)
                    ZStack {
                        HStack(alignment: .bottom, spacing: layout.spacing) {
                            ForEach(self.model.points) { point in
                                let barHeight = self.height(
                                    for: point,
                                    scale: scale,
                                    available: geometry.size.height)
                                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                    .fill(self.fill(for: point, scale: scale))
                                    .frame(width: layout.barWidth)
                                    .frame(height: barHeight)
                                    .overlay {
                                        if point.id == self.selectedPointID {
                                            RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                                                .strokeBorder(
                                                    MenuHighlightStyle.primary(self.isHighlighted),
                                                    lineWidth: layout.selectionStrokeWidth(barHeight: barHeight))
                                        }
                                    }
                                    .accessibilityLabel(point.accessibilityValue)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                        .overlay(alignment: .bottomLeading) {
                            Rectangle()
                                .fill(MenuHighlightStyle.secondary(self.isHighlighted).opacity(0.22))
                                .frame(height: 1)
                        }

                        if self.model.points.contains(where: { $0.hoverDetail != nil }) {
                            MouseLocationReader { location in
                                self.updateSelection(location: location, layout: layout)
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .contentShape(Rectangle())
                        }
                    }
                    .onChange(of: geometry.size.width) { _, _ in
                        self.clearSelection()
                    }
                    .onChange(of: self.model.points) { previousPoints, points in
                        let nextPointID = InlineUsageBarHoverSelection.reconciledPointID(
                            current: self.selectedPointID,
                            previousPoints: previousPoints,
                            points: points)
                        guard self.selectedPointID != nextPointID else { return }
                        self.selectedPointID = nextPointID
                    }
                    .onChange(of: self.layoutDirection) { _, _ in
                        self.clearSelection()
                    }
                }
            }
        }

        private func updateSelection(location: CGPoint?, layout: InlineUsageBarLayout) {
            let nextPointID = InlineUsageBarHoverSelection.pointID(
                current: self.selectedPointID,
                locationX: location?.x,
                layout: layout,
                layoutDirection: self.layoutDirection,
                points: self.model.points)
            guard self.selectedPointID != nextPointID else { return }
            self.selectedPointID = nextPointID
        }

        private func clearSelection() {
            guard self.selectedPointID != nil else { return }
            self.selectedPointID = nil
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
    private let width: CGFloat
    private let barCount: Int

    init(width: CGFloat, count: Int) {
        self.width = max(0, width)
        self.barCount = max(0, count)
        let layoutCount = max(1, self.barCount)
        self.spacing = self.barCount <= 1 ? 0 : min(2, self.width / CGFloat(layoutCount) / 4)
        self.barWidth = self.barCount == 0
            ? 0
            : max(0, (self.width - self.spacing * CGFloat(self.barCount - 1)) / CGFloat(self.barCount))
    }

    func selectionStrokeWidth(barHeight: CGFloat) -> CGFloat {
        min(1, self.barWidth / 2, max(0, barHeight) / 2)
    }

    func contains(_ locationX: CGFloat) -> Bool {
        self.barCount > 0 && self.width > 0 && locationX >= 0 && locationX <= self.width
    }

    func index(atX locationX: CGFloat, layoutDirection: LayoutDirection = .leftToRight) -> Int? {
        guard self.contains(locationX), self.barWidth > 0 else { return nil }

        let stride = self.barWidth + self.spacing
        guard stride > 0 else { return nil }
        let resolvedX = layoutDirection == .rightToLeft ? self.width - locationX : locationX
        if self.spacing < 1 {
            let nearest = Int(((resolvedX - self.barWidth / 2) / stride).rounded())
            return min(max(nearest, 0), self.barCount - 1)
        }
        let index = min(Int(resolvedX / stride), self.barCount - 1)
        let offset = resolvedX - CGFloat(index) * stride
        let tolerance = max(1, self.width) * CGFloat.ulpOfOne * 8
        return offset <= self.barWidth + tolerance ? index : nil
    }
}

enum InlineUsageBarHoverSelection {
    static func reconciledPointID(
        current: String?,
        previousPoints: [InlineUsageDashboardModel.Point],
        points: [InlineUsageDashboardModel.Point]) -> String?
    {
        guard previousPoints.map(\.id) == points.map(\.id), let current else { return nil }
        return points.contains { $0.id == current && $0.hoverDetail != nil } ? current : nil
    }

    static func pointID(
        current: String?,
        locationX: CGFloat?,
        layout: InlineUsageBarLayout,
        layoutDirection: LayoutDirection,
        points: [InlineUsageDashboardModel.Point]) -> String?
    {
        guard let locationX else { return nil }
        guard layout.contains(locationX) else { return nil }
        guard let index = layout.index(atX: locationX, layoutDirection: layoutDirection) else {
            return current.flatMap { currentID in
                points.contains { $0.id == currentID && $0.hoverDetail != nil } ? currentID : nil
            }
        }
        guard points.indices.contains(index), points[index].hoverDetail != nil else { return nil }
        return points[index].id
    }
}
