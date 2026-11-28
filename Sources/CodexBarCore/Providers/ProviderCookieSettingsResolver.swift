import Foundation

public enum ProviderCookieSettingsResolver {
    public static func resolve(
        provider: UsageProvider,
        configuredSource: ProviderCookieSource,
        configuredHeader: String?,
        selectedAccount: ProviderTokenAccount?) -> ProviderSettingsSnapshot.CookieProviderSettings
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider),
              case .cookieHeader = support.injection,
              let selectedAccount
        else {
            return ProviderSettingsSnapshot.CookieProviderSettings(
                cookieSource: configuredSource,
                manualCookieHeader: configuredHeader)
        }

        // A provider that retires its saved account on Off must not keep sending a stored header.
        guard !(support.disabledCookiesSuppressAccount && configuredSource == .off) else {
            return ProviderSettingsSnapshot.CookieProviderSettings(cookieSource: .off, manualCookieHeader: nil)
        }

        return ProviderSettingsSnapshot.CookieProviderSettings(
            cookieSource: support.requiresManualCookieSource ? .manual : configuredSource,
            manualCookieHeader: TokenAccountSupportCatalog.normalizedCookieHeader(
                for: provider,
                token: selectedAccount.token))
    }
}
