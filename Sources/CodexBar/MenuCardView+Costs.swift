import CodexBarCore
import Foundation
import SwiftUI

struct ProviderCostContent: View {
    let section: UsageMenuCardView.Model.ProviderCostSection
    let progressColor: Color
    @Environment(\.menuItemHighlighted) private var isHighlighted

    var body: some View {
        if self.section.presentation == .inlineValue {
            HStack(alignment: .firstTextBaseline) {
                Text(self.section.title)
                    .font(.body)
                    .fontWeight(.medium)
                Spacer()
                Text(self.section.spendLine)
                    .font(.footnote)
                    .monospacedDigit()
                    .lineLimit(1)
            }
        } else {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text(self.section.title)
                        .font(.body)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    if let balanceLine = self.section.balanceLine {
                        Spacer(minLength: 8)
                        Text(balanceLine)
                            .font(.footnote)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .monospacedDigit()
                            .lineLimit(1)
                            .layoutPriority(1)
                    }
                }
                if let percentUsed = self.section.percentUsed {
                    UsageProgressBar(
                        percent: percentUsed,
                        tint: self.progressColor,
                        accessibilityLabel: L("Extra usage spent"))
                }
                HStack(alignment: .firstTextBaseline) {
                    Text(self.section.spendLine).font(.footnote).lineLimit(1)
                    Spacer()
                    if let percentLine = self.section.percentLine {
                        Text(percentLine)
                            .font(.footnote)
                            .foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted))
                            .lineLimit(1)
                    }
                }
                if let personalSpendLine = self.section.personalSpendLine {
                    Text(personalSpendLine)
                        .font(.footnote).foregroundStyle(MenuHighlightStyle.secondary(self.isHighlighted)).lineLimit(1)
                }
            }
        }
    }
}

extension UsageMenuCardView.Model.ProviderCostSection {
    enum Presentation: Equatable {
        case detail
        case inlineValue
    }

    init(
        title: String,
        percentUsed: Double?,
        spendLine: String,
        percentLine: String?,
        balanceLine: String? = nil,
        presentation: Presentation = .detail,
        showsInProviderDetails: Bool = true)
    {
        self.init(
            title: title,
            percentUsed: percentUsed,
            spendLine: spendLine,
            percentLine: percentLine,
            balanceLine: balanceLine,
            personalSpendLine: nil,
            presentation: presentation,
            showsInProviderDetails: showsInProviderDetails)
    }
}

extension UsageMenuCardView.Model {
    static func isRequiredOpenCodeZenBalance(_ snapshot: UsageSnapshot?) -> Bool {
        snapshot?.primary == nil &&
            snapshot?.secondary == nil &&
            snapshot?.providerCost?.period == "Zen balance"
    }

    static func tokenUsageSnapshot(input: Input) -> CostUsageTokenSnapshot? {
        if usesProviderCostHistoryAsPrimaryDashboard(input.provider), input.snapshot != nil {
            return primaryCostHistorySnapshot(input: input)
        }
        return input.tokenSnapshot
    }

    static func creditsLine(
        metadata: ProviderMetadata,
        snapshot: UsageSnapshot?,
        credits: CreditsSnapshot?,
        error: String?,
        preferredCurrencyCode: String = "auto") -> String?
    {
        guard metadata.supportsCredits else { return nil }
        let visibility = ProviderDescriptorRegistry.descriptor(for: metadata.id).presentation.menuCard.creditsVisibility
        if visibility == .hidden ||
            (visibility == .requiresValueOrError && credits == nil && error == nil) ||
            (visibility == .hiddenWhenUsageSnapshotPresent && snapshot != nil)
        {
            return nil
        }
        if let credits {
            if let creditLimit = credits.codexCreditLimit {
                return UsageFormatter.creditsString(from: creditLimit.remaining)
            }
            return UsageFormatter.creditsString(from: credits.remaining)
        }
        if let error, !error.isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return L(metadata.creditsHint)
    }

