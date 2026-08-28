import CodexBarCore
import Foundation

extension SettingsStore {
    var miMoCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .mimo)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .mimo) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .mimo, field: "cookieHeader", value: newValue)
        }
    }

    var miMoCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .mimo, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .mimo) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .mimo, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureMiMoCookieLoaded() {}
}

extension SettingsStore {
    func miMoSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.MiMoProviderSettings {
        self.resolvedCookieSettings(
            provider: .mimo,
            configuredSource: self.miMoCookieSource,
            configuredHeader: self.miMoCookieHeader,
            tokenOverride: tokenOverride)
    }
}
