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
        get { self[providerConfig: .amp, field: .apiKey] }
        set { self[providerConfig: .amp, field: .apiKey] = newValue }
    }

    var ampCookieHeader: String {
        get { self[providerConfig: .amp, field: .cookieHeader] }
        set { self[providerConfig: .amp, field: .cookieHeader] = newValue }
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
