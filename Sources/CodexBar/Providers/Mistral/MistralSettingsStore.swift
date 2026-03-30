import CodexBarCore
import Foundation

extension SettingsStore {
    var mistralCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .mistral)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .mistral) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .mistral, field: "cookieHeader", value: newValue)
        }
    }

    var mistralCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .mistral, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .mistral) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .mistral, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureMistralCookieLoaded() {}
}

extension SettingsStore {
    func mistralSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
        .MistralProviderSettings
    {
        ProviderSettingsSnapshot.MistralProviderSettings(
            cookieSource: self.mistralSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.mistralSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func mistralSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.mistralCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .mistral),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .mistral,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func mistralSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.mistralCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .mistral),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .mistral).isEmpty { return fallback }
        return .manual
    }
}
