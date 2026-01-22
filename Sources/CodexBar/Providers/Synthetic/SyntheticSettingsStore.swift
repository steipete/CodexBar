import CodexBarCore
import Foundation

extension SettingsStore {
    var syntheticAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .synthetic)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .synthetic) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .synthetic, field: "apiKey", value: newValue)
        }
    }

    func ensureSyntheticAPITokenLoaded() {}
}
