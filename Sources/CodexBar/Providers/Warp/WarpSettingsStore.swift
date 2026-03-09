import CodexBarCore
import Foundation

extension SettingsStore {
    var warpAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .warp)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .warp) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .warp, field: "apiKey", value: newValue)
        }
    }
}
