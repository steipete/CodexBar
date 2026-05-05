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
        let account = self.selectedClaudeTokenAccount(tokenOverride: tokenOverride)
        let routing = self.claudeCredentialRouting(account: account)
        return ProviderSettingsSnapshot.ClaudeProviderSettings(
            usageDataSource: self.claudeUsageDataSource,
            webExtrasEnabled: self.claudeWebExtrasEnabled,
            cookieSource: self.claudeSnapshotCookieSource(tokenOverride: tokenOverride, routing: routing),
            manualCookieHeader: self.claudeSnapshotCookieHeader(
                routing: routing,
                hasSelectedAccount: account != nil))
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

    private func claudeSnapshotCookieHeader(
        routing: ClaudeCredentialRouting,
        hasSelectedAccount: Bool) -> String
    {
        switch routing {
        case .none:
            hasSelectedAccount ? "" : self.claudeCookieHeader
        case .oauth:
            ""
        case let .webCookie(header):
            header
        }
    }

    private func claudeSnapshotCookieSource(
        tokenOverride: TokenAccountOverride?,
        routing: ClaudeCredentialRouting) -> ProviderCookieSource
    {
        let fallback = self.claudeCookieSource
        guard let support = TokenAccountSupportCatalog.support(for: .claude),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if routing.isOAuth {
            return .off
        }
        if self.tokenAccounts(for: .claude).isEmpty { return fallback }
        return .manual
    }

    private func claudeCredentialRouting(account: ProviderTokenAccount?) -> ClaudeCredentialRouting {
        let manualCookieHeader = account == nil ? self.claudeCookieHeader : nil
        return ClaudeCredentialRouting.resolve(
            tokenAccountToken: account?.token,
            manualCookieHeader: manualCookieHeader)
    }

    private func selectedClaudeTokenAccount(tokenOverride: TokenAccountOverride?) -> ProviderTokenAccount? {
        ProviderTokenAccountSelection.selectedAccount(
            provider: .claude,
            settings: self,
            override: tokenOverride)
    }
}
