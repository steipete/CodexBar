import CodexBarCore
import Foundation

extension UsageStore {
    struct DeepSeekProfileTransition {
        var snapshot: UsageSnapshot
        let accountID: UUID?
        let hasSyntheticBalance: Bool
    }

    func version(for provider: UsageProvider) -> String? {
        self.versions[provider]
    }

    var codexSnapshot: UsageSnapshot? {
        self.snapshots[.codex]
    }

    var claudeSnapshot: UsageSnapshot? {
        self.snapshots[.claude]
    }

    func presentationSnapshot(for provider: UsageProvider) -> UsageSnapshot? {
        if provider == .deepseek,
           let transition = self.deepseekProfileTransition,
           transition.accountID == self.settings.selectedTokenAccount(for: .deepseek)?.id
        {
            return transition.snapshot
        }
        if let snapshot = self.snapshots[provider] {
            return snapshot
        }
        guard provider == .deepseek, self.refreshingProviders.contains(provider) else { return nil }
        return self.lastKnownResetSnapshots[provider]
    }

    func beginDeepSeekProfileTransition(preservingBalance: Bool = true) {
        guard self.deepseekProfileTransition == nil,
              let snapshot = self.snapshots[.deepseek] ?? self.lastKnownResetSnapshots[.deepseek]
        else { return }
        var transitionSnapshot = snapshot.withoutDeepSeekDetailedUsage()
        if !preservingBalance {
            transitionSnapshot = transitionSnapshot.with(
                primary: RateWindow(
                    usedPercent: 0,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: L("Refreshing")),
                secondary: nil)
        }
        self.deepseekProfileTransition = DeepSeekProfileTransition(
            snapshot: transitionSnapshot,
            accountID: self.settings.selectedTokenAccount(for: .deepseek)?.id,
            hasSyntheticBalance: !preservingBalance)
    }

    func markDeepSeekProfileTransitionUnavailable() {
        guard var transition = self.deepseekProfileTransition,
              transition.hasSyntheticBalance
        else { return }
        transition.snapshot = transition.snapshot.with(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: L("Unavailable")),
            secondary: nil)
        self.deepseekProfileTransition = transition
    }

    func clearDeepSeekProfileTransition() {
        self.deepseekProfileTransition = nil
    }

    var deepseekProfileTransitionSnapshot: UsageSnapshot? {
        self.deepseekProfileTransition?.snapshot
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

    func diagnostic(for provider: UsageProvider) -> String? {
        self.diagnostics[provider]
    }

    func userFacingError(for provider: UsageProvider) -> String? {
        if let raw = self.errors[provider] {
            switch provider {
            case .codex:
                return CodexUIErrorMapper.userFacingMessage(raw)
            case .ollama:
                return OllamaUIErrorMapper.userFacingMessage(raw)
            default:
                return raw
            }
        }
        if let diagnostic = self.diagnostics[provider] {
            return diagnostic
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
        case .clawrouter:
            return ClawRouterUsageError.missingCredentials.errorDescription
        case .sub2api:
            let environment = ProviderRegistry.makeEnvironment(
                base: self.environmentBase,
                provider: provider,
                settings: self.settings,
                tokenOverride: nil)
            if Sub2APISettingsReader.apiKey(environment: environment) == nil {
                return Sub2APIUsageError.missingCredentials.errorDescription
            }
            return Sub2APIUsageError.missingBaseURL.errorDescription
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
