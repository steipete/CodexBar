import CodexBarCore
import Foundation

extension SettingsStore {
    var notionCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .notion)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .notion) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .notion, field: "cookieHeader", value: newValue)
        }
    }

    var notionCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .notion, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .notion) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .notion, field: "cookieSource", value: newValue.rawValue)
        }
    }

    var notionWorkspaceID: String {
        get { self.configSnapshot.providerConfig(for: .notion)?.sanitizedWorkspaceID ?? "" }
        set {
            self.updateProviderConfig(provider: .notion) { entry in
                entry.workspaceID = self.normalizedConfigValue(newValue)
            }
        }
    }
}

extension SettingsStore {
    func notionSettingsSnapshot(
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.NotionProviderSettings
    {
        // Resolved directly rather than through `resolvedCookieSettings`, whose generic construction
        // can only carry the two cookie fields and would drop the workspace override.
        let resolved = ProviderCookieSettingsResolver.resolve(
            provider: .notion,
            configuredSource: self.notionCookieSource,
            configuredHeader: self.notionCookieHeader,
            selectedAccount: ProviderTokenAccountSelection.selectedAccount(
                provider: .notion,
                settings: self,
                override: tokenOverride))
        let workspaceID = self.notionWorkspaceID
        return ProviderSettingsSnapshot.NotionProviderSettings(
            cookieSource: resolved.cookieSource,
            manualCookieHeader: resolved.manualCookieHeader,
            workspaceID: workspaceID.isEmpty ? nil : workspaceID)
    }
}
