import CodexBarCore
import Foundation

struct TokenAccountOverride: Sendable {
    let provider: UsageProvider
    let account: ProviderTokenAccount
}

struct ProviderSpec {
    let style: IconStyle
    let isEnabled: @MainActor () -> Bool
    let fetch: () async -> ProviderFetchOutcome
}

struct ProviderRegistry {
    let metadata: [UsageProvider: ProviderMetadata]

    static let shared: ProviderRegistry = .init()

    init(metadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata) {
        self.metadata = metadata
    }

    @MainActor
    func specs(
        settings: SettingsStore,
        metadata: [UsageProvider: ProviderMetadata],
        codexFetcher: UsageFetcher,
        claudeFetcher: any ClaudeUsageFetching,
        browserDetection: BrowserDetection) -> [UsageProvider: ProviderSpec]
    {
        var specs: [UsageProvider: ProviderSpec] = [:]
        specs.reserveCapacity(UsageProvider.allCases.count)

        for provider in UsageProvider.allCases {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            let meta = metadata[provider]!
            let spec = ProviderSpec(
                style: descriptor.branding.iconStyle,
                isEnabled: { settings.isProviderEnabled(provider: provider, metadata: meta) },
                fetch: {
                    let sourceMode: ProviderSourceMode = switch provider {
                    case .codex:
                        switch settings.codexUsageDataSource {
                        case .auto: .auto
                        case .oauth: .oauth
                        case .cli: .cli
                        }
                    case .claude:
                        switch settings.claudeUsageDataSource {
                        case .auto: .auto
                        case .oauth: .oauth
                        case .web: .web
                        case .cli: .cli
                        }
                    default:
                        .auto
                    }
                    let snapshot = await MainActor.run {
                        Self.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
                    }
                    let env = await MainActor.run {
                        Self.makeEnvironment(
                            base: ProcessInfo.processInfo.environment,
                            provider: provider,
                            settings: settings,
                            tokenOverride: nil)
                    }
                    let context = ProviderFetchContext(
                        runtime: .app,
                        sourceMode: sourceMode,
                        includeCredits: false,
                        webTimeout: 60,
                        webDebugDumpHTML: false,
                        verbose: false,
                        env: env,
                        settings: snapshot,
                        fetcher: codexFetcher,
                        claudeFetcher: claudeFetcher,
                        browserDetection: browserDetection)
                    return await descriptor.fetchOutcome(context: context)
                })
            specs[provider] = spec
        }

        return specs
    }

    private static let defaultMetadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata

