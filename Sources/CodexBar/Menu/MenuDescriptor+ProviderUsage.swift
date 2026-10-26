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
                "\(L("Latest")): \(cost)" + Self.mistralTokenSuffix(latest.checkedTotalTokens),
                .secondary))
        }
        let totalCost = UsageFormatter.convertedCostString(
            usage.totalCost,
            preferredCurrency: preferredCurrencyCode,
            providerCurrency: usage.currency)
        entries.append(.text(
            "\(L("Month")): \(totalCost)" + Self.mistralTokenSuffix(usage.checkedTotalTokens),
            .secondary))
        if let top = Self.topMistralModel(from: usage.daily) {
            entries.append(.text("\(L("Top model")): \(top)", .secondary))
        }
    }

    private static func mistralTokenSuffix(_ tokens: Int?) -> String {
        guard let tokens else { return "" }
        return " · \(UsageFormatter.tokenCountString(tokens)) \(L("tokens"))"
    }

    private static func topMistralModel(from entries: [MistralDailyUsageBucket]) -> String? {
        var tokens: [String: Int] = [:]
        for entry in entries {
            for model in entry.models {
                guard let total = model.checkedTotalTokens,
                      let sum = CheckedSum.integers([tokens[model.name, default: 0], total])
                else { return nil }
                tokens[model.name] = sum
            }
        }
        return tokens.max {
            if $0.value == $1.value {
                return $0.key > $1.key
            }
            return $0.value < $1.value
        }?.key
    }
}
