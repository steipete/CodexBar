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
            case .api: .api
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

    var claudeAdminAPIKey: String {
        get { self.configSnapshot.providerConfig(for: .claude)?.sanitizedAPIKey ?? "" }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.apiKey = self.normalizedConfigValue(newValue)
            }
            self.logSecretUpdate(provider: .claude, field: "apiKey", value: newValue)
        }
    }

    var claudeSwapEnabled: Bool {
        get { self.configSnapshot.providerConfig(for: .claude)?.claudeSwapEnabled ?? false }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.claudeSwapEnabled = newValue
            }
            self.logProviderModeChange(provider: .claude, field: "claudeSwapEnabled", value: String(newValue))
        }
    }

    var claudeSwapShowSingleAccount: Bool {
        get { self.configSnapshot.providerConfig(for: .claude)?.claudeSwapShowSingleAccount ?? false }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.claudeSwapShowSingleAccount = newValue
            }
            self.logProviderModeChange(
                provider: .claude,
                field: "claudeSwapShowSingleAccount",
                value: String(newValue))
        }
    }

    private static func normalizedClaudeProfileConfigDirs(_ paths: [String]?) -> [String] {
        var seen: Set<String> = []
        var result: [String] = []
        for path in (paths ?? []).compactMap({ ClaudeConfigDirScope.normalizedConfigDirPath($0) }) {
            guard seen.insert(path).inserted else { continue }
            result.append(path)
        }
        return result
    }

    var claudeProfileConfigDirs: [String] {
        Self.normalizedClaudeProfileConfigDirs(
            self.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs)
    }

    var claudeActiveSource: ClaudeActiveSource {
        get { self.configSnapshot.providerConfig(for: .claude)?.claudeActiveSource ?? .ambient }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.claudeActiveSource = newValue
            }
        }
    }

    /// The persisted usage source, restricted to profile-scoped paths while a profile directory is
    /// selected: explicit API/Web modes depend on provider-wide credentials that a profile deliberately
    /// strips, so they resolve as Auto (OAuth -> CLI) instead of failing.
    var claudeEffectiveUsageDataSource: ClaudeUsageDataSource {
        let source = self.claudeUsageDataSource
        guard self.profileClaudeConfigDir(forActiveSource: self.claudeResolvedActiveSource) != nil else {
            return source
        }
        return source == .oauth || source == .cli ? source : .auto
    }

    /// A persisted profile selection whose directory left the allow-list falls back to the ambient account.
    var claudeResolvedActiveSource: ClaudeActiveSource {
        guard let path = self.profileClaudeConfigDir(forActiveSource: self.claudeActiveSource) else {
            return .ambient
        }
        return .profileConfigDir(path: path)
    }

    @discardableResult
    func addClaudeProfileConfigDir(_ path: String) -> Bool {
        guard let normalizedPath = ClaudeConfigDirScope.normalizedConfigDirPath(path),
              !self.claudeProfileConfigDirs.contains(normalizedPath)
        else {
            return false
        }
        let stored = (self.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs ?? []) +
            [ClaudeConfigDirScope.abbreviatedConfigDirPath(normalizedPath)]
        self.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = stored
        }
        self.logProviderModeChange(provider: .claude, field: "claudeProfileConfigDirs", value: "added")
        return true
    }

    func removeClaudeProfileConfigDir(_ path: String) {
        guard let normalizedPath = ClaudeConfigDirScope.normalizedConfigDirPath(path) else { return }
        let remaining = (self.configSnapshot.providerConfig(for: .claude)?.claudeProfileConfigDirs ?? [])
            .filter { ClaudeConfigDirScope.normalizedConfigDirPath($0) != normalizedPath }
        self.updateProviderConfig(provider: .claude) { entry in
            entry.claudeProfileConfigDirs = remaining.isEmpty ? nil : remaining
        }
        // Keep the persisted selection valid: a removed directory falls back to the ambient account.
        if self.claudeActiveSource != .ambient,
           self.profileClaudeConfigDir(forActiveSource: self.claudeActiveSource) == nil
        {
            self.claudeActiveSource = .ambient
        }
        self.logProviderModeChange(provider: .claude, field: "claudeProfileConfigDirs", value: "removed")
    }

    func profileClaudeConfigDir(forActiveSource source: ClaudeActiveSource) -> String? {
        guard case let .profileConfigDir(path) = source else {
            return nil
        }
        guard let normalizedPath = ClaudeConfigDirScope.normalizedConfigDirPath(path),
              self.claudeProfileConfigDirs.contains(normalizedPath)
        else {
            return nil
        }
        return normalizedPath
    }

    var claudeSwapExecutablePath: String {
        get { self.configSnapshot.providerConfig(for: .claude)?.sanitizedClaudeSwapExecutablePath ?? "" }
        set {
            self.updateProviderConfig(provider: .claude) { entry in
                entry.claudeSwapExecutablePath = self.normalizedConfigValue(newValue)
            }
            self.logProviderModeChange(
                provider: .claude,
                field: "claudeSwapExecutablePath",
                value: newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "cleared" : "set")
        }
    }
}

