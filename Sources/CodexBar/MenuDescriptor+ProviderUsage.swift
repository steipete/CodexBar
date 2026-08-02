import CodexBarCore
import Foundation

extension MenuDescriptor {
    static func appendOpenAIAPIUsageSummary(
        entries: inout [Entry],
        usage: OpenAIAPIUsageSnapshot,
        preferredCurrencyCode: String = "auto")
    {
        let today = usage.currentDay
        let last7 = usage.last7Days
        let last30 = usage.last30Days
        let historyLabel = usage.historyWindowLabel
        let todayCost = UsageFormatter.convertedCostString(
            today.costUSD, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
        let last7Cost = UsageFormatter.convertedCostString(
            last7.costUSD, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
        let last30Cost = UsageFormatter.convertedCostString(
            last30.costUSD, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")

        entries.append(.text(
            "\(L("Today")): \(todayCost) · " +
                "\(UsageFormatter.tokenCountString(today.totalTokens)) \(L("tokens"))",
            .secondary))
        entries.append(.text(
            "7d: \(last7Cost) · " +
                "\(UsageFormatter.tokenCountString(last7.requests)) \(L("requests"))",
            .secondary))
        entries.append(.text(
            "\(historyLabel): \(last30Cost) · " +
                "\(UsageFormatter.tokenCountString(last30.requests)) \(L("requests"))",
            .secondary))
        if let topModel = usage.topModels.first?.name {
            entries.append(.text("\(L("Top model")): \(topModel)", .secondary))
        }
    }

    static func appendClaudeAdminAPIUsageSummary(
        entries: inout [Entry],
        usage: ClaudeAdminAPIUsageSnapshot,
        preferredCurrencyCode: String = "auto")
    {
        let today = usage.currentDay
        let last7 = usage.last7Days
        let last30 = usage.last30Days
        let todayCost = UsageFormatter.convertedCostString(
            today.costUSD, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
        let last7Cost = UsageFormatter.convertedCostString(
            last7.costUSD, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
        let last30Cost = UsageFormatter.convertedCostString(
            last30.costUSD, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")

        entries.append(.text(
            "\(L("Today")): \(todayCost) · " +
                "\(UsageFormatter.tokenCountString(today.totalTokens)) \(L("tokens"))",
            .secondary))
        entries.append(.text(
            "7d: \(last7Cost) · " +
                "\(UsageFormatter.tokenCountString(last7.totalTokens)) \(L("tokens"))",
            .secondary))
        entries.append(.text(
            "30d: \(last30Cost) · " +
                "\(UsageFormatter.tokenCountString(last30.totalTokens)) \(L("tokens"))",
            .secondary))
        if let topModel = usage.topModels.first?.name {
            entries.append(.text("\(L("Top model")): \(topModel)", .secondary))
        }
    }

    static func appendOpenRouterUsageSummary(
        entries: inout [Entry],
        usage: OpenRouterUsageSnapshot,
        preferredCurrencyCode: String = "auto")
    {
        if let daily = usage.keyUsageDaily {
            let cost = UsageFormatter.convertedCostString(
                daily, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
            entries.append(.text("\(L("Today")): \(cost)", .secondary))
        }
        if let weekly = usage.keyUsageWeekly {
            let cost = UsageFormatter.convertedCostString(
                weekly, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
            entries.append(.text("\(L("Week")): \(cost)", .secondary))
        }
        if let monthly = usage.keyUsageMonthly {
            let cost = UsageFormatter.convertedCostString(
                monthly, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
            entries.append(.text("\(L("Month")): \(cost)", .secondary))
        }
    }

    static func appendMistralUsageSummary(
        entries: inout [Entry],
        usage: MistralUsageSnapshot,
        preferredCurrencyCode: String = "auto")
    {
        let latest = usage.daily.last
        if let latest {
            let cost = UsageFormatter.convertedCostString(
                latest.cost,
                preferredCurrency: preferredCurrencyCode,
                providerCurrency: usage.currency)
            entries.append(.text(
                "\(L("Latest")): \(cost) · " +
                    "\(UsageFormatter.tokenCountString(latest.totalTokens)) \(L("tokens"))",
                .secondary))
        }
        let totalTokens = usage.totalInputTokens + usage.totalCachedTokens + usage.totalOutputTokens
        let totalCost = UsageFormatter.convertedCostString(
            usage.totalCost,
            preferredCurrency: preferredCurrencyCode,
            providerCurrency: usage.currency)
        entries.append(.text(
            "\(L("Month")): \(totalCost) · " +
                "\(UsageFormatter.tokenCountString(totalTokens)) \(L("tokens"))",
            .secondary))
        if let top = Self.topMistralModel(from: usage.daily) {
            entries.append(.text("\(L("Top model")): \(top)", .secondary))
        }
    }

    static func appendPoeUsageSummary(
        entries: inout [Entry],
        usage: PoeUsageHistorySnapshot,
        preferredCurrencyCode: String = "auto")
    {
        let today = usage.currentDay()
        let week = usage.last7Days
        let month = usage.last30Days
        let todayCostSuffix = today.costUSD.map { value in
            let cost = UsageFormatter.convertedCostString(
                value, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
            return " · \(cost)"
        } ?? ""
        let weekCostSuffix = week.costUSD.map { value in
            let cost = UsageFormatter.convertedCostString(
                value, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
            return " · \(cost)"
        } ?? ""
        let monthCostSuffix = month.costUSD.map { value in
            let cost = UsageFormatter.convertedCostString(
                value, preferredCurrency: preferredCurrencyCode, providerCurrency: "USD")
            return " · \(cost)"
        } ?? ""
        entries.append(.text(
            "\(L("Today")): \(Self.pointsString(today.points)) · " +
                "\(UsageFormatter.tokenCountString(today.requests)) \(L("requests"))\(todayCostSuffix)",
            .secondary))
        entries.append(.text(
            "7d: \(Self.pointsString(week.points)) · " +
                "\(UsageFormatter.tokenCountString(week.requests)) \(L("requests"))\(weekCostSuffix)",
            .secondary))
        entries.append(.text(
            "30d: \(Self.pointsString(month.points)) · " +
                "\(UsageFormatter.tokenCountString(month.requests)) \(L("requests"))\(monthCostSuffix)",
            .secondary))
        if let topModel = usage.topModels.first {
            entries.append(
                .text(
                    "\(L("Top model")): \(topModel.name) (\(Self.pointsString(topModel.points)))",
                    .secondary))
        }
        if !usage.topUsageTypes.isEmpty {
            let summary = usage.topUsageTypes
                .prefix(2)
                .map { "\($0.name): \(Self.pointsString($0.points))" }
                .joined(separator: " · ")
            entries.append(.text("Usage mix: \(summary)", .secondary))
        }
        let recent = usage.recentEntries(limit: 3)
        if !recent.isEmpty {
            entries.append(.text("Recent activity:", .secondary))
            for entry in recent {
                let stamp = Self.poeTimeString(entry.createdAt)
                entries.append(.text(
                    "\(stamp) · \(entry.model) · \(Self.pointsString(entry.points))",
                    .secondary))
            }
        }
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

    private static func pointsString(_ points: Double) -> String {
        let value = max(0, points)
        if value.rounded() == value {
            return "\(UsageFormatter.tokenCountString(Int(value))) points"
        }
        return "\(String(format: "%.1f", value)) points"
    }

    private static func poeTimeString(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }
}
