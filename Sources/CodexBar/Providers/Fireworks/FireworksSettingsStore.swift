import CodexBarCore
import Foundation

extension SettingsStore {
    var fireworksAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .fireworks)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .fireworks) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .fireworks, field: "apiKey", value: newValue)
        }
    }

    var fireworksAccountSlug: String {
        get { self.configSnapshot.providerConfig(for: .fireworks)?.sanitizedAccountSlug ?? "" }
        set {
            self.updateProviderConfig(provider: .fireworks) { entry in
                entry.accountSlug = self.normalizedConfigValue(newValue)
            }
        }
    }

    var hasFireworksCredentials: Bool {
        guard let config = self.configSnapshot.providerConfig(for: .fireworks) else { return false }
        return config.sanitizedAPIKey != nil && config.sanitizedAccountSlug != nil
    }
}

extension SettingsStore {
    func fireworksSettingsSnapshot() -> ProviderSettingsSnapshot.FireworksProviderSettings {
        ProviderSettingsSnapshot.FireworksProviderSettings(accountSlug: self.fireworksAccountSlug)
    }
}
