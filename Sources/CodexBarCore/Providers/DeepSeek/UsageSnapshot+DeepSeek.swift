extension UsageSnapshot {
    public func withoutDeepSeekDetailedUsage(
        state: DeepSeekDetailedUsageState = .unavailable) -> UsageSnapshot
    {
        self.replacing(
            costUsage: .value(nil),
            details: .value([]),
            deepseekDetailedUsageState: .value(state))
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
