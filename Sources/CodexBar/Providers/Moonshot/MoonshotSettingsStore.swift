import CodexBarCore
import Foundation

extension SettingsStore {
    var moonshotAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .moonshot)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .moonshot) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .moonshot, field: "apiKey", value: newValue)
        }
    }

    var moonshotRegion: MoonshotRegion {
        get {
            let raw = self.configSnapshot.providerConfig(for: .moonshot)?.region
            return MoonshotRegion(rawValue: raw ?? "") ?? .international
        }
        set {
            self.updateProviderConfig(provider: .moonshot) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    func ensureMoonshotAPITokenLoaded() {}
}

extension SettingsStore {
    func moonshotSettingsSnapshot() -> ProviderSettingsSnapshot.MoonshotProviderSettings {
        ProviderSettingsSnapshot.MoonshotProviderSettings(region: self.moonshotRegion)
    }
}
