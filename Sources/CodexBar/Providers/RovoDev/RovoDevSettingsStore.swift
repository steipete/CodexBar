import CodexBarCore
import Foundation

extension SettingsStore {
    var rovoDevAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .rovodev)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .rovodev) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .rovodev, field: "apiKey", value: newValue)
        }
    }

    /// Stores the Atlassian email used for Basic auth.
    /// Mapped to ``ProviderConfig.workspaceID`` since there is no dedicated email field.
    var rovoDevEmail: String {
        get { self.configSnapshot.providerConfig(for: .rovodev)?.sanitizedWorkspaceID ?? "" }
        set {
            self.updateProviderConfig(provider: .rovodev) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }

    /// Stores the optional Atlassian Cloud ID/Site ID for billing-site context.
    /// Mapped to ``ProviderConfig.secretKey`` since there is no dedicated cloud ID field.
    var rovoDevCloudId: String {
        get { self.configSnapshot.providerConfig(for: .rovodev)?.sanitizedSecretKey ?? "" }
        set {
            self.updateProviderConfig(provider: .rovodev) { entry in
                entry.secretKey = self.normalizedConfigValue(newValue)
            }
        }
    }
}
