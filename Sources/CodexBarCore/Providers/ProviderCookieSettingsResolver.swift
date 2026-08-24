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

        let routesAsCookie: Bool = switch support.injection {
        case .cookieHeader:
            true
        case .environment:
            // A provider that migrated to API-key token accounts may still hold accounts saved
            // under the old cookie-header injection; route those specific accounts as cookies
            // instead of sending a stored Cookie header as a bogus bearer token.
            support.legacyCookieDetector?(selectedAccount.token) ?? false
        }
        guard routesAsCookie else {
            return ProviderSettingsSnapshot.CookieProviderSettings(
                cookieSource: configuredSource,
                manualCookieHeader: configuredHeader)
        }

        return ProviderSettingsSnapshot.CookieProviderSettings(
            cookieSource: support.requiresManualCookieSource ? .manual : configuredSource,
            manualCookieHeader: TokenAccountSupportCatalog.normalizedCookieHeader(
                for: provider,
                token: selectedAccount.token))
    }
}
