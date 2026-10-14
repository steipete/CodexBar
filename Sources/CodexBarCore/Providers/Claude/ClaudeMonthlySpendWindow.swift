import Foundation

extension UsageSnapshot {
    /// Presentation only: Claude reports no reset for monthly caps, so use the month of the cost observation.
    package var claudeMonthlySpendWindow: NamedRateWindow? {
        guard self.loginMethod(for: .claude) != "Admin API",
              let cost = self.providerCost, let spend = cost.spendLimitWindow else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return NamedRateWindow(
            id: "claude-extra-usage",
            title: "Extra usage",
            window: RateWindow(
                usedPercent: spend.usedPercent,
                windowMinutes: ProviderPaceCapability.monthlyWindowSentinelMinutes,
                resetsAt: cost.resetsAt ?? calendar.dateInterval(of: .month, for: cost.updatedAt)?.end,
                resetDescription: nil))
    }
}
