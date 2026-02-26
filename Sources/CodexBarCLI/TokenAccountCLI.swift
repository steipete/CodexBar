import CodexBarCore
import Commander
import Foundation

struct TokenAccountCLISelection: Sendable {
    let label: String?
    let index: Int?
    let allAccounts: Bool

    var usesOverride: Bool {
        self.label != nil || self.index != nil || self.allAccounts
    }
}

enum TokenAccountCLIError: LocalizedError {
    case noAccounts(UsageProvider)
    case accountNotFound(UsageProvider, String)
    case indexOutOfRange(UsageProvider, Int, Int)

    var errorDescription: String? {
        switch self {
        case let .noAccounts(provider):
            "No token accounts configured for \(provider.rawValue)."
        case let .accountNotFound(provider, label):
            "No token account labeled '\(label)' for \(provider.rawValue)."
        case let .indexOutOfRange(provider, index, count):
            "Token account index \(index) out of range for \(provider.rawValue) (1-\(count))."
        }
    }
}

struct TokenAccountCLIContext {
    let selection: TokenAccountCLISelection
    let config: CodexBarConfig
    let accountsByProvider: [UsageProvider: ProviderTokenAccountData]

    init(selection: TokenAccountCLISelection, config: CodexBarConfig, verbose _: Bool) throws {
        self.selection = selection
        self.config = config
        self.accountsByProvider = Dictionary(uniqueKeysWithValues: config.providers.compactMap { provider in
            guard let accounts = provider.tokenAccounts else { return nil }
            return (provider.id, accounts)
        })
    }

    func resolvedAccounts(for provider: UsageProvider) throws -> [ProviderTokenAccount] {
        guard TokenAccountSupportCatalog.support(for: provider) != nil else { return [] }
        guard let data = self.accountsByProvider[provider], !data.accounts.isEmpty else {
            if self.selection.usesOverride {
                throw TokenAccountCLIError.noAccounts(provider)
            }
            return []
        }

        if self.selection.allAccounts {
            return data.accounts
        }

        if let label = self.selection.label?.trimmingCharacters(in: .whitespacesAndNewlines), !label.isEmpty {
            let normalized = label.lowercased()
            if let match = data.accounts.first(where: { $0.label.lowercased() == normalized }) {
                return [match]
            }
            throw TokenAccountCLIError.accountNotFound(provider, label)
        }

        if let index = self.selection.index {
            guard index >= 0, index < data.accounts.count else {
                throw TokenAccountCLIError.indexOutOfRange(provider, index + 1, data.accounts.count)
            }
            return [data.accounts[index]]
        }

        let clamped = data.clampedActiveIndex()
        return [data.accounts[clamped]]
    }

