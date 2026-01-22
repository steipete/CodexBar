import CodexBarCore
import Foundation

extension SettingsStore {
    var ampCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .amp)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .amp, field: "cookieHeader", value: newValue)
        }
    }

    var ampCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .amp, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .amp) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .amp, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureAmpCookieLoaded() {}
}

extension SettingsStore {
    func ampSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.AmpProviderSettings {
        ProviderSettingsSnapshot.AmpProviderSettings(
            cookieSource: self.ampSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.ampSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func ampSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.ampCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .amp),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .amp,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func ampSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.ampCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .amp),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .amp).isEmpty { return fallback }
        return .manual
    }
}
