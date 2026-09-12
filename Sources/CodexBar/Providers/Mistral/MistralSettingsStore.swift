import CodexBarCore
import Foundation

extension SettingsStore {
    var mistralCookieHeader: String {
        get { self[providerConfig: .mistral, field: .cookieHeader] }
        set { self[providerConfig: .mistral, field: .cookieHeader] = newValue }
    }

    var mistralCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .mistral, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .mistral) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .mistral, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func mistralSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .MistralProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .mistral,
            configuredSource: self.mistralCookieSource,
            configuredHeader: self.mistralCookieHeader,
            tokenOverride: tokenOverride)
    }
}
