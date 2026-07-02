import CodexBarCore
import Foundation

extension SettingsStore {
    var crossModelAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .crossmodel)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .crossmodel) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .crossmodel, field: "apiKey", value: newValue)
        }
    }
}
