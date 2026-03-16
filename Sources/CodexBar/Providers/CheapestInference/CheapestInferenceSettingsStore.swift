import CodexBarCore
import Foundation

extension SettingsStore {
    var cheapestInferenceAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .cheapestinference)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .cheapestinference) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .cheapestinference, field: "apiKey", value: newValue)
        }
    }
}
