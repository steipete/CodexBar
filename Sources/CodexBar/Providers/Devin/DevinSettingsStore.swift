import CodexBarCore
import Foundation

extension SettingsStore {
    var devinBearerToken: String {
        get { self.configSnapshot.providerConfig(for: .devin)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .devin) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .devin, field: "cookieHeader", value: newValue)
        }
    }

    var devinCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .devin, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .devin) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .devin, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var devinOrganization: String {
        get { self.configSnapshot.providerConfig(for: .devin)?.sanitizedWorkspaceID ?? "" }
        set {
            self.updateProviderConfig(provider: .devin) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}

extension SettingsStore {
    func devinSettingsSnapshot(tokenOverride _: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .DevinProviderSettings {
        ProviderSettingsSnapshot.DevinProviderSettings(
            cookieSource: self.devinCookieSource,
            manualBearerToken: self.devinBearerToken,
            organization: self.devinOrganization)
    }
}
