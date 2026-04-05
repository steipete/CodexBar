import CodexBarCore
import Foundation

extension SettingsStore {
    var bedrockAccessKeyID: String {
        get { self.configSnapshot.providerConfig(for: .bedrock)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .bedrock) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .bedrock, field: "apiKey", value: newValue)
        }
    }

    var bedrockSecretAccessKey: String {
        get {
            let raw = self.configSnapshot.providerConfig(for: .bedrock)?.sanitizedCookieHeader ?? ""
            return raw
        }
        set {
            self.updateProviderConfig(provider: .bedrock) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
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
