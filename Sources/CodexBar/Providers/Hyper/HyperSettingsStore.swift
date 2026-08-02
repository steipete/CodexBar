import CodexBarCore
import Foundation

extension SettingsStore {
    var hyperCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .hyper, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .hyper) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .hyper, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var hyperCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .hyper)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .hyper) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .hyper, field: "cookieHeader", value: newValue)
        }
    }

    var hyperAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .hyper)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .hyper) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .hyper, field: "apiKey", value: newValue)
        }
    }

    func hyperSettingsSnapshot() -> ProviderSettingsSnapshot.CookieProviderSettings {
        ProviderSettingsSnapshot.CookieProviderSettings(
            cookieSource: self.hyperCookieSource,
            manualCookieHeader: self.hyperCookieHeader)
    }
}
