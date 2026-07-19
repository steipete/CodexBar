import CodexBarCore
import Foundation

extension SettingsStore {
    var sakanaCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .sakana)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .sakana) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .sakana, field: "cookieHeader", value: newValue)
        }
    }
}
