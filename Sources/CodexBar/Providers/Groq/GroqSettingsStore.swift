import CodexBarCore
import Foundation

extension SettingsStore {
    var groqSessionToken: String {
        get { self.configSnapshot.providerConfig(for: .groq)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .groq) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .groq, field: "apiKey", value: newValue)
        }
    }
}
