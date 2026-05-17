import CodexBarCore
import Foundation

extension SettingsStore {
    var deepgramAPIToken: String {
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
            self.configSnapshot.providerConfig(for: .deepgram)?.workspaceID ?? ""
        }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed

            self.updateProviderConfig(provider: .deepgram) { entry in
                entry.workspaceID = value
            }
        }
    }
}

