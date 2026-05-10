import CodexBarCore
import Foundation

extension SettingsStore {
    var crofAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .crof)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .crof) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .crof, field: "apiKey", value: newValue)
        }
    }
}
