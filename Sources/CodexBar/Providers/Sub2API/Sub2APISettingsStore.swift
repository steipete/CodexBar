import CodexBarCore
import Foundation

extension SettingsStore {
    var sub2APIAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .sub2api)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .sub2api) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .sub2api, field: "apiKey", value: newValue)
        }
    }

    var sub2APIBaseURL: String {
        get { self.configSnapshot.providerConfig(for: .sub2api)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .sub2api) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }
}
