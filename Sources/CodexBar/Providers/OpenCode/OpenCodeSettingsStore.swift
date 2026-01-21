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
        ProviderSettingsSnapshot.OpenCodeProviderSettings(
            cookieSource: self.opencodeSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.opencodeSnapshotCookieHeader(tokenOverride: tokenOverride),
            workspaceID: self.opencodeWorkspaceID)
    }

    private func opencodeSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.opencodeCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .opencode),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .opencode,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func opencodeSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.opencodeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .opencode),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .opencode).isEmpty { return fallback }
        return .manual
    }
}
