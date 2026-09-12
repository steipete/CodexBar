import CodexBarCore
import Foundation

extension SettingsStore {
    var devinBearerToken: String {
        get { self[providerConfig: .devin, field: .cookieHeader] }
        set { self[providerConfig: .devin, field: .cookieHeader] = newValue }
    }

    var devinCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .devin, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .devin) }
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
