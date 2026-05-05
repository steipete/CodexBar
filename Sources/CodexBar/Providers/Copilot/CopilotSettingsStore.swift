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

    var copilotEnterpriseHost: String {
        get { self.configSnapshot.providerConfig(for: .copilot)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .copilot) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }

    func ensureCopilotAPITokenLoaded() {}
}

extension SettingsStore {
    func copilotSettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CopilotProviderSettings
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .copilot,
            settings: self,
            override: tokenOverride)
        let token = account?.token ?? self.copilotAPIToken
        let host = CopilotDeviceFlow.normalizedHost(self.copilotEnterpriseHost)
        return ProviderSettingsSnapshot.CopilotProviderSettings(
            apiToken: self.normalizedConfigValue(token),
            enterpriseHost: host == CopilotDeviceFlow.defaultHost ? nil : host)
    }
}
