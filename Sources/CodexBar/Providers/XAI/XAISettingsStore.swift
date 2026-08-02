import CodexBarCore
import Foundation

extension SettingsStore {
    var xaiManagementAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .xai)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .xai) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .xai, field: "apiKey", value: newValue)
        }
    }

    var xaiTeamID: String {
        get {
            self.configSnapshot.providerConfig(for: .xai)?.sanitizedWorkspaceID ?? ""
        }
        set {
            self.updateProviderConfig(provider: .xai) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}
