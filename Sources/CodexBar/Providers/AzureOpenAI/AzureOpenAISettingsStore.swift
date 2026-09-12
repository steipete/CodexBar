import CodexBarCore
import Foundation

extension SettingsStore {
    var azureOpenAIAPIKey: String {
        get { self[providerConfig: .azureopenai, field: .apiKey] }
        set { self[providerConfig: .azureopenai, field: .apiKey] = newValue }
    }

    var azureOpenAIEndpoint: String {
        get { self.configSnapshot.providerConfig(for: .azureopenai)?.sanitizedEnterpriseHost ?? "" }
        set {
            self.updateProviderConfig(provider: .azureopenai) { entry in
                entry.enterpriseHost = self.normalizedConfigValue(newValue)
            }
        }
    }

    var azureOpenAIDeploymentName: String {
        get { self.configSnapshot.providerConfig(for: .azureopenai)?.sanitizedWorkspaceID ?? "" }
        set {
            self.updateProviderConfig(provider: .azureopenai) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}
