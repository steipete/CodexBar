import CodexBarCore
import Foundation

extension SettingsStore {
    var zaiAPIRegion: ZaiAPIRegion {
        get {
            let raw = self.configSnapshot.providerConfig(for: .zai)?.region
            return ZaiAPIRegion(rawValue: raw ?? "") ?? .global
        }
        set {
            self.updateProviderConfig(provider: .zai) { entry in
                entry.region = newValue.rawValue
            }
        }
    }

    var zaiAPIToken: String {
        get { self.configSnapshot.providerConfig(for: .zai)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .zai) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .zai, field: "apiKey", value: newValue)
        }
    }

    func ensureZaiAPITokenLoaded() {}
}

extension SettingsStore {
    func zaiSettingsSnapshot(
        tokenOverride: TokenAccountOverride? = nil) -> ProviderSettingsSnapshot.ZaiProviderSettings
    {
        let usageScope = self.zaiEffectiveUsageScope(tokenOverride: tokenOverride)
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .zai,
            settings: self,
            override: tokenOverride)
        let teamContext: ZaiBigModelTeamContext? = if usageScope == .team {
            ZaiBigModelTeamContext(
                organizationID: account?.sanitizedOrganizationID,
                projectID: account?.sanitizedWorkspaceID)
        } else {
            nil
        }
        return ProviderSettingsSnapshot.ZaiProviderSettings(
            apiRegion: self.zaiAPIRegion,
            usageScope: usageScope,
            teamContext: teamContext)
    }

    func zaiEffectiveUsageScope(tokenOverride: TokenAccountOverride? = nil) -> ZaiUsageScope {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .zai,
            settings: self,
            override: tokenOverride)
        return Self.zaiUsageScope(from: account) ?? .personal
    }

    private static func zaiUsageScope(from account: ProviderTokenAccount?) -> ZaiUsageScope? {
        guard let raw = account?.sanitizedUsageScope?.lowercased() else { return nil }
        return ZaiUsageScope(rawValue: raw)
    }
}
