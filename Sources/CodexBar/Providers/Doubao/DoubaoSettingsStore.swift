import CodexBarCore
import Foundation

extension SettingsStore {
    var doubaoAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .doubao)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .doubao) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .doubao, field: "apiKey", value: newValue)
        }
    }

    var doubaoSecretAccessKey: String {
        get { self.configSnapshot.providerConfig(for: .doubao)?.sanitizedSecretKey ?? "" }
        set {
            self.updateProviderConfig(provider: .doubao) { entry in
                entry.secretKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .doubao, field: "secretAccessKey", value: newValue)
        }
    }

    var doubaoRegion: String {
        get { self.configSnapshot.providerConfig(for: .doubao)?.sanitizedRegion ?? "" }
        set {
            self.updateProviderConfig(provider: .doubao) { entry in
                entry.region = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .doubao, field: "region", value: newValue)
        }
    }
}
