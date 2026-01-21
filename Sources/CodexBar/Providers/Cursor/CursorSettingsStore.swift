import CodexBarCore
import Foundation

extension SettingsStore {
    var cursorCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .cursor)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .cursor, field: "cookieHeader", value: newValue)
        }
    }

    var cursorCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .cursor, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .cursor) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .cursor, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureCursorCookieLoaded() {}
}

extension SettingsStore {
    func cursorSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .CursorProviderSettings {
        ProviderSettingsSnapshot.CursorProviderSettings(
            cookieSource: self.cursorSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.cursorSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private func cursorSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.cursorCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .cursor),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .cursor,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func cursorSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.cursorCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .cursor),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .cursor).isEmpty { return fallback }
        return .manual
    }
}