    @MainActor
    static func makeSettingsSnapshot(
        settings: SettingsStore,
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    {
        settings.ensureTokenAccountsLoaded()
        let codexHeader = Self.manualCookieHeader(
            provider: .codex,
            settings: settings,
            override: tokenOverride,
            fallback: settings.codexCookieHeader)
        let claudeHeader = Self.manualCookieHeader(
            provider: .claude,
            settings: settings,
            override: tokenOverride,
            fallback: settings.claudeCookieHeader)
        let cursorHeader = Self.manualCookieHeader(
            provider: .cursor,
            settings: settings,
            override: tokenOverride,
            fallback: settings.cursorCookieHeader)
        let opencodeHeader = Self.manualCookieHeader(
            provider: .opencode,
            settings: settings,
            override: tokenOverride,
            fallback: settings.opencodeCookieHeader)
        let factoryHeader = Self.manualCookieHeader(
            provider: .factory,
            settings: settings,
            override: tokenOverride,
            fallback: settings.factoryCookieHeader)
        let minimaxHeader = Self.manualCookieHeader(
            provider: .minimax,
            settings: settings,
            override: tokenOverride,
            fallback: settings.minimaxCookieHeader)
        let augmentHeader = Self.manualCookieHeader(
            provider: .augment,
            settings: settings,
            override: tokenOverride,
            fallback: settings.augmentCookieHeader)
        let ampHeader = Self.manualCookieHeader(
            provider: .amp,
            settings: settings,
            override: tokenOverride,
            fallback: settings.ampCookieHeader)
        settings.ensureKimiAuthTokenLoaded()
        let kimiHeader = settings.kimiManualCookieHeader

        return ProviderSettingsSnapshot.make(
            debugMenuEnabled: settings.debugMenuEnabled,
            codex: ProviderSettingsSnapshot.CodexProviderSettings(
                usageDataSource: settings.codexUsageDataSource,
                cookieSource: Self.cookieSource(
                    provider: .codex,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.codexCookieSource),
                manualCookieHeader: codexHeader),
            claude: ProviderSettingsSnapshot.ClaudeProviderSettings(
                usageDataSource: settings.claudeUsageDataSource,
                webExtrasEnabled: settings.claudeWebExtrasEnabled,
                cookieSource: Self.cookieSource(
                    provider: .claude,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.claudeCookieSource),
                manualCookieHeader: claudeHeader),
            cursor: ProviderSettingsSnapshot.CursorProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .cursor,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.cursorCookieSource),
                manualCookieHeader: cursorHeader),
            opencode: ProviderSettingsSnapshot.OpenCodeProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .opencode,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.opencodeCookieSource),
                manualCookieHeader: opencodeHeader,
                workspaceID: settings.opencodeWorkspaceID),
            factory: ProviderSettingsSnapshot.FactoryProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .factory,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.factoryCookieSource),
                manualCookieHeader: factoryHeader),
            minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .minimax,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.minimaxCookieSource),
                manualCookieHeader: minimaxHeader,
                apiRegion: settings.minimaxAPIRegion),
            zai: ProviderSettingsSnapshot.ZaiProviderSettings(apiRegion: settings.zaiAPIRegion),
            copilot: ProviderSettingsSnapshot.CopilotProviderSettings(),
            kimi: ProviderSettingsSnapshot.KimiProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .kimi,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.kimiCookieSource),
                manualCookieHeader: kimiHeader),
            augment: ProviderSettingsSnapshot.AugmentProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .augment,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.augmentCookieSource),
                manualCookieHeader: augmentHeader),
            amp: ProviderSettingsSnapshot.AmpProviderSettings(
                cookieSource: Self.cookieSource(
                    provider: .amp,
                    settings: settings,
                    override: tokenOverride,
                    fallback: settings.ampCookieSource),
                manualCookieHeader: ampHeader),
            jetbrains: ProviderSettingsSnapshot.JetBrainsProviderSettings(
                ideBasePath: settings.jetbrainsIDEBasePath.isEmpty ? nil : settings.jetbrainsIDEBasePath))
    }

    @MainActor
    static func makeEnvironment(
        base: [String: String],
        provider: UsageProvider,
        settings: SettingsStore,
        tokenOverride: TokenAccountOverride?) -> [String: String]
    {
        let account = Self.selectedTokenAccount(
            provider: provider,
            settings: settings,
            override: tokenOverride)
        var env = base
        if let account, let override = TokenAccountSupportCatalog.envOverride(
            for: provider,
            token: account.token)
        {
            for (key, value) in override {
                env[key] = value
            }
        }
        return ProviderConfigEnvironment.applyAPIKeyOverride(
            base: env,
            provider: provider,
            config: settings.providerConfig(for: provider))
    }

    @MainActor
    private static func selectedTokenAccount(
        provider: UsageProvider,
        settings: SettingsStore,
        override: TokenAccountOverride?) -> ProviderTokenAccount?
    {
        if let override, override.provider == provider { return override.account }
        return settings.selectedTokenAccount(for: provider)
    }

    @MainActor
    private static func manualCookieHeader(
        provider: UsageProvider,
        settings: SettingsStore,
        override: TokenAccountOverride?,
        fallback: String) -> String
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider),
              case .cookieHeader = support.injection
        else {
            return fallback
        }
        if let account = Self.selectedTokenAccount(provider: provider, settings: settings, override: override) {
            if provider == .claude, TokenAccountSupportCatalog.isClaudeOAuthToken(account.token) {
                return ""
            }
            return TokenAccountSupportCatalog.normalizedCookieHeader(account.token, support: support)
        }
        return fallback
    }

    @MainActor
    private static func cookieSource(
        provider: UsageProvider,
        settings: SettingsStore,
        override: TokenAccountOverride?,
        fallback: ProviderCookieSource) -> ProviderCookieSource
    {
        guard let support = TokenAccountSupportCatalog.support(for: provider),
              support.requiresManualCookieSource
        else {
            return fallback
        }
        if provider == .claude,
           let account = Self.selectedTokenAccount(provider: provider, settings: settings, override: override),
           TokenAccountSupportCatalog.isClaudeOAuthToken(account.token)
        {
            return .off
        }
        if settings.tokenAccounts(for: provider).isEmpty { return fallback }
        return .manual
    }
}
