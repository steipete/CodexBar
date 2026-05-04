import CodexBarCore
import Foundation

extension SettingsStore {
    var mimoManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .mimo)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .mimo) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .mimo, field: "cookieHeader", value: newValue)
        }
    }

    var mimoCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .mimo, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .mimo) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .mimo, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func mimoSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.MiMoProviderSettings {
        _ = tokenOverride
        return ProviderSettingsSnapshot.MiMoProviderSettings(
            cookieSource: self.mimoCookieSource,
            manualCookieHeader: self.mimoManualCookieHeader)
    }
}
