import CodexBarCore
import Foundation

extension SettingsStore {
    var clinePassAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .clinepass)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .clinepass) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .clinepass, field: "apiKey", value: newValue)
        }
    }
}
