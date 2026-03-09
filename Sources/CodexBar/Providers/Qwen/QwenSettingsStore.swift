import CodexBarCore
import Foundation

extension SettingsStore {
    var qwenAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .qwen)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .qwen) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .qwen, field: "apiKey", value: newValue)
        }
    }
}
