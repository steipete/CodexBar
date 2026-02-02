import CodexBarCore
import Foundation

extension SettingsStore {
    var traeCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .trae)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .trae) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .trae, field: "cookieHeader", value: newValue)
        }
    }

    var traeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .trae, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .trae) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .trae, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureTraeCookieLoaded() {}
}

extension SettingsStore {
    func traeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.TraeProviderSettings {
        ProviderSettingsSnapshot.TraeProviderSettings(
            cookieSource: self.traeSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.traeSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func traeSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.traeCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .trae),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .trae,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func traeSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.traeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .trae),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .trae).isEmpty { return fallback }
        return .manual
    }
}
