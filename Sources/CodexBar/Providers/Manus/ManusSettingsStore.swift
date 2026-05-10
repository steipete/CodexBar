import CodexBarCore
import Foundation

extension SettingsStore {
    var manusManualCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .manus)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .manus) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .manus, field: "cookieHeader", value: newValue)
        }
    }

    var manusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .manus, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .manus) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .manus, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func manusSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.ManusProviderSettings {
        ProviderSettingsSnapshot.ManusProviderSettings(
            cookieSource: self.manusSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.manusSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func manusSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.manusManualCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .manus),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .manus,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func manusSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.manusCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .manus),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .manus).isEmpty { return fallback }
        return .manual
    }
}
