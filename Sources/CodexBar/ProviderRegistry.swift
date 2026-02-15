import CodexBarCore
import Foundation

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
        browserDetection: BrowserDetection,
        onAntigravityCredentialsRefreshed:
        (@Sendable (String, AntigravityOAuthCredentials) -> Void)? = nil) -> [UsageProvider: ProviderSpec]
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
                    let sourceMode = ProviderCatalog.implementation(for: provider)?
                        .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: settings))
                        ?? .auto
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
                    let verbose = settings.isVerboseLoggingEnabled
                    let context = ProviderFetchContext(
                        runtime: .app,
                        sourceMode: sourceMode,
                        includeCredits: false,
                        webTimeout: 60,
                        webDebugDumpHTML: false,
                        verbose: verbose,
                        env: env,
                        settings: snapshot,
                        fetcher: codexFetcher,
                        claudeFetcher: claudeFetcher,
                        browserDetection: browserDetection,
                        onAntigravityCredentialsRefreshed: onAntigravityCredentialsRefreshed)
                    return await descriptor.fetchOutcome(context: context)
                })
            specs[provider] = spec
        }

        return specs
    }

    @MainActor
    static func makeSettingsSnapshot(
        settings: SettingsStore,
        tokenOverride: TokenAccountOverride?) -> ProviderSettingsSnapshot
    {
        settings.ensureTokenAccountsLoaded()
        var builder = ProviderSettingsSnapshotBuilder(
            debugMenuEnabled: settings.debugMenuEnabled,
            debugKeepCLISessionsAlive: settings.debugKeepCLISessionsAlive)
        let context = ProviderSettingsSnapshotContext(settings: settings, tokenOverride: tokenOverride)
        for implementation in ProviderCatalog.all {
            if let contribution = implementation.settingsSnapshot(context: context) {
                builder.apply(contribution)
            }
        }
        return builder.build()
    }

    @MainActor
    static func makeEnvironment(
        base: [String: String],
        provider: UsageProvider,
        settings: SettingsStore,
        tokenOverride: TokenAccountOverride?) -> [String: String]
    {
        let account = ProviderTokenAccountSelection.selectedAccount(
            provider: provider,
            settings: settings,
            override: tokenOverride)
        var env = ProviderConfigEnvironment.applyAPIKeyOverride(
            base: base,
            provider: provider,
            config: settings.providerConfig(for: provider))
        // If token account is selected, use its token instead of config's apiKey
        if let account, let override = TokenAccountSupportCatalog.envOverride(
            for: provider,
            token: account.token)
        {
            for (key, value) in override {
                env[key] = value
            }
        }
        return env
    }
}
