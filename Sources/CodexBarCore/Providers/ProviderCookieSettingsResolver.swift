import Foundation

public enum ProviderCookieSettingsResolver {
    public static func resolve(
        provider: UsageProvider,
        configuredSource: ProviderCookieSource,
        configuredHeader: String?,
        selectedAccount: ProviderTokenAccount?) -> ProviderSettingsSnapshot.CookieProviderSettings
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider),
              let selectedAccount
        else {
            return ProviderSettingsSnapshot.CookieProviderSettings(
                cookieSource: configuredSource,
                manualCookieHeader: configuredHeader)
        }

        switch support.injection {
        case .cookieHeader:
            return ProviderSettingsSnapshot.CookieProviderSettings(
                cookieSource: support.requiresManualCookieSource ? .manual : configuredSource,
                manualCookieHeader: TokenAccountSupportCatalog.normalizedCookieHeader(
                    for: provider,
                    token: selectedAccount.token))
        case .environment:
            // A provider that migrated to API-key token accounts may still hold accounts saved
            // under the old cookie-header injection; route those specific accounts as cookies
            // instead of sending a stored Cookie header as a bogus bearer token. The provider's
            // own requiresManualCookieSource no longer implies manual mode here (it now reflects
            // the API-key default), so force .manual unconditionally: OpenCodeWebCookieSupport
            // only reads manualCookieHeader when the source is .manual, and leaving it at
            // whatever the provider's default is (often .auto) would silently fall through to a
            // different, unrelated cached/imported browser cookie instead of this account's.
            guard support.legacyCookieDetector?(selectedAccount.token) == true else {
                return ProviderSettingsSnapshot.CookieProviderSettings(
                    cookieSource: configuredSource,
                    manualCookieHeader: configuredHeader)
            }
            return ProviderSettingsSnapshot.CookieProviderSettings(
                cookieSource: .manual,
                manualCookieHeader: TokenAccountSupportCatalog.normalizedCookieHeader(
                    for: provider,
                    token: selectedAccount.token))
        }
    }
}
