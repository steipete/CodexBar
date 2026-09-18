import CodexBarCore

extension ProviderConfig {
    /// Display preferences must not change ownership of fetched or cached usage.
    var fetchIdentityConfig: Self {
        var copy = self
        copy.accentColor = nil
        copy.hiddenUsageItemIDs = nil
        return copy
    }
}
