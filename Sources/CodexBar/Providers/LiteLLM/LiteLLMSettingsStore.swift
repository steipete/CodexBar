import CodexBarCore
import Foundation

extension SettingsStore {
    var liteLLMAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .litellm)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .litellm) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .litellm, field: "apiKey", value: newValue)
        }
    }

    var liteLLMBaseURL: String {
        get {
            self.configSnapshot.providerConfig(for: .litellm)?.sanitizedEnterpriseHost ?? ""
        }
        set {
            self.updateProviderConfig(provider: .litellm) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }
}
