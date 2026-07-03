import CodexBarCore
import Foundation

extension UsageStore {
    var codexSnapshot: UsageSnapshot? {
        self.snapshots[.codex]
    }

    var claudeSnapshot: UsageSnapshot? {
        self.snapshots[.claude]
    }

    var lastCodexError: String? {
        self.errors[.codex]
    }

    var userFacingLastCodexError: String? {
        self.userFacingError(for: .codex)
    }

    var userFacingLastCreditsError: String? {
        CodexUIErrorMapper.userFacingMessage(self.lastCreditsError)
    }

    var userFacingLastOpenAIDashboardError: String? {
        CodexUIErrorMapper.userFacingMessage(self.lastOpenAIDashboardError)
    }

    var lastClaudeError: String? {
        self.errors[.claude]
    }

    func error(for provider: UsageProvider) -> String? {
        self.errors[provider]
    }

    func userFacingError(for provider: UsageProvider) -> String? {
        if let raw = self.errors[provider] {
            guard provider == .codex else { return raw }
            return CodexUIErrorMapper.userFacingMessage(raw)
        }
        return self.unavailableMessage(for: provider)
    }

    func unavailableMessage(for provider: UsageProvider) -> String? {
        guard self.enabledProvidersForDisplay().contains(provider),
              !self.isProviderAvailable(provider)
        else {
            return nil
        }

        switch provider {
        case .synthetic:
            return SyntheticSettingsError.missingToken.errorDescription
        case .zai:
            return ZaiSettingsError.missingToken.errorDescription
        case .openrouter:
            return OpenRouterSettingsError.missingToken.errorDescription
        case .crossmodel:
            return CrossModelSettingsError.missingToken.errorDescription
        case .azureopenai:
            return AzureOpenAISettingsError.missingAPIKey.errorDescription
        case .elevenlabs:
            return ElevenLabsUsageError.missingCredentials.errorDescription
        case .deepseek:
            return DeepSeekUsageError.missingCredentials.errorDescription
        case .perplexity:
            return PerplexityAPIError.missingToken.errorDescription
        case .minimax:
            return MiniMaxAPISettingsError.missingToken.errorDescription
        case .kimi:
            return KimiAPIError.missingToken.errorDescription
        default:
            return "\(self.metadata(for: provider).displayName) is unavailable in the current environment."
        }
    }

    func status(for provider: UsageProvider) -> ProviderStatus? {
        guard self.statusChecksEnabled else { return nil }
        return self.statuses[provider]
    }

    func statusIndicator(for provider: UsageProvider) -> ProviderStatusIndicator {
        self.status(for: provider)?.indicator ?? .none
    }

    func statusComponents(for provider: UsageProvider) -> [ProviderStatusComponent] {
        guard self.statusChecksEnabled else { return [] }
        return self.statusComponents[provider] ?? []
    }

    func accountInfo(for provider: UsageProvider) -> AccountInfo {
        let now = Date()
        let configRevision = self.settings.configRevision
        if let cached = self.accountInfoCache[provider],
           cached.isValid(now: now, configRevision: configRevision)
        {
            return cached.account
        }

        let account: AccountInfo
        if provider == .codex {
            let env = ProviderRegistry.makeEnvironment(
                base: self.environmentBase,
                provider: .codex,
                settings: self.settings,
                tokenOverride: nil)
            let fetcher = ProviderRegistry.makeFetcher(base: self.codexFetcher, provider: .codex, env: env)
            account = fetcher.loadAccountInfo()
        } else {
            account = self.codexFetcher.loadAccountInfo()
        }
        self.accountInfoCache[provider] = AccountInfoCacheEntry(
            account: account,
            configRevision: configRevision,
            expiresAt: now.addingTimeInterval(self.accountInfoCacheTTL))
        return account
    }
}
