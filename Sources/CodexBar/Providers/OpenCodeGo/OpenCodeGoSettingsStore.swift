import CodexBarCore
import Foundation

extension SettingsStore {
    var opencodegoWorkspaceID: String {
        get { self.configSnapshot.providerConfig(for: .opencodego)?.workspaceID ?? "" }
        set {
            let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = trimmed.isEmpty ? nil : trimmed
            self.updateProviderConfig(provider: .opencodego) { entry in
                entry.workspaceID = value
            }
        }
    }

    var opencodegoCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .opencodego)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .opencodego) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .opencodego, field: "cookieHeader", value: newValue)
        }
    }

    var opencodegoCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .opencodego, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .opencodego) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .opencodego, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureOpenCodeGoCookieLoaded() {}
}

extension SettingsStore {
    func opencodegoSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .OpenCodeProviderSettings
    {
        ProviderSettingsSnapshot.OpenCodeProviderSettings(
            cookieSource: self.opencodegoSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.opencodegoSnapshotCookieHeader(tokenOverride: tokenOverride),
            workspaceID: self.opencodegoSnapshotWorkspaceID)
    }

    private func opencodegoSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.opencodegoCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .opencodego),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .opencodego,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func opencodegoSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.opencodegoCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .opencodego),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .opencodego).isEmpty { return fallback }
        return .manual
    }

    private var opencodegoSnapshotWorkspaceID: String? {
        guard let workspaceID = self.configSnapshot.providerConfig(for: .opencodego)?.workspaceID else {
            return nil
        }
        let trimmed = workspaceID.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
