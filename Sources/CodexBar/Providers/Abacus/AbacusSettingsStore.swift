import CodexBarCore
import Foundation

extension SettingsStore {
    var abacusCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .abacus)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .abacus) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .abacus, field: "cookieHeader", value: newValue)
        }
    }

    var abacusCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .abacus, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .abacus) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .abacus, field: "cookieSource", value: newValue.rawValue)
        }
    }
}

extension SettingsStore {
    func abacusSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .AbacusProviderSettings {
        ProviderSettingsSnapshot.AbacusProviderSettings(
            cookieSource: self.abacusSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.abacusSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func abacusSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.abacusCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .abacus),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .abacus,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func abacusSnapshotCookieSource(tokenOverride _: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.abacusCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .abacus),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .abacus).isEmpty { return fallback }
        return .manual
    }
}
