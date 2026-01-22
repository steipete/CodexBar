import CodexBarCore
import Foundation

extension SettingsStore {
    var firmwareAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .firmware)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .firmware) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .firmware, field: "apiKey", value: newValue)
        }
    }

    func ensureFirmwareAPITokenLoaded() {}
}
