import CodexBarCore
import Foundation

extension SettingsStore {
    var abacusCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .abacus)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .abacus) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .abacus, field: "cookieHeader", value: newValue)
        }
    }

    var abacusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .abacus, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .abacus) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .abacus, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func abacusSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .AbacusProviderSettings {
        self.resolvedCookieSettings(
            provider: .abacus,
            configuredSource: self.abacusCookieSource,
            configuredHeader: self.abacusCookieHeader,
            tokenOverride: tokenOverride)
    }
}
