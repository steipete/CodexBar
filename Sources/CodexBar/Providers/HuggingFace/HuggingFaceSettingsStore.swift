import CodexBarCore
import Foundation

extension SettingsStore {
    var huggingFaceAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .huggingface)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .huggingface) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .huggingface, field: "apiKey", value: newValue)
        }
    }

    var hasHuggingFaceCredentials: Bool {
        guard let config = self.configSnapshot.providerConfig(for: .huggingface) else { return false }
        return config.sanitizedAPIKey != nil
    }
}
