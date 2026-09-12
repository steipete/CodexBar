import CodexBarCore
import Foundation

extension SettingsStore {
    var fireworksAPIToken: String {
        get { self[providerConfig: .fireworks, field: .apiKey] }
        set { self[providerConfig: .fireworks, field: .apiKey] = newValue }
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
        return config.sanitizedAPIKey != nil
    }
}

extension SettingsStore {
    func fireworksSettingsSnapshot() -> ProviderSettingsSnapshot.FireworksProviderSettings {
        ProviderSettingsSnapshot.FireworksProviderSettings(accountSlug: self.fireworksAccountSlug)
    }
}
