import CodexBarCore
import Foundation

let spendDashboardDefaultUSDToGBPRate = 0.749

func spendDashboardDefaultsToGBP(storedPreference: Bool?) -> Bool {
    storedPreference ?? true
}

func spendDashboardUSDToGBPRate(_ rate: Double) -> Double {
    guard rate.isFinite else { return spendDashboardDefaultUSDToGBPRate }
    return min(max(rate, 0.01), 10)
}

struct SpendDisplayCurrencyPreference: Equatable, Sendable {
    static let displayGBPDefaultsKey = "spendDashboardDisplayGBP"
    static let usdToGBPRateDefaultsKey = "spendDashboardUSDToGBPRate"

    let displaysGBP: Bool
    let usdToGBPRate: Double

    init(displaysGBP: Bool, usdToGBPRate: Double) {
        self.displaysGBP = displaysGBP
        self.usdToGBPRate = spendDashboardUSDToGBPRate(usdToGBPRate)
    }

    static func load(userDefaults: UserDefaults) -> Self {
        let storedDisplayGBP = userDefaults.object(forKey: self.displayGBPDefaultsKey) as? Bool
        let storedRate = userDefaults.object(forKey: self.usdToGBPRateDefaultsKey) as? Double
        return Self(
            displaysGBP: spendDashboardDefaultsToGBP(storedPreference: storedDisplayGBP),
            usdToGBPRate: storedRate ?? spendDashboardDefaultUSDToGBPRate)
    }

    func converted(_ summary: WidgetSnapshot.TokenUsageSummary) -> WidgetSnapshot.TokenUsageSummary {
        guard self.shouldConvert(currencyCode: summary.currencyCode) else { return summary }
        return WidgetSnapshot.TokenUsageSummary(
            sessionCostUSD: self.convertedUSD(summary.sessionCostUSD),
            sessionTokens: summary.sessionTokens,
            last30DaysCostUSD: self.convertedUSD(summary.last30DaysCostUSD),
            last30DaysTokens: summary.last30DaysTokens,
            currencyCode: "GBP",
            sessionLabel: summary.sessionLabel,
            last30DaysLabel: summary.last30DaysLabel,
            updatedAt: summary.updatedAt)
    }

    func converted(
        _ point: WidgetSnapshot.DailyUsagePoint,
        sourceCurrencyCode: String) -> WidgetSnapshot.DailyUsagePoint
    {
        guard self.shouldConvert(currencyCode: sourceCurrencyCode) else { return point }
        return WidgetSnapshot.DailyUsagePoint(
            dayKey: point.dayKey,
            totalTokens: point.totalTokens,
            costUSD: self.convertedUSD(point.costUSD))
    }

    func converted(_ cost: ProviderCostSnapshot) -> ProviderCostSnapshot {
        guard self.shouldConvert(currencyCode: cost.currencyCode) else { return cost }
        let convertedValues = [
            cost.used,
            cost.limit,
            cost.nextRegenAmount,
            cost.personalUsed,
        ].compactMap(\.self).map { $0 * self.usdToGBPRate }
        guard convertedValues.allSatisfy(\.isFinite) else { return cost }
        return ProviderCostSnapshot(
            used: cost.used * self.usdToGBPRate,
            limit: cost.limit * self.usdToGBPRate,
            currencyCode: "GBP",
            period: cost.period,
            resetsAt: cost.resetsAt,
            nextRegenAmount: cost.nextRegenAmount.map { $0 * self.usdToGBPRate },
            personalUsed: cost.personalUsed.map { $0 * self.usdToGBPRate },
            updatedAt: cost.updatedAt)
    }

    private func shouldConvert(currencyCode: String) -> Bool {
        self.displaysGBP &&
            currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "USD"
    }

    private func convertedUSD(_ amount: Double?) -> Double? {
        guard let amount else { return nil }
        let converted = amount * self.usdToGBPRate
        return converted.isFinite ? converted : nil
    }
}
