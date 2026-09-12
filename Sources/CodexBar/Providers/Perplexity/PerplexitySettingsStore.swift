import CodexBarCore
import Foundation

extension SettingsStore {
    var perplexityManualCookieHeader: String {
        get { self[providerConfig: .perplexity, field: .cookieHeader] }
        set { self[providerConfig: .perplexity, field: .cookieHeader] = newValue }
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
        self.resolvedCookieSettings(
            provider: .perplexity,
            configuredSource: self.perplexityCookieSource,
            configuredHeader: self.perplexityManualCookieHeader,
            tokenOverride: tokenOverride)
    }
}
