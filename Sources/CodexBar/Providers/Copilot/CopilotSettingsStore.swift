import CodexBarCore
import Foundation

extension SettingsStore {
    var copilotAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .copilot)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .copilot, field: "apiKey", value: newValue)
        }
    }

    func ensureCopilotAPITokenLoaded() {}
}

extension SettingsStore {
    func copilotSettingsSnapshot() -> ProviderSettingsSnapshot.CopilotProviderSettings {
        ProviderSettingsSnapshot.CopilotProviderSettings()
    }
}
