extension UsageSnapshot {
    public func withoutDeepSeekDetailedUsage(
        state: DeepSeekDetailedUsageState = .unavailable) -> UsageSnapshot
    {
        self.replacing(
            costUsage: .value(nil),
            details: .value([]),
            deepseekDetailedUsageState: .value(state))
    }

    public func withDeepSeekUsageSummary(
        _ summary: DeepSeekUsageSummary,
        detailedUsageState: DeepSeekDetailedUsageState = .available) -> UsageSnapshot
    {
        self.replacing(
            costUsage: .value(summary.toCostUsageTokenSnapshot()),
            details: .value(DeepSeekUsageSnapshot.detailSections(for: summary, referenceDate: self.updatedAt)),
            deepseekDetailedUsageState: .value(detailedUsageState))
    }

    public func withDeepSeekProjectedUsage(
        costUsage: CostUsageTokenSnapshot,
        details: [ProviderDetailSection],
        detailedUsageState: DeepSeekDetailedUsageState = .available) -> UsageSnapshot
    {
        self.replacing(
            costUsage: .value(costUsage),
            details: .value(details),
            deepseekDetailedUsageState: .value(detailedUsageState))
    }

    public func preservingDeepSeekPlatformProfiles(from previous: UsageSnapshot?) -> UsageSnapshot {
        guard self.deepseekDetailedUsageState == .unavailable,
              self.deepseekPlatformProfiles.isEmpty,
              let previous,
              !previous.deepseekPlatformProfiles.isEmpty
        else { return self }
        return self.replacing(
            deepseekPlatformProfiles: .value(previous.deepseekPlatformProfiles))
    }
}
