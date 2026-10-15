extension ClaudeUsageSnapshot {
    func replacingWebExtras(
        extraRateWindows: [NamedRateWindow],
        providerCost: ProviderCostSnapshot?) -> ClaudeUsageSnapshot
    {
        var snapshot = self
        snapshot.extraRateWindows = extraRateWindows
        snapshot.providerCost = providerCost
        return snapshot
    }
}
