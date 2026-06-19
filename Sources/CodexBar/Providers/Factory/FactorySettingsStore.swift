import CodexBarCore
import Foundation

extension SettingsStore {
    var factoryCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .factory)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .factory, field: "cookieHeader", value: newValue)
        }
    }

    var factoryCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .factory, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .factory, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureFactoryCookieLoaded() {}
}

extension SettingsStore {
    func factorySettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .FactoryProviderSettings {
        self.resolvedCookieSettings(
            provider: .factory,
            configuredSource: self.factoryCookieSource,
            configuredHeader: self.factoryCookieHeader,
            tokenOverride: tokenOverride)
    }
}
