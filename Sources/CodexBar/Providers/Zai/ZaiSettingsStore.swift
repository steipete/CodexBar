import CodexBarCore
import Foundation

extension SettingsStore {
    var zaiAPIRegion: ZaiAPIRegion {
        get {
            let raw = self.configSnapshot.providerConfig(for: .zai)?.region
            return ZaiAPIRegion(rawValue: raw ?? "") ?? .global
        }
        set {
            self.updateProviderConfig(provider: .zai) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    var zaiAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .zai)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .zai) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .zai, field: "apiKey", value: newValue)
        }
    }

    func ensureZaiAPITokenLoaded() {}
}

extension SettingsStore {
    func zaiSettingsSnapshot() -> ProviderSettingsSnapshot.ZaiProviderSettings {
        ProviderSettingsSnapshot.ZaiProviderSettings(apiRegion: self.zaiAPIRegion)
    }
}
