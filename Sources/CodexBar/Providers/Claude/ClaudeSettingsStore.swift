import CodexBarCore
import Foundation

extension SettingsStore {
    var claudeUsageDataSource: ClaudeUsageDataSource {
        get {
            let source = self.configSnapshot.providerConfig(for: .claude)?.source
            return Self.claudeUsageDataSource(from: source)
        }
        set {
            let source: ProviderSourceMode? = switch newValue {
            case .auto: .auto
            case .oauth: .oauth
            case .web: .web
            case .cli: .cli
            }
            self.updateProviderConfig(provider: .claude) { entry in
                entry.source = source
            }
            self.logProviderModeChange(provider: .claude, field: "usageSource", value: newValue.rawValue)
            if newValue != .cli {
                self.claudeWebExtrasEnabled = false
            }
        }
    }

    var claudeCookieHeader: String {
        get { self.configSnapshot.providerConfig(for: .claude)?.sanitizedCookieHeader ?? "" }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieHeader = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .claude, field: "cookieHeader", value: newValue)
        }
    }

    var claudeCookieSource: ProviderCookieSource {
        get { self.resolvedCookieSource(provider: .claude, fallback: .auto) }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.cookieSource = newValue
            }
            self.logProviderModeChange(provider: .claude, field: "cookieSource", value: newValue.rawValue)
        }
    }

    func ensureClaudeCookieLoaded() {}
}

extension SettingsStore {
    func claudeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .ClaudeProviderSettings {
        ProviderSettingsSnapshot.ClaudeProviderSettings(
            usageDataSource: self.claudeUsageDataSource,
            webExtrasEnabled: self.claudeWebExtrasEnabled,
            cookieSource: self.claudeSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.claudeSnapshotCookieHeader(tokenOverride: tokenOverride))
    }

    private static func claudeUsageDataSource(from source: ProviderSourceMode?) -> ClaudeUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .api:
            return .auto
        case .web:
            return .web
        case .cli:
            return .cli
        case .oauth:
            return .oauth
        }
    }

    private func claudeSnapshotCookieHeader(tokenOverride: TokenAccountOverride?) -> String {
        let fallback = self.claudeCookieHeader
        guard let support = TokenAccountSupportCatalog.support(for: .claude),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        guard let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .claude,
            settings: self,
            override: tokenOverride)
        else {
            return fallback
        }
        if TokenAccountSupportCatalog.isClaudeOAuthToken(account.token) {
            return ""
        }
        return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
    }

    private func claudeSnapshotCookieSource(tokenOverride: TokenAccountOverride?) -> ProviderCookieSource {
        let fallback = self.claudeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .claude),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if let account = ProviderTokenAccountSelection.selectedAccount(
            provider: .claude,
            settings: self,
            override: tokenOverride),
            TokenAccountSupportCatalog.isClaudeOAuthToken(account.token)
        {
            return .off
        }
        if self.tokenAccounts(for: .claude).isEmpty { return fallback }
        return .manual
    }
}
