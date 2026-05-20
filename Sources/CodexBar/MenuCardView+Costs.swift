import CodexBarCore
import Foundation

extension UsageMenuCardView.Model {
    static func creditsLine(
        metadata: ProviderMetadata,
        credits: CreditsSnapshot?,
        error: String?) -> String?
    {
        guard metadata.supportsCredits else { return nil }
        if let credits {
            return UsageFormatter.creditsString(from: credits.remaining)
        }
        if let error, !error.isEmpty {
            return error.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return metadata.creditsHint
    }

    static func tokenUsageSection(
        provider: UsageProvider,
        enabled: Bool,
        snapshot: CostUsageTokenSnapshot?,
        error: String?) -> TokenUsageSection?
    {
        guard provider == .codex || provider == .claude || provider == .vertexai || provider == .bedrock else {
            return nil
        }
        guard enabled else { return nil }
        guard let snapshot else { return nil }

        let sessionCost = snapshot.sessionCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let sessionTokens = snapshot.sessionTokens.map { UsageFormatter.tokenCountString($0) }
        let sessionLine: String = {
            if provider == .bedrock {
                let label = Self.bedrockLatestBillingDayLabel(from: snapshot)
                if let sessionTokens {
                    return "\(label): \(sessionCost) · \(sessionTokens) tokens"
                }
                return "\(label): \(sessionCost)"
            }
            if provider == .codex {
                if let sessionTokens {
                    return "Today (local Mac): \(sessionCost) · \(sessionTokens) tokens"
                }
                return "Today (local Mac): \(sessionCost)"
            }
            if let sessionTokens {
                return "Today: \(sessionCost) · \(sessionTokens) tokens"
            }
            return "Today: \(sessionCost)"
        }()

        let monthCost = snapshot.last30DaysCostUSD.map { UsageFormatter.usdString($0) } ?? "—"
        let fallbackTokens = snapshot.daily.compactMap(\.totalTokens).reduce(0, +)
        let monthTokensValue = snapshot.last30DaysTokens ?? (fallbackTokens > 0 ? fallbackTokens : nil)
        let monthTokens = monthTokensValue.map { UsageFormatter.tokenCountString($0) }
        let windowLabel = Self.costHistoryWindowLabel(days: snapshot.historyDays)
        let scopedWindowLabel = provider == .codex ? "\(windowLabel) (local Mac)" : windowLabel
        let monthLine: String = {
            if let monthTokens {
                return "\(scopedWindowLabel): \(monthCost) · \(monthTokens) tokens"
            }
            return "\(scopedWindowLabel): \(monthCost)"
        }()
        let err = (error?.isEmpty ?? true) ? nil : error
        return TokenUsageSection(
            sessionLine: sessionLine,
            monthLine: monthLine,
            hintLine: Self.tokenUsageHint(provider: provider),
            errorLine: err,
            errorCopyText: (error?.isEmpty ?? true) ? nil : error)
    }

    static func tokenUsageHint(provider: UsageProvider) -> String? {
        switch provider {
        case .codex:
            "Estimated from local Codex logs on this Mac; remote usage may be missing."
        case .claude:
            UsageFormatter.costEstimateHint(provider: provider)
        case .vertexai:
            UsageFormatter.costEstimateHint
        case .bedrock:
            "Reported by AWS Cost Explorer; daily billing data can lag."
        default:
            nil
        }
    }

    static func costHistoryWindowLabel(days: Int) -> String {
        days == 1 ? "Today" : "Last \(days) days"
    }

    private static func bedrockLatestBillingDayLabel(from snapshot: CostUsageTokenSnapshot) -> String {
        guard let entry = bedrockLatestBillingDay(from: snapshot.daily),
              let displayDate = bedrockDisplayDate(from: entry.date)
        else { return "Latest billing day" }
        return "Latest billing day (\(displayDate))"
    }

    private static func bedrockLatestBillingDay(from entries: [CostUsageDailyReport.Entry])
        -> CostUsageDailyReport.Entry?
    {
        entries.max { lhs, rhs in
            let lDate = Self.bedrockBillingDate(from: lhs.date) ?? .distantPast
            let rDate = Self.bedrockBillingDate(from: rhs.date) ?? .distantPast
            if lDate != rDate { return lDate < rDate }
            let lCost = lhs.costUSD ?? -1
            let rCost = rhs.costUSD ?? -1
            if lCost != rCost { return lCost < rCost }
            let lTokens = lhs.totalTokens ?? -1
            let rTokens = rhs.totalTokens ?? -1
            if lTokens != rTokens { return lTokens < rTokens }
            return lhs.date < rhs.date
        }
    }

    private static func bedrockDisplayDate(from text: String) -> String? {
        guard let date = bedrockBillingDate(from: text) else { return nil }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date)
    }

    private static func bedrockBillingDate(from text: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: text.trimmingCharacters(in: .whitespacesAndNewlines))
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

        if provider == .factory, cost.period == "Extra usage balance" {
            let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ProviderCostSection(
                title: "Extra usage",
                percentUsed: nil,
                spendLine: "Balance: \(balance)",
                percentLine: nil)
        }

        if provider == .opencodego, cost.period == "Zen balance" {
            let balance = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            return ProviderCostSection(
                title: "Zen balance",
                percentUsed: nil,
                spendLine: "Balance: \(balance)",
                percentLine: nil)
        }

        if provider == .openai || provider == .claude, cost.limit <= 0 {
            let spend = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            let periodLabel = cost.period ?? "Last 30 days"
            return ProviderCostSection(
                title: "API spend",
                percentUsed: nil,
                spendLine: "\(periodLabel): \(spend)",
                percentLine: nil)
        }

        guard cost.limit > 0 else { return nil }

        let used: String
        let limit: String
        let title: String

        if cost.currencyCode == "Quota" {
            title = "Quota usage"
            used = String(format: "%.0f", cost.used)
            limit = String(format: "%.0f", cost.limit)
        } else {
            title = "Extra usage"
            used = UsageFormatter.currencyString(cost.used, currencyCode: cost.currencyCode)
            limit = UsageFormatter.currencyString(cost.limit, currencyCode: cost.currencyCode)
        }

        let percentUsed = Self.clamped((cost.used / cost.limit) * 100)
        let periodLabel = cost.period ?? "This month"

        return ProviderCostSection(
            title: title,
            percentUsed: percentUsed,
            spendLine: "\(periodLabel): \(used) / \(limit)",
            percentLine: String(format: "%.0f%% used", min(100, max(0, percentUsed))))
    }

    static func clamped(_ value: Double) -> Double {
        min(100, max(0, value))
    }
}
