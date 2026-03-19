import CodexBarCore
import Foundation

extension SettingsStore {
    var grokAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .grok)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .grok) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .grok, field: "apiKey", value: newValue)
        }
    }

    /// Management API key, stored in the cookieHeader field (Grok uses API tokens, not cookies)
    var grokManagementToken: String {
        get { self.configSnapshot.providerConfig(for: .grok)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .grok) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .grok, field: "managementKey", value: newValue)
        }
    }

    /// Team ID, stored in the workspaceID field
    var grokTeamID: String {
        get { self.configSnapshot.providerConfig(for: .grok)?.workspaceID ?? "default" }
        set {
            self.updateProviderConfig(provider: .grok) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}
