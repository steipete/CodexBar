import CodexBarCore
import Foundation

extension SettingsStore {
    var opencodeWorkspaceID: String {
        get { self.configSnapshot.providerConfig(for: .opencode)?.workspaceID ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.workspaceID = value
            }
        }
    }

    var opencodeCookieHeader: String {
        get { self[providerConfig: .opencode, field: .cookieHeader] }
        set { self[providerConfig: .opencode, field: .cookieHeader] = newValue }
    }

    var opencodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .opencode, fallback: .auto) }
        set { self.setCookieSource(newValue, provider: .opencode) }
    }
}

extension SettingsStore {
    func opencodeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .OpenCodeProviderSettings {
        let cookieSettings: ProviderSettingsSnapshot.CookieProviderSettings = self.resolvedCookieSettings(
            provider: .opencode,
            configuredSource: self.opencodeCookieSource,
            configuredHeader: self.opencodeCookieHeader,
            tokenOverride: tokenOverride)
        return ProviderSettingsSnapshot.OpenCodeProviderSettings(
            cookieSource: cookieSettings.cookieSource,
            manualCookieHeader: cookieSettings.manualCookieHeader,
            workspaceID: self.opencodeWorkspaceID)
    }
}
