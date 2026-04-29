import CodexBarCore
import Foundation

extension SettingsStore {
    var deepSeekAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .deepseek)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .deepseek) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .deepseek, field: "apiKey", value: newValue)
        }
    }

    func ensureDeepSeekAPITokenLoaded() {}
}
