import CodexBarCore
import Foundation

extension SettingsStore {
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
            manualCookieHeader: self.codexSnapshotCookieHeader(tokenOverride: tokenOverride))
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
