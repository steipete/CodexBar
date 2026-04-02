import CodexBarCore
import Foundation

extension SettingsStore {
    var mistralAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .mistral)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .mistral) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .mistral, field: "apiKey", value: newValue)
        }
    }

    var mistralManualCookieHeader: String {
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

    func ensureMistralAPITokenLoaded() {}

    func ensureMistralCookieLoaded() {}
}

extension SettingsStore {
    func mistralSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .MistralProviderSettings {
        _ = tokenOverride
        return ProviderSettingsSnapshot.MistralProviderSettings(
            cookieSource: self.mistralCookieSource,
            manualCookieHeader: self.mistralManualCookieHeader)
    }
}