    static func creditsProgressPercent(credits: CreditsSnapshot?) -> Double? {
        credits?.codexCreditLimit?.remainingPercent
    }

    static func creditsScaleText(credits: CreditsSnapshot?) -> String? {
        guard let limit = credits?.codexCreditLimit else { return nil }
        return L("of %@", UsageFormatter.creditsNumberString(from: limit.limit))
    }

    static func codexCreditLimitDetail(credits: CreditsSnapshot?, now: Date) -> String? {
        guard let limit = credits?.codexCreditLimit else { return nil }
        var parts = [
            L("%@ used", UsageFormatter.creditsNumberString(from: limit.used)),
        ]
        if let resetsAt = limit.resetsAt {
            parts.append(L("resets %@", UsageFormatter.resetDescription(from: resetsAt, now: now)))
        }
        return parts.joined(separator: " · ")
    }

    static func tokenUsageSection(
        provider: UsageProvider,
        enabled: Bool,
        isRefreshing: Bool = false,
        comparisonPeriodsEnabled: Bool,
        snapshot: CostUsageTokenSnapshot?,
        error: String?,
        preferredCurrencyCode: String = "auto") -> TokenUsageSection?
    {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            return nil
        }
        guard enabled else { return nil }
        guard let snapshot else { return nil }

