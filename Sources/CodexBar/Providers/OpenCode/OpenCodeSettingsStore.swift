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
        get { self.configSnapshot.providerConfig(for: .opencode)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .opencode, field: "cookieHeader", value: newValue)
        }
    }

    var opencodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .opencode, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .opencode) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .opencode, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureOpenCodeCookieLoaded() {}
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
