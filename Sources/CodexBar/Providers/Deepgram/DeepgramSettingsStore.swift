import CodexBarCore
import Foundation

extension SettingsStore {
    var deepgramAPIKey: String {
        get {
            self.configSnapshot.providerConfig(for: .deepgram)?.sanitizedAPIKey ?? ""
        }
        set {
            self.updateProviderConfig(provider: .deepgram) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .deepgram, field: "apiKey", value: newValue)
        }
    }

    var deepgramProjectID: String {
        get {
            self.configSnapshot.providerConfig(for: .deepgram)?.sanitizedWorkspaceID ?? ""
        }
        set {
            self.updateProviderConfig(provider: .deepgram) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}
