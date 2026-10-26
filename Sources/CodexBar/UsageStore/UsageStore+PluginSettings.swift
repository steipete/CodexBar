import CodexBarCore

/// Discovered settings use the same publication ownership as refreshed account credentials.
extension UsageStore {
    func persistPluginSettings(
        provider: UsageProvider, values: [String: String], generation: UInt64?, originalConfigRevision: UInt64)
        async -> ProviderSettingsSaveOutcome
    {
        let outcome = await self.settings.savePluginSettings(provider: provider, values: values) {
            self.settings.providerConfigRevision(for: provider) == originalConfigRevision
                && self.providerConfigMutationIsCurrent(
                    provider: provider, generation: generation, originalConfigRevision: originalConfigRevision)
        }
        if outcome == .saved {
            self.advanceProviderRefreshConfigRevision(provider: provider, generation: generation)
        }
        return outcome
    }
}
