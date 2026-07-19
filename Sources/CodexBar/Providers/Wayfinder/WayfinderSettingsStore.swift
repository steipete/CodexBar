import CodexBarCore
import Foundation

extension SettingsStore {
    var wayfinderGatewayURL: String {
        get { self.configSnapshot.providerConfig(for: .wayfinder)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .wayfinder) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }
}
