import CodexBarCore
import Foundation

extension SettingsStore {
    var aiAndAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .aiand)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .aiand) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .aiand, field: "apiKey", value: newValue)
        }
    }
}
