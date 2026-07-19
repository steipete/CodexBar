import CodexBarCore
import Foundation

extension SettingsStore {
    var neuralWattAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .neuralwatt)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .neuralwatt) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .neuralwatt, field: "apiKey", value: newValue)
        }
    }
}
