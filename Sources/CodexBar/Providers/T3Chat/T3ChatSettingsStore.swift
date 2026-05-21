import CodexBarCore
import Foundation

extension SettingsStore {
    var t3ChatCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .t3chat)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .t3chat) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .t3chat, field: "cookieHeader", value: newValue)
        }
    }

    var t3ChatCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .t3chat, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .t3chat) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .t3chat, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureT3ChatCookieLoaded() {}
}

extension SettingsStore {
    func t3ChatSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .T3ChatProviderSettings {
        ProviderSettingsSnapshot.T3ChatProviderSettings(
            cookieSource: self.t3ChatSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.t3ChatSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func t3ChatSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.t3ChatCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .t3chat),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .t3chat,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func t3ChatSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.t3ChatCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .t3chat),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .t3chat).isEmpty { return fallback }
        return .manual
    }
}
