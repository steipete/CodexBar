import CodexBarCore
import Foundation

extension SettingsStore {
    var mistralCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .mistral)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .mistral) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .mistral, field: "cookieHeader", value: newValue)
        }
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

    func ensureMistralCookieLoaded() {}
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
