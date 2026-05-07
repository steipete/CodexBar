import CodexBarCore
import Foundation

extension SettingsStore {
    var commandcodeCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .commandcode)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .commandcode) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .commandcode, field: "cookieHeader", value: newValue)
        }
    }

    var commandcodeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .commandcode, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .commandcode) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .commandcode, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureCommandCodeCookieLoaded() {}
}

extension SettingsStore {
    func commandcodeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .CommandCodeProviderSettings {
        ProviderSettingsSnapshot.CommandCodeProviderSettings(
            cookieSource: self.commandcodeSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.commandcodeSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func commandcodeSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.commandcodeCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .commandcode),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .commandcode,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func commandcodeSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.commandcodeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .commandcode),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .commandcode).isEmpty { return fallback }
        return .manual
    }
}
