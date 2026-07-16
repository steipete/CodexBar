import CodexBarCore
import Foundation

extension UsageMenuCardView.Model.ProviderCostSection {
    init(
        title: String,
        percentUsed: Double?,
        spendLine: String,
        percentLine: String?)
    {
        self.init(
            title: title,
            percentUsed: percentUsed,
            spendLine: spendLine,
            percentLine: percentLine,
            personalSpendLine: nil)
    }
}

extension UsageMenuCardView.Model {
    static func sakanaPayAsYouGoSection(_ usage: SakanaPayAsYouGoSnapshot?) -> ProviderCostSection? {
        guard let usage else { return nil }
        return ProviderCostSection(
            title: L("Extra usage"),
            percentUsed: nil,
            spendLine: "\(L("Balance")): \(usage.balanceDetail)",
            percentLine: usage.periodUsageTotal.map { "\(L("Usage")): \(UsageFormatter.usdString($0))" })
    }

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
        error: String?) -> String?
    {
        guard metadata.supportsCredits else { return nil }
        if metadata.id == .codex, credits == nil, error == nil { return nil }
        if metadata.id == .amp,
           let ampUsage = snapshot?.ampUsage,
           let ampCredits = self.ampCreditsLine(ampUsage)
        {
            return ampCredits
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

    private static func ampCreditsLine(_ usage: AmpUsageDetails) -> String? {
        var lines: [String] = []
        if let individualCredits = usage.individualCredits {
            lines.append(
                "\(L("Individual credits")): \(UsageFormatter.currencyString(individualCredits, currencyCode: "USD"))")
        }
        lines.append(contentsOf: usage.workspaceBalances.map { workspace in
            "\(L("Workspace")) \(workspace.name): " +
                UsageFormatter.currencyString(workspace.remaining, currencyCode: "USD")
        })
        return lines.isEmpty ? nil : lines.joined(separator: "\n")
    }

    static func tokenUsageSection(
        provider: UsageProvider,
        enabled: Bool,
        comparisonPeriodsEnabled: Bool,
        snapshot: CostUsageTokenSnapshot?,
        error: String?) -> TokenUsageSection?
    {
        guard ProviderDescriptorRegistry.descriptor(for: provider).tokenCost.supportsTokenCost else {
            return nil
        }
        guard enabled else { return nil }
        guard let snapshot else { return nil }

        let sessionCost = snapshot.sessionCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
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
            UsageFormatter.currencyString($0, currencyCode: snapshot.currencyCode)
        } ?? "—"
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let monthTokens = monthTokensValue.map { UsageFormatter.tokenCountString($0) }
        let windowLabel = snapshot.historyLabel ?? Self.costHistoryWindowLabel(days: snapshot.historyDays)
        let monthLine: String = {
            if let monthTokens {
                return String(format: L("%@: %@ · %@ tokens"), windowLabel, monthCost, monthTokens)
            }
            return "\(windowLabel): \(monthCost)"
        }()
        let err = (error?.isEmpty ?? true) ? nil : error
        return TokenUsageSection(
            sessionLine: sessionLine,
            monthLine: monthLine,
            comparisonLines: comparisonPeriodsEnabled
                ? snapshot.comparisonSummaries().map {
                    Self.costWindowLine(summary: $0, currencyCode: snapshot.currencyCode)
                }
                : [],
            hintLine: Self.tokenUsageHint(provider: provider),
            errorLine: err,
            errorCopyText: (error?.isEmpty ?? true) ? nil : error)
    }

    static func costWindowLine(summary: CostUsageWindowSummary, currencyCode: String) -> String {
        let label = Self.costHistoryWindowLabel(days: summary.days)
        let cost = summary.totalCostUSD.map {
            UsageFormatter.currencyString($0, currencyCode: currencyCode)
        } ?? "—"
        guard let totalTokens = summary.totalTokens else { return "\(label): \(cost)" }
        return String(
            format: L("%@: %@ · %@ tokens"),
            label,
            cost,
            UsageFormatter.tokenCountString(totalTokens))
    }

    static func tokenUsageHint(provider: UsageProvider) -> String? {
        switch provider {
        case .codex:
            L("Estimated from local Codex logs for the selected account.")
        case .claude:
            UsageFormatter.costEstimateHint(provider: provider)
        case .vertexai:
            L("cost_estimate_hint")
        case .bedrock:
            L("AWS Cost Explorer billing can lag.")
        case .openai:
            L("Reported by OpenAI Admin API organization usage.")
        case .mistral:
            L("Reported by Mistral billing usage.")
        default:
            nil
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
            if lhs.dayKey != rhs.dayKey { return lhs.dayKey < rhs.dayKey }
            let lCost = lhs.entry.costUSD ?? -1
            let rCost = rhs.entry.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.entry.totalTokens ?? -1
            let rTokens = rhs.entry.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
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
            if year.isMultiple(of: 400) { return 29 }
            if year.isMultiple(of: 100) { return 28 }
            return year.isMultiple(of: 4) ? 29 : 28
        case 4, 6, 9, 11:
            return 30
        default:
            return 31
        }
    }

    static func providerCostSection(
        provider: UsageProvider,
        cost: ProviderCostSnapshot?) -> ProviderCostSection?
    {
        if provider == .manus {
            return nil
        }
        guard let cost else { return nil }
        guard provider != .synthetic else { return nil }

        if provider == .factory || provider == .devin, cost.period == "Extra usage balance" {
            let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ProviderCostSection(
                title: L("Extra usage"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if provider == .opencodego, cost.period == "Zen balance" {
            let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ProviderCostSection(
                title: L("Zen balance"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if provider == .minimax, cost.period == "MiniMax points balance" {
            let balance = String(format: "%.0f", cost.used)
            return ProviderCostSection(
                title: L("Credits"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if provider == .zenmux {
            let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ProviderCostSection(
                title: L("metric_mistral_payg"),
                percentUsed: nil,
                spendLine: "\(L("Balance")): \(balance)",
                percentLine: nil)
        }

        if provider == .openai || provider == .claude || provider == .litellm, cost.limit <= 0 {
            let spend = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            let periodLabel = Self.localizedPeriodLabel(cost.period ?? "Last 30 days")
            return ProviderCostSection(
                title: L("API spend"),
                percentUsed: nil,
                spendLine: "\(periodLabel): \(spend)",
                percentLine: nil)
        }

        if provider == .litellm {
            return nil
        }

        if provider == .clawrouter, cost.limit <= 0 {
            let spend = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
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

        if provider == .clawrouter {
            title = "Monthly budget"
            used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
        } else if cost.currencyCode == "Quota" {
            title = L("Quota usage")
            used = String(format: "%.0f", cost.used)
            limit = String(format: "%.0f", cost.limit)
        } else {
            title = L("Extra usage")
            used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
        }

        let percentUsed = Self.clamped((cost.used / cost.limit) * 100)
        let periodLabel = Self.localizedPeriodLabel(cost.period ?? "This month")

        // When the headline budget is a shared pool (e.g. Cursor team on-demand), show the
        // account's own contribution underneath it.
        let personalSpendLine: String? = cost.personalUsed.flatMap { personal in
            personal > 0
                ? "\(L("Your spend")): \(UsageFormatter.currencyString(personal, currencyCode: cost.currencyCode))"
                : nil
        }

        return ProviderCostSection(
            title: title,
            percentUsed: percentUsed,
            spendLine: "\(periodLabel): \(used) / \(limit)",
            percentLine: String(format: L("%.0f%% used"), min(100, max(0, percentUsed))),
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
