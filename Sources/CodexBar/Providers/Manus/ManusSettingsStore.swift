import CodexBarCore
import Foundation

extension SettingsStore {
    var manusManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .manus)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .manus) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .manus, field: "cookieHeader", value: newValue)
        }
    }

    var manusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .manus, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .manus) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .manus, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func manusSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.ManusProviderSettings {
        self.resolvedCookieSettings(
            provider: .manus,
            configuredSource: self.manusCookieSource,
            configuredHeader: self.manusManualCookieHeader,
            tokenOverride: tokenOverride)
    }
}
