import CodexBarCore
import Foundation

struct ProviderSpec {
    let style: IconStyle
    let isEnabled: @MainActor () -> Bool
    let descriptor: ProviderDescriptor
    let makeFetchContext: @MainActor () -> ProviderFetchContext
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
                descriptor: descriptor,
                makeFetchContext: {
                    let sourceMode = ProviderCatalog.implementation(for: provider)?
                        .sourceMode(context: ProviderSourceModeContext(provider: provider, settings: settings))
                        ?? .auto
                    let snapshot = Self.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
                    let env = Self.makeEnvironment(
                        base: ProcessInfo.processInfo.environment,
                        provider: provider,
                        settings: settings,
                        tokenOverride: nil)
                    let fetcher = Self.makeFetcher(base: codexFetcher, provider: provider, env: env)
                    let verbose = settings.isVerboseLoggingEnabled
                    return ProviderFetchContext(
                        runtime: .app,
                        sourceMode: sourceMode,
                        includeCredits: false,
                        webTimeout: 60,
                        webDebugDumpHTML: false,
                        verbose: verbose,
                        env: env,
                        settings: snapshot,
                        fetcher: fetcher,
                        claudeFetcher: claudeFetcher,
                        browserDetection: browserDetection)
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
        // Managed Codex routing only scopes remote account fetches such as identity, plan,
        // quotas, and dashboard data, and only when the active source is a managed account.
        // Token-cost/session history is intentionally not routed through the managed home
        // because that data is currently treated as provider-level local telemetry from this
        // Mac's Codex sessions, not as account-owned remote state. If we later want
        // account-scoped token history in the UI, that needs an explicit product decision and
        // presentation change so the two concepts are not conflated.
        if provider == .codex, let managedHomePath = settings.activeManagedCodexRemoteHomePath {
            env = CodexHomeScope.scopedEnvironment(base: env, codexHome: managedHomePath)
        }
        return env
    }

    static func makeFetcher(base: UsageFetcher, provider: UsageProvider, env: [String: String]) -> UsageFetcher {
        guard provider == .codex else { return base }
        return UsageFetcher(environment: env)
    }
}
