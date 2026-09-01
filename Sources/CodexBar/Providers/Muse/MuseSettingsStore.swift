import CodexBarCore
import Foundation

extension SettingsStore {
    var museAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .muse)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .muse, field: "apiKey", value: newValue)
        }
    }

    var museBaseURL: String {
        get { self.configSnapshot.providerConfig(for: .muse)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .muse) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }

    func ensureMuseAPITokenLoaded() {}
}
