import CodexBarCore
import Foundation

extension SettingsStore {
    var perplexityManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .perplexity)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .perplexity) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .perplexity, field: "cookieHeader", value: newValue)
        }
    }

    var perplexityCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .perplexity, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .perplexity) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .perplexity, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func perplexitySettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .PerplexityProviderSettings {
        // tokenOverride is not used: Perplexity auth is cookie-based, not token-account-based.
        // Manual cookies are handled via perplexityManualCookieHeader in the settings snapshot below.
        _ = tokenOverride
        return ProviderSettingsSnapshot.PerplexityProviderSettings(
            cookieSource: self.perplexityCookieSource,
            manualCookieHeader: self.perplexityManualCookieHeader)
    }
}