extension SettingsStore {
    func claudeSettingsSnapshot(tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    .ClaudeProviderSettings {
        // A selected profile config directory is the sole credential authority. Provider-wide manual
        // cookies, browser-cookie import, and the Admin API cannot be attributed to a directory, so
        // fetches are restricted to the profile-scoped OAuth and CLI paths.
        if self.profileClaudeConfigDir(forActiveSource: self.claudeResolvedActiveSource) != nil {
            return ProviderSettingsSnapshot.ClaudeProviderSettings(
                usageDataSource: self.claudeEffectiveUsageDataSource,
                webExtrasEnabled: false,
                cookieSource: .off,
                manualCookieHeader: "",
                organizationID: nil)
        }
        let account = self.selectedClaudeTokenAccount(tokenOverride: tokenOverride)
        let routing = self.claudeCredentialRouting(account: account)
        return ProviderSettingsSnapshot.ClaudeProviderSettings(
            usageDataSource: self.claudeSnapshotUsageDataSource(
                routing: routing,
                hasSelectedAccount: account != nil),
            webExtrasEnabled: self.claudeWebExtrasEnabled,
            cookieSource: self.claudeSnapshotCookieSource(tokenOverride: tokenOverride, routing: routing),
            manualCookieHeader: self.claudeSnapshotCookieHeader(
                routing: routing,
                hasSelectedAccount: account != nil),
            organizationID: account?.sanitizedOrganizationID)
    }

    private static func claudeUsageDataSource(from source: ProviderSourceMode?) -> ClaudeUsageDataSource {
        guard let source else { return .auto }
        switch source {
        case .auto, .api:
            return source == .api ? .api : .auto
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
        case .adminAPIKey:
            ""
        case let .webCookie(header):
            header
        }
    }

    private func claudeSnapshotUsageDataSource(
        routing: ClaudeCredentialRouting,
        hasSelectedAccount: Bool) -> ClaudeUsageDataSource
    {
        guard hasSelectedAccount else { return self.claudeUsageDataSource }
        return switch routing {
        case .oauth:
            .oauth
        case .adminAPIKey:
            .api
        case .webCookie:
            .web
        case .none:
            .auto
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
        if routing.adminAPIKey != nil {
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

extension SettingsStore {
    /// Switching profiles must not let the previous account's cached credentials or throttled CLI
    /// result answer the next fetch. Both the old and new profile scopes are invalidated because the
    /// stale entry can live under either identity.
    func invalidateClaudeProfileCaches(around sources: [ClaudeActiveSource]) {
        let base = ProcessInfo.processInfo.environment
        for source in sources {
            let environment = ClaudeConfigDirScope.scopedEnvironment(
                base: base,
                configDir: self.profileClaudeConfigDir(forActiveSource: source))
            ClaudeOAuthCredentialsStore.invalidateCache(environment: environment)
        }
    }
}
