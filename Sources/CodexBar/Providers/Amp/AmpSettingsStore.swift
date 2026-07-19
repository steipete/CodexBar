import CodexBarCore
import Foundation

extension SettingsStore {
    var ampUsageDataSource: ProviderSourceMode {
        get { self.configSnapshot.providerConfig(for: .amp)?.source ?? .auto }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.source = newValue == .auto ? nil : newValue
            }
            self.logProviderModeChange(provider: .amp, field: "source", value: newValue.rawValue)
        }
    }

    var ampAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .amp)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .amp, field: "apiKey", value: newValue)
        }
    }

    var ampCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .amp)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .amp, field: "cookieHeader", value: newValue)
        }
    }

    var ampCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .amp, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .amp, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureAmpAPITokenLoaded() {}

    func ensureAmpCookieLoaded() {}
}

extension SettingsStore {
    func ampSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.AmpProviderSettings {
        self.resolvedCookieSettings(
            provider: .amp,
            configuredSource: self.ampCookieSource,
            configuredHeader: self.ampCookieHeader,
            tokenOverride: tokenOverride)
    }
}
