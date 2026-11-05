import Foundation

extension UsageSnapshot {
    /// Applies the reset policy used when the app publishes a successful provider refresh.
    public func backfillingResetTimesForProvider(
        _ provider: UsageProvider,
        from cached: UsageSnapshot?,
        now: Date = .init()) -> UsageSnapshot
    {
        // Provider-specific by design: an omitted feed reset is authoritative, not missing enrichment.
        guard provider != .quotafeed else { return self }
        // Session-bound snapshots cannot inherit another login's dates.
        let requiresBrowserSession = ProviderDescriptorRegistry.descriptor(for: provider)
            .settingsSection.selectedProfileBrowsers != nil
        return requiresBrowserSession ? self : self.backfillingResetTimes(from: cached, now: now)
    }
}