    func settingsSnapshot(for provider: UsageProvider, account: ProviderTokenAccount?) -> ProviderSettingsSnapshot? {
        let config = self.providerConfig(for: provider)
        let cookieHeader = self.manualCookieHeader(provider: provider, account: account, config: config)
        let cookieSource = self.cookieSource(provider: provider, account: account, config: config)

        switch provider {
        case .codex:
            return self.makeSnapshot(
                codex: ProviderSettingsSnapshot.CodexProviderSettings(
                    usageDataSource: .auto,
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .claude:
            let claudeSource: ClaudeUsageDataSource = if provider == .claude,
                                                         let account,
                                                         TokenAccountSupportCatalog.isClaudeOAuthToken(account.token)
            {
                .oauth
            } else {
                .auto
            }
            let effectiveSource = (claudeSource == .oauth) ? ProviderCookieSource.off : cookieSource
            return self.makeSnapshot(
                claude: ProviderSettingsSnapshot.ClaudeProviderSettings(
                    usageDataSource: claudeSource,
                    webExtrasEnabled: false,
                    cookieSource: effectiveSource,
                    manualCookieHeader: claudeSource == .oauth ? nil : cookieHeader))
        case .cursor:
            return self.makeSnapshot(
                cursor: ProviderSettingsSnapshot.CursorProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .opencode:
            return self.makeSnapshot(
                opencode: ProviderSettingsSnapshot.OpenCodeProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader,
                    workspaceID: config?.workspaceID))
        case .factory:
            return self.makeSnapshot(
                factory: ProviderSettingsSnapshot.FactoryProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .minimax:
            return self.makeSnapshot(
                minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader,
                    apiRegion: self.resolveMiniMaxRegion(config)))
        case .augment:
            return self.makeSnapshot(
                augment: ProviderSettingsSnapshot.AugmentProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .amp:
            return self.makeSnapshot(
                amp: ProviderSettingsSnapshot.AmpProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .ollama:
            return self.makeSnapshot(
                ollama: ProviderSettingsSnapshot.OllamaProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .kimi:
            return self.makeSnapshot(
                kimi: ProviderSettingsSnapshot.KimiProviderSettings(
                    cookieSource: cookieSource,
                    manualCookieHeader: cookieHeader))
        case .zai:
            return self.makeSnapshot(
                zai: ProviderSettingsSnapshot.ZaiProviderSettings(apiRegion: self.resolveZaiRegion(config)))
        case .jetbrains:
            return self.makeSnapshot(
                jetbrains: ProviderSettingsSnapshot.JetBrainsProviderSettings(
                    ideBasePath: nil))
        case .antigravity:
            let usageSourceRaw = config?.usageSource ?? ""
            let usageSource = AntigravityUsageSource(rawValue: usageSourceRaw) ?? .auto
            return self.makeSnapshot(
                antigravity: ProviderSettingsSnapshot.AntigravityProviderSettings(
                    usageSource: usageSource,
                    accountLabel: account?.label,
                    tokenAccounts: config?.tokenAccounts))
        case .gemini, .copilot, .kiro, .vertexai, .kimik2, .synthetic, .openrouter, .warp:
            return nil
        }
    }

    private func makeSnapshot(
        codex: ProviderSettingsSnapshot.CodexProviderSettings? = nil,
        claude: ProviderSettingsSnapshot.ClaudeProviderSettings? = nil,
        cursor: ProviderSettingsSnapshot.CursorProviderSettings? = nil,
        opencode: ProviderSettingsSnapshot.OpenCodeProviderSettings? = nil,
        factory: ProviderSettingsSnapshot.FactoryProviderSettings? = nil,
        minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings? = nil,
        zai: ProviderSettingsSnapshot.ZaiProviderSettings? = nil,
        kimi: ProviderSettingsSnapshot.KimiProviderSettings? = nil,
        augment: ProviderSettingsSnapshot.AugmentProviderSettings? = nil,
        amp: ProviderSettingsSnapshot.AmpProviderSettings? = nil,
        ollama: ProviderSettingsSnapshot.OllamaProviderSettings? = nil,
        jetbrains: ProviderSettingsSnapshot.JetBrainsProviderSettings? = nil,
        antigravity: ProviderSettingsSnapshot.AntigravityProviderSettings? = nil) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot.make(
            codex: codex,
            claude: claude,
            cursor: cursor,
            opencode: opencode,
            factory: factory,
            minimax: minimax,
            zai: zai,
            kimi: kimi,
            augment: augment,
            amp: amp,
            ollama: ollama,
            jetbrains: jetbrains,
            antigravity: antigravity)
    }

    func environment(
        base: [String: String],
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> [String: String]
    {
        let providerConfig = self.providerConfig(for: provider)
        var env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: base,
            provider: provider,
            config: providerConfig)
        // If token account is selected, use its token instead of config's apiKey
        if let account,
           let override = TokenAccountSupportCatalog.envOverride(for: provider, token: account.token)
        {
            for (key, value) in override {
                env[key] = value
            }
        }
        return env
    }

    func applyAccountLabel(
        _ snapshot: UsageSnapshot,
        provider: UsageProvider,
        account: ProviderTokenAccount) -> UsageSnapshot
    {
        let label = account.label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !label.isEmpty else { return snapshot }
        let existing = snapshot.identity(for: provider)
        let email = existing?.accountEmail?.trimmingCharacters(in: .whitespacesAndNewlines)
        let resolvedEmail = (email?.isEmpty ?? true) ? label : email
        let identity = ProviderIdentitySnapshot(
            providerID: provider,
            accountEmail: resolvedEmail,
            accountOrganization: existing?.accountOrganization,
            loginMethod: existing?.loginMethod)
        return snapshot.withIdentity(identity)
    }

    func effectiveSourceMode(
        base: ProviderSourceMode,
        provider: UsageProvider,
        account: ProviderTokenAccount?) -> ProviderSourceMode
    {
        guard base == .auto,
              provider == .claude,
              let account,
              TokenAccountSupportCatalog.isClaudeOAuthToken(account.token)
        else {
            return base
        }
        return .oauth
    }

    func preferredSourceMode(for provider: UsageProvider) -> ProviderSourceMode {
        let config = self.providerConfig(for: provider)
        return config?.source ?? .auto
    }

    private func providerConfig(for provider: UsageProvider) -> ProviderConfig? {
        self.config.providerConfig(for: provider)
    }

    private func manualCookieHeader(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        config: ProviderConfig?) -> String?
    {
        if let account,
           let support = TokenAccountSupportCatalog.support(for: provider),
           case .cookieHeader = support.injection
        {
            if provider == .claude, TokenAccountSupportCatalog.isClaudeOAuthToken(account.token) {
                return nil
            }
            let header = TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
            return header.isEmpty ? nil : header
        }
        return config?.sanitizedCookieHeader
    }

    private func cookieSource(
        provider: UsageProvider,
        account: ProviderTokenAccount?,
        config: ProviderConfig?) -> ProviderCookieSource
    {
        if let account, TokenAccountSupportCatalog.support(for: provider)?.requiresManualCookieSource == true {
            if provider == .claude, TokenAccountSupportCatalog.isClaudeOAuthToken(account.token) {
                return .off
            }
            return .manual
        }
        if let override = config?.cookieSource { return override }
        if config?.sanitizedCookieHeader != nil {
            return .manual
        }
        return .auto
    }

    private func resolveZaiRegion(_ config: ProviderConfig?) -> ZaiAPIRegion {
        guard let raw = config?.region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .global
        }
        return ZaiAPIRegion(rawValue: raw) ?? .global
    }

    private func resolveMiniMaxRegion(_ config: ProviderConfig?) -> MiniMaxAPIRegion {
        guard let raw = config?.region?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty
        else {
            return .global
        }
        return MiniMaxAPIRegion(rawValue: raw) ?? .global
    }
}
