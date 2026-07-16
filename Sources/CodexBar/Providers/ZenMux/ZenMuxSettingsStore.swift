import CodexBarCore
import Foundation

extension SettingsStore {
    var zenMuxManagementAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .zenmux)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .zenmux) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .zenmux, field: "apiKey", value: newValue)
        }
    }
}
