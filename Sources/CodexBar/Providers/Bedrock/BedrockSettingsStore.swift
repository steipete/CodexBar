import CodexBarCore
import Foundation

extension SettingsStore {
    var bedrockAccessKeyID: String {
        get { self.configSnapshot.providerConfig(for: .bedrock)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .bedrock) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .bedrock, field: "accessKeyID", value: newValue)
        }
    }

    var bedrockSecretAccessKey: String {
        get { self.configSnapshot.providerConfig(for: .bedrock)?.sanitizedSecretKey ?? "" }
        set {
            self.updateProviderConfig(provider: .bedrock) { entry in
                entry.secretKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .bedrock, field: "secretAccessKey", value: newValue)
        }
    }

    var bedrockRegion: String {
        get { self.configSnapshot.providerConfig(for: .bedrock)?.region ?? "" }
        set {
            self.updateProviderConfig(provider: .bedrock) { entry in
                entry.region = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .bedrock, field: "region", value: newValue)
        }
    }
}