        let sessionCost = snapshot.sessionCostUSD.map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode)
        } ?? "—"
        let sessionTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let sessionLabel = if provider == .bedrock || provider == .mistral {
            Self.latestBillingDayLabel(from: snapshot)
        } else {
            L("Today")
        }
        let sessionLine: String = {
            if let sessionTokens {
                return String(format: L("%@: %@ · %@ tokens"), sessionLabel, sessionCost, sessionTokens)
            }
            return "\(sessionLabel): \(sessionCost)"
        }()

        let monthCost = snapshot.last30DaysCostUSD.map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode)
        } ?? "—"
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let monthTokens = monthTokensValue.map { UsageFormatter.tokenCountString($0) }
        let windowLabel = if let historyLabel = snapshot.historyLabel {
            historyLabel
        } else if provider == .mistral,
                  snapshot.historyDays == 1,
                  Self.bedrockLatestBillingDay(from: snapshot.daily) != nil
        {
            L("Latest billing day")
        } else {
            Self.costHistoryWindowLabel(days: snapshot.historyDays)
        }
        let monthLine: String = {
            if let monthTokens {
                return String(format: L("%@: %@ · %@ tokens"), windowLabel, monthCost, monthTokens)
            }
            return "\(windowLabel): \(monthCost)"
        }()
        // Plan-metered spend over the same window (what the provider actually deducts);
        // only providers that report it (currently Cursor) populate `meteredCostUSD`.
        let meteredLine: String? = snapshot.meteredCostUSD.map {
            let amount = UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: snapshot.currencyCode)
            return String(format: L("Cursor-metered: %@ (%@)"), amount, windowLabel.lowercased())
        }
        var comparisonLines: [String] = []
        if comparisonPeriodsEnabled {
            comparisonLines.append(contentsOf: snapshot.comparisonSummaries().map {
                Self.costWindowLine(
                    summary: $0,
                    currencyCode: UsageFormatter.effectiveCurrencyCode(
                        preferred: preferredCurrencyCode,
                        providerCurrency: snapshot.currencyCode),
                    sourceCurrencyCode: snapshot.currencyCode)
            })
        }
        // Grok: surface token composition + model mix on the Cost card (not just $ / total).
        if provider == .grok {
            comparisonLines.append(contentsOf: Self.grokTokenDetailLines(snapshot: snapshot))
        }
        let err = (error?.isEmpty ?? true) ? nil : error
        return TokenUsageSection(
            isRefreshing: isRefreshing,
            sessionLine: sessionLine,
            monthLine: monthLine,
            meteredLine: meteredLine,
            comparisonLines: comparisonLines,
            hintLine: Self.tokenUsageHint(provider: provider),
            errorLine: err,
            errorCopyText: (error?.isEmpty ?? true) ? nil : error)
    }

    /// Extra Cost-card lines for Grok local session stats.
    static func grokTokenDetailLines(snapshot: CostUsageTokenSnapshot) -> [String] {
        var lines: [String] = []
        let input = snapshot.daily.compactMap(\.inputTokens).reduce(0, +)
        let cache = snapshot.daily.compactMap(\.cacheReadTokens).reduce(0, +)
        let output = snapshot.daily.compactMap(\.outputTokens).reduce(0, +)
        if input + cache + output > 0 {
            lines.append(String(
                format: L("Uncached %@ · Cache %@ · Output %@"),
                UsageFormatter.tokenCountString(input),
                UsageFormatter.tokenCountString(cache),
                UsageFormatter.tokenCountString(output)))
        }
        var modelTotals: [String: Int] = [:]
        for entry in snapshot.daily {
            for breakdown in entry.modelBreakdowns ?? [] {
                modelTotals[breakdown.modelName, default: 0] += breakdown.totalTokens ?? 0
            }
        }
        if !modelTotals.isEmpty {
            let top = modelTotals.sorted { $0.value > $1.value }.prefix(3)
            let parts = top.map { "\($0.key) \(UsageFormatter.tokenCountString($0.value))" }
            lines.append(String(format: L("Models: %@"), parts.joined(separator: " · ")))
        }
        if !snapshot.projects.isEmpty {
            let topProjects = snapshot.projects.prefix(3)
            let parts = topProjects.map { project in
                let tokens = project.totalTokens.map(UsageFormatter.tokenCountString) ?? "—"
                return "\(project.name) \(tokens)"
            }
            lines.append(String(format: L("Top projects: %@"), parts.joined(separator: " · ")))
        }
        let daysWithCost = snapshot.daily.count(where: { ($0.costUSD ?? 0) > 0 })
        if daysWithCost < snapshot.daily.count {
            lines.append(String(
                format: L("Cost reported on %d/%d days"),
                daysWithCost,
                snapshot.daily.count))
        }
        return lines
    }

    static func costWindowLine(
        summary: CostUsageWindowSummary,
        currencyCode: String,
        sourceCurrencyCode: String? = nil) -> String
    {
        let label = Self.costHistoryWindowLabel(days: summary.days)
        let cost = summary.totalCostUSD.map {
            UsageFormatter.convertedCostString(
                $0,
                preferredCurrency: currencyCode,
                providerCurrency: sourceCurrencyCode ?? currencyCode)
        } ?? "—"
        guard let totalTokens = summary.totalTokens else { return "\(label): \(cost)" }
        return String(
            format: L("%@: %@ · %@ tokens"),
            label,
            cost,
            UsageFormatter.tokenCountString(totalTokens))
    }

    static func tokenUsageHint(provider: UsageProvider) -> String? {
        let lines = Self.tokenUsageHintLines(provider: provider)
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func tokenUsageHeader(provider _: UsageProvider) -> String {
        L("Cost")
    }

    static func tokenUsageHintLines(provider: UsageProvider) -> [String] {
        ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.menuHintLines.map { hint in
            switch hint {
            case let .localized(key): L(key)
            case .estimate: UsageFormatter.costEstimateHint(provider: provider)
            case let .literal(text): L(text)
            }
        }
    }

    static func costHistoryWindowLabel(days: Int) -> String {
        days == 1 ? L("Today") : String(format: L("Last %d days"), days)
    }

    private static func latestBillingDayLabel(from snapshot: CostUsageTokenSnapshot) -> String {
        guard let entry = bedrockLatestBillingDay(from: snapshot.daily),
              let displayDate = bedrockDisplayDate(from: entry.date)
        else { return L("Latest billing day") }
        return String(format: L("Latest billing day (%@)"), displayDate)
    }

    private static func bedrockLatestBillingDay(from entries: [CostUsageDailyReport.Entry])
        -> CostUsageDailyReport.Entry?
    {
        entries.compactMap { entry -> (entry: CostUsageDailyReport.Entry, dayKey: String)? in
            guard let dayKey = bedrockBillingDayKey(from: entry.date) else { return nil }
            return (entry, dayKey)
        }
        .max { lhs, rhs in
            if lhs.dayKey != rhs.dayKey {
                return lhs.dayKey < rhs.dayKey
            }
            let lCost = lhs.entry.costUSD ?? -1
            let rCost = rhs.entry.costUSD ?? -1
            if lCost != rCost {
                return lCost < rCost
            }
            let lTokens = lhs.entry.totalTokens ?? -1
            let rTokens = rhs.entry.totalTokens ?? -1
            if lTokens != rTokens {
                return lTokens < rTokens
            }
            return lhs.entry.date < rhs.entry.date
        }?.entry
    }

    private static func bedrockDisplayDate(from text: String) -> String? {
        guard let dayKey = bedrockBillingDayKey(from: text) else { return nil }
        let monthStart = dayKey.index(dayKey.startIndex, offsetBy: 5)
        let monthEnd = dayKey.index(monthStart, offsetBy: 2)
        let dayStart = dayKey.index(dayKey.startIndex, offsetBy: 8)
        guard
            let month = Int(dayKey[monthStart..<monthEnd]),
            let day = Int(dayKey[dayStart...]),
            (1...Self.bedrockMonthAbbreviations.count).contains(month),
            (1...31).contains(day)
        else { return nil }
        return "\(Self.bedrockMonthAbbreviations[month - 1]) \(day)"
    }

    private static let bedrockMonthAbbreviations = [
        "Jan", "Feb", "Mar", "Apr", "May", "Jun",
        "Jul", "Aug", "Sep", "Oct", "Nov", "Dec",
    ]

    private static func bedrockBillingDayKey(from text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count == 10 else { return nil }
        for (offset, character) in trimmed.enumerated() {
            switch offset {
            case 4, 7:
                guard character == "-" else { return nil }
            default:
                guard character.isNumber else { return nil }
            }
        }
        let monthStart = trimmed.index(trimmed.startIndex, offsetBy: 5)
        let monthEnd = trimmed.index(monthStart, offsetBy: 2)
        let dayStart = trimmed.index(trimmed.startIndex, offsetBy: 8)
        let yearEnd = trimmed.index(trimmed.startIndex, offsetBy: 4)
        guard
            let year = Int(trimmed[..<yearEnd]),
            let month = Int(trimmed[monthStart..<monthEnd]),
            let day = Int(trimmed[dayStart...]),
            (1...Self.bedrockMonthAbbreviations.count).contains(month),
            (1...Self.daysInBedrockBillingMonth(month, year: year)).contains(day)
        else { return nil }
        return trimmed
    }

    private static func daysInBedrockBillingMonth(_ month: Int, year: Int) -> Int {
        switch month {
        case 2:
            if year.isMultiple(of: 400) {
                return 29
            }
            if year.isMultiple(of: 100) {
                return 28
            }
            return year.isMultiple(of: 4) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    static func providerCostSection(
        cost: ProviderCostSnapshot?,
        style: ProviderCostMenuCardStyle,
        isClaudeAdminAPI: Bool = false,
        preferredCurrencyCode: String = "auto") -> ProviderCostSection?
    {
        guard style != .hidden else { return nil }
        guard let cost else { return nil }

        /// Formats a cost value using the user's currency preference.
        func formatCost(_ value: Double, providerCurrency: String? = nil) -> String {
            UsageFormatter.convertedCostString(
                value,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: providerCurrency ?? cost.currencyCode)
        }

        if style == .extraUsageBalance {
            let balance = formatCost(cost.used)
            return ProviderCostSection(
                title: L("Extra usage"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if style == .zenBalance {
            let balance = formatCost(cost.used)
            return ProviderCostSection(
                title: L("Zen balance"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if style == .pointsBalance {
            let balance = String(format: "%.0f", cost.used)
            return ProviderCostSection(
                title: L("Credits"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if style == .prepaidCredits {
            let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ProviderCostSection(
                title: L("Credits"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if style == .payAsYouGoBalance {
            let balance = formatCost(cost.used)
            return ProviderCostSection(
                title: L("metric_mistral_payg"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if style == .claude {
            if isClaudeAdminAPI {
                let spend = formatCost(cost.used)
                let periodLabel = Self.localizedPeriodLabel(cost.period ?? "Last 30 days")
                return ProviderCostSection(
                    title: L("API spend"),
                    percentUsed: nil,
                    spendLine: "\(periodLabel): \(spend)",
                    percentLine: nil)
            }

            if cost.limit <= 0 {
                guard let balance = cost.balance else { return nil }
                let value = formatCost(balance)
                return ProviderCostSection(
                    title: L("Credits"),
                    percentUsed: nil,
                    spendLine: value,
                    percentLine: nil,
                    presentation: .inlineValue,
                    showsInProviderDetails: false)
            }

            let used = formatCost(cost.used)
            let limit = formatCost(cost.limit)
            let percentUsed = Self.clamped((cost.used / cost.limit) * 100)
            let periodLabel = Self.localizedPeriodLabel(cost.period ?? "This month")
            let balanceLine = cost.balance.map {
                "\(L("Balance")): \(formatCost($0))"
            }
            return ProviderCostSection(
                title: L("Extra usage"),
                percentUsed: percentUsed,
                spendLine: "\(periodLabel): \(used) / \(limit)",
                percentLine: String(format: L("%.0f%% used"), min(100, max(0, percentUsed))),
                balanceLine: balanceLine,
                showsInProviderDetails: false)
        }

        if style == .apiSpend {
            let spend = formatCost(cost.used)
            let periodLabel = Self.localizedPeriodLabel(cost.period ?? "Last 30 days")
            return ProviderCostSection(
                title: L("API spend"),
                percentUsed: nil,
                spendLine: "\(periodLabel): \(spend)",
                percentLine: nil)
        }

        if style == .clawRouter, cost.limit <= 0 {
            let spend = formatCost(cost.used)
            return ProviderCostSection(
                title: "ClawRouter spend",
                percentUsed: nil,
                spendLine: "\(L("This month")): \(spend)",
                percentLine: nil)
        }

        guard cost.limit > 0 else { return nil }

        let used: String
        let limit: String
        let title: String

        if style == .clawRouter {
            title = "Monthly budget"
            used = formatCost(cost.used)
            limit = formatCost(cost.limit)
        } else if cost.currencyCode == "Quota" {
            title = L("Quota usage")
            used = String(format: "%.0f", cost.used)
            limit = String(format: "%.0f", cost.limit)
        } else {
            title = L("Extra usage")
            used = formatCost(cost.used)
            limit = formatCost(cost.limit)
        }

        let percentUsed = Self.clamped((cost.used / cost.limit) * 100)
        let periodLabel = Self.localizedPeriodLabel(cost.period ?? "This month")

        // When the headline budget is a shared pool (e.g. Cursor team on-demand), show the
        // account's own contribution underneath it.
        let personalSpendLine: String? = cost.personalUsed.flatMap { personal in
            personal > 0
                ? "\(L("Your spend")): \(formatCost(personal))"
                : nil
        }

        return ProviderCostSection(
            title: title,
            percentUsed: percentUsed,
            spendLine: "\(periodLabel): \(used) / \(limit)",
            percentLine: String(format: L("%.0f%% used"), min(100, max(0, percentUsed))),
            balanceLine: nil,
            personalSpendLine: personalSpendLine)
    }

    private static func localizedPeriodLabel(_ label: String) -> String {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        switch trimmed.lowercased() {
        case "last 30 days":
            return L("Last 30 days")
        case "this month":
            return L("This month")
        case "today":
            return L("Today")
        default:
            return L(trimmed)
        }
    }

    static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
