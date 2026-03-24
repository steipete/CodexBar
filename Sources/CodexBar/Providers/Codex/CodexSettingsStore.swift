import CodexBarCore
import Foundation

extension SettingsStore {
    /// When `true`, CodexBar never treats `~/.codex` as an implicit menu-bar account; add accounts under Accounts
    /// (OAuth, API key, or path).
    var codexExplicitAccountsOnly: Bool {
        get { self.configSnapshot.providerConfig(for: .codex)?.codexExplicitAccountsOnly ?? false }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.codexExplicitAccountsOnly = newValue
                if newValue,
                   let token = entry.tokenAccounts,
                   !token.accounts.isEmpty,
                   token.activeIndex < 0
                {
                    entry.tokenAccounts = ProviderTokenAccountData(
                        version: token.version,
                        accounts: token.accounts,
                        activeIndex: 0)
                }
            }
            self.repairCodexShellIntegrationIfNeeded()
        }
    }

    /// When `true`, enables multi-account support for Codex (account switcher, drag reorder, per-account tabs).
    /// Defaults to `false` (single-account / upstream behavior).
    var codexMultipleAccountsEnabled: Bool {
        get { self.configSnapshot.providerConfig(for: .codex)?.codexMultipleAccountsEnabled ?? false }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.codexMultipleAccountsEnabled = newValue
            }
        }
    }

    /// When `true` (default), shows "Buy Credits…" in the Codex menu. Persisted per-provider; `nil` in config means
    /// enabled.
    var codexBuyCreditsMenuEnabled: Bool {
        get { self.configSnapshot.providerConfig(for: .codex)?.buyCreditsMenuEnabled ?? true }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.buyCreditsMenuEnabled = newValue
            }
        }
    }

    var codexUsageDataSource: CodexUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .codex)?.source
            return Self.codexUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .codex) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .codex, field: "usageSource", value: newValue.rawValue)
        }
    }

    var codexCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .codex, field: "cookieHeader", value: newValue)
        }
    }

    var codexCookieSource: ProviderCookieSource {
        get {
            let resolved = self.resolvedCookieSource(provider: .codex, fallback: .auto)
            return self.openAIWebAccessEnabled ? resolved : .off
        }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .codex, field: "cookieSource", value: newValue.rawValue)
            self.openAIWebAccessEnabled = newValue.isEnabled
        }
    }

    func ensureCodexCookieLoaded() {}
}

extension SettingsStore {
    func codexSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CodexProviderSettings {
        ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: self.codexUsageDataSource,
            cookieSource: self.codexSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.codexSnapshotCookieHeader(tokenOverride: tokenOverride),
            explicitAccountsOnly: self.codexExplicitAccountsOnly)
    }

    private static func codexUsageDataSource(from source: ProviderSourceMode?) -> CodexUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web, .api:
            return .auto
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private func codexSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.codexCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .codex,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func codexSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.codexCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .codex),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if self.tokenAccounts(for: .codex).isEmpty { return fallback }
        return .manual
    }
}
