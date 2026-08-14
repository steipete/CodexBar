import CodexBarCore
import Foundation

extension SettingsStore {
    var museAPIToken: String {
        get {
            guard let config = self.configSnapshot.providerConfig(for: .muse) else { return "" }
            return config.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .muse, field: "apiKey", value: newValue)
        }
    }

    var museBaseURL: String {
        get {
            guard let config = self.configSnapshot.providerConfig(for: .muse) else { return "" }
            return config.sanitizedBaseURL ?? ""
        }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.baseURL = self.normalizedConfigValue(newValue)
            }
        }
    }

    func ensureMuseAPITokenLoaded() {}

    var hasMuseAPIToken: Bool {
        guard let config = self.configSnapshot.providerConfig(for: .muse) else { return false }
        return config.sanitizedAPIKey != nil
    }

    var configuredMuseBaseURL: String? {
        guard let raw = self.configSnapshot.providerConfig(for: .muse)?.baseURL?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !raw.isEmpty
        else {
            return nil
        }
        return raw
    }
}

extension SettingsStore {
    func museSettingsSnapshot() -> ProviderSettingsSnapshot.MuseProviderSettings {
        ProviderSettingsSnapshot.MuseProviderSettings(baseURL: self.configuredMuseBaseURL)
    }
}
