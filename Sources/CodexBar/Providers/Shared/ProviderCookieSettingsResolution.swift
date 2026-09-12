import CodexBarCore

extension SettingsStore {
    func resolvedCookieSettings<Settings: ProviderCookieSettings>(
        provider: UsageProvider,
        tokenOverride: TokenAccountOverride?) -> Settings
    {
        self.resolvedCookieSettings(
            provider: provider,
            configuredSource: self.resolvedCookieSource(provider: provider, fallback: .auto),
            configuredHeader: self[providerConfig: provider, field: .cookieHeader],
            tokenOverride: tokenOverride)
    }

    func resolvedCookieSettings<Settings: ProviderCookieSettings>(
        provider: UsageProvider,
        configuredSource: ProviderCookieSource,
        configuredHeader: String?,
        tokenOverride: TokenAccountOverride?) -> Settings
    {
        let resolved = ProviderCookieSettingsResolver.resolve(
            provider: provider,
            configuredSource: configuredSource,
            configuredHeader: configuredHeader,
            selectedAccount: ProviderTokenAccountSelection.selectedAccount(
                provider: provider,
                settings: self,
                override: tokenOverride))
        return Settings(
            cookieSource: resolved.cookieSource,
            manualCookieHeader: resolved.manualCookieHeader)
    }
}
