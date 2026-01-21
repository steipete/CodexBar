import CodexBarCore
import Foundation

extension SettingsStore {
    var factoryCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .factory)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .factory, field: "cookieHeader", value: newValue)
        }
    }

    var factoryCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .factory, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .factory) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .factory, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureFactoryCookieLoaded() {}
}

extension SettingsStore {
    func factorySettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .FactoryProviderSettings {
        ProviderSettingsSnapshot.FactoryProviderSettings(
            cookieSource: self.factorySnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.factorySnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func factorySnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.factoryCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .factory),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .factory,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func factorySnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.factoryCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .factory),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .factory).isEmpty { return fallback }
        return .manual
    }
}
