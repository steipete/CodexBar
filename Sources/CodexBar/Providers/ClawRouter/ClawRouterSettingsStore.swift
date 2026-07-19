import CodexBarCore
import Foundation

extension SettingsStore {
    var clawRouterAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .clawrouter)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .clawrouter) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .clawrouter, field: "apiKey", value: newValue)
        }
    }

    var clawRouterBaseURL: String {
        get { self.configSnapshot.providerConfig(for: .clawrouter)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .clawrouter) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }
}
