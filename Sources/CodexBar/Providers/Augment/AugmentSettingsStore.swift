import CodexBarCore
import Foundation

extension SettingsStore {
    var augmentCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .augment)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .augment) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .augment, field: "cookieHeader", value: newValue)
        }
    }

    var augmentCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .augment, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .augment) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .augment, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureAugmentCookieLoaded() {}
}

extension SettingsStore {
    func augmentSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .AugmentProviderSettings {
        ProviderSettingsSnapshot.AugmentProviderSettings(
            cookieSource: self.augmentSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.augmentSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func augmentSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.augmentCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .augment),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .augment,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func augmentSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.augmentCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .augment),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .augment).isEmpty { return fallback }
        return .manual
    }
}
