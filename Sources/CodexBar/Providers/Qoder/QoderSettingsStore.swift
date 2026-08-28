import CodexBarCore
import Foundation

extension SettingsStore {
    var qoderCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .qoder)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .qoder) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .qoder, field: "cookieHeader", value: newValue)
        }
    }

    var qoderCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .qoder, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .qoder) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .qoder, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureQoderCookieLoaded() {}
}

extension SettingsStore {
    func qoderSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .QoderProviderSettings
    {
        self.resolvedCookieSettings(
            provider: .qoder,
            configuredSource: self.qoderCookieSource,
            configuredHeader: self.qoderCookieHeader,
            tokenOverride: tokenOverride)
    }
}
