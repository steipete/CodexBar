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
    static let rateUpdatedAtDefaultsKey = "spendDashboardRateUpdatedAt"

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

    func currencyString(_ amount: Double, sourceCurrencyCode: String) -> String {
        let display = self.displayAmount(amount, sourceCurrencyCode: sourceCurrencyCode)
        return UsageFormatter.currencyString(display.amount, currencyCode: display.currencyCode)
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

    func converted(_ snapshot: CostUsageTokenSnapshot) -> CostUsageTokenSnapshot {
        guard self.shouldConvert(currencyCode: snapshot.currencyCode) else { return snapshot }
        return CostUsageTokenSnapshot(
            sessionTokens: snapshot.sessionTokens,
            sessionCostUSD: self.convertedUSD(snapshot.sessionCostUSD),
            sessionRequests: snapshot.sessionRequests,
            last30DaysTokens: snapshot.last30DaysTokens,
            last30DaysCostUSD: self.convertedUSD(snapshot.last30DaysCostUSD),
            last30DaysRequests: snapshot.last30DaysRequests,
            currencyCode: "GBP",
            historyDays: snapshot.historyDays,
            historyCoverageIsEstablished: snapshot.historyCoverageIsEstablished,
            historyLabel: snapshot.historyLabel,
            meteredCostUSD: self.convertedUSD(snapshot.meteredCostUSD),
            credentialScopeFingerprint: snapshot.credentialScopeFingerprint,
            daily: snapshot.daily.map(self.converted),
            projects: snapshot.projects.map(self.converted),
            sessions: snapshot.sessions.map(self.converted),
            updatedAt: snapshot.updatedAt)
    }

    private func converted(_ entry: CostUsageDailyReport.Entry) -> CostUsageDailyReport.Entry {
        CostUsageDailyReport.Entry(
            date: entry.date,
            inputTokens: entry.inputTokens,
            outputTokens: entry.outputTokens,
            cacheReadTokens: entry.cacheReadTokens,
            cacheCreationTokens: entry.cacheCreationTokens,
            totalTokens: entry.totalTokens,
            requestCount: entry.requestCount,
            costUSD: self.convertedUSD(entry.costUSD),
            modelsUsed: entry.modelsUsed,
            modelBreakdowns: entry.modelBreakdowns?.map(self.converted))
    }

    private func converted(
        _ breakdown: CostUsageDailyReport.ModelBreakdown) -> CostUsageDailyReport.ModelBreakdown
    {
        CostUsageDailyReport.ModelBreakdown(
            modelName: breakdown.modelName,
            costUSD: self.convertedUSD(breakdown.costUSD),
            totalTokens: breakdown.totalTokens,
            requestCount: breakdown.requestCount,
            standardCostUSD: self.convertedUSD(breakdown.standardCostUSD),
            priorityCostUSD: self.convertedUSD(breakdown.priorityCostUSD),
            standardTokens: breakdown.standardTokens,
            priorityTokens: breakdown.priorityTokens)
    }

    private func converted(_ project: CostUsageProjectBreakdown) -> CostUsageProjectBreakdown {
        CostUsageProjectBreakdown(
            name: project.name,
            path: project.path,
            totalTokens: project.totalTokens,
            totalCostUSD: self.convertedUSD(project.totalCostUSD),
            daily: project.daily.map(self.converted),
            modelBreakdowns: project.modelBreakdowns?.map(self.converted),
            sources: project.sources.map(self.converted))
    }

    private func converted(_ source: CostUsageProjectSourceBreakdown) -> CostUsageProjectSourceBreakdown {
        CostUsageProjectSourceBreakdown(
            name: source.name,
            path: source.path,
            totalTokens: source.totalTokens,
            totalCostUSD: self.convertedUSD(source.totalCostUSD),
            daily: source.daily.map(self.converted),
            modelBreakdowns: source.modelBreakdowns?.map(self.converted))
    }

    private func converted(_ session: CostUsageSessionBreakdown) -> CostUsageSessionBreakdown {
        CostUsageSessionBreakdown(
            sessionID: session.sessionID,
            lastActivity: session.lastActivity,
            inputTokens: session.inputTokens,
            cachedInputTokens: session.cachedInputTokens,
            outputTokens: session.outputTokens,
            totalTokens: session.totalTokens,
            requestCount: session.requestCount,
            costUSD: self.convertedUSD(session.costUSD),
            modelBreakdowns: session.modelBreakdowns.map(self.converted))
    }

    private func shouldConvert(currencyCode: String) -> Bool {
        self.displaysGBP &&
            currencyCode.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "USD"
    }

    private func displayAmount(
        _ amount: Double,
        sourceCurrencyCode: String) -> (amount: Double, currencyCode: String)
    {
        guard self.shouldConvert(currencyCode: sourceCurrencyCode) else {
            return (amount, sourceCurrencyCode)
        }
        let converted = amount * self.usdToGBPRate
        return converted.isFinite ? (converted, "GBP") : (amount, sourceCurrencyCode)
    }

    private func convertedUSD(_ amount: Double?) -> Double? {
        guard let amount else { return nil }
        let converted = amount * self.usdToGBPRate
        return converted.isFinite ? converted : nil
    }
}
