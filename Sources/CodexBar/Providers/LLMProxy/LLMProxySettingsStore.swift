import CodexBarCore
import Foundation

extension SettingsStore {
    var llmProxyAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .llmproxy)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .llmproxy) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .llmproxy, field: "apiKey", value: newValue)
        }
    }

    var llmProxyBaseURL: String {
        get {
            self.configSnapshot.providerConfig(for: .llmproxy)?.sanitizedEnterpriseHost ?? ""
        }
        set {
            self.updateProviderConfig(provider: .llmproxy) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }
}
