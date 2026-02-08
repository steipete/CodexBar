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
            case .api: .api
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

    var codexCLIProxyBaseURL: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedAPIBaseURL ?? "" }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.apiBaseURL = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .codex, field: "apiBaseURL", value: newValue)
        }
    }

    var codexCLIProxyManagementKey: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .codex, field: "apiKey", value: newValue)
        }
    }

    var codexCLIProxyAuthIndex: String {
        get { self.configSnapshot.providerConfig(for: .codex)?.sanitizedAPIAuthIndex ?? "" }
        set {
            self.updateProviderConfig(provider: .codex) { entry in
                entry.apiAuthIndex = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(provider: .codex, field: "apiAuthIndex", value: newValue)
        }
    }

    func ensureCodexCookieLoaded() {}
}

extension SettingsStore {
    func codexSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot.CodexProviderSettings {
        let resolvedBaseURL: String = {
            let providerValue = self.codexCLIProxyBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
            if !providerValue.isEmpty { return providerValue }
            return self.cliProxyGlobalBaseURL
        }()
        let resolvedManagementKey: String = {
            let providerValue = self.codexCLIProxyManagementKey.trimmingCharacters(in: .whitespacesAndNewlines)
            if !providerValue.isEmpty { return providerValue }
            return self.cliProxyGlobalManagementKey
        }()
        let resolvedAuthIndex: String = {
            let providerValue = self.codexCLIProxyAuthIndex.trimmingCharacters(in: .whitespacesAndNewlines)
            if !providerValue.isEmpty { return providerValue }
            return self.cliProxyGlobalAuthIndex
        }()
        return ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: self.codexUsageDataSource,
            cookieSource: self.codexSnapshotCookieSource(tokenOverride: tokenOverride),
            manualCookieHeader: self.codexSnapshotCookieHeader(tokenOverride: tokenOverride),
            cliProxyBaseURL: resolvedBaseURL,
            cliProxyManagementKey: resolvedManagementKey,
            cliProxyAuthIndex: resolvedAuthIndex)
    }

    private static func codexUsageDataSource(from source: ProviderSourceMode?) -> CodexUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .web:
            return .auto
        case .api:
            return .api
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
