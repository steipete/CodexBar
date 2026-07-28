import CodexBarCore
import Foundation

extension SettingsStore {
    var hyperAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .hyper)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .hyper) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .hyper, field: "apiKey", value: newValue)
        }
    }
}
