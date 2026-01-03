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
        claudeFetcher: any ClaudeUsageFetching) -> [UsageProvider: ProviderSpec]
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
                        ProviderSettingsSnapshot(
                            debugMenuEnabled: settings.debugMenuEnabled,
                            codex: ProviderSettingsSnapshot.CodexProviderSettings(
                                usageDataSource: settings.codexUsageDataSource,
                                cookieSource: settings.codexCookieSource,
                                manualCookieHeader: settings.codexCookieHeader),
                            claude: ProviderSettingsSnapshot.ClaudeProviderSettings(
                                usageDataSource: settings.claudeUsageDataSource,
                                webExtrasEnabled: settings.claudeWebExtrasEnabled,
                                cookieSource: settings.claudeCookieSource,
                                manualCookieHeader: settings.claudeCookieHeader),
                            cursor: ProviderSettingsSnapshot.CursorProviderSettings(
                                cookieSource: settings.cursorCookieSource,
                                manualCookieHeader: settings.cursorCookieHeader),
                            factory: ProviderSettingsSnapshot.FactoryProviderSettings(
                                cookieSource: settings.factoryCookieSource,
                                manualCookieHeader: settings.factoryCookieHeader),
                            minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings(
                                cookieSource: settings.minimaxCookieSource,
                                manualCookieHeader: settings.minimaxCookieHeader),
                            zai: ProviderSettingsSnapshot.ZaiProviderSettings(),
                            copilot: ProviderSettingsSnapshot.CopilotProviderSettings(),
                            augment: ProviderSettingsSnapshot.AugmentProviderSettings(
                                cookieSource: settings.augmentCookieSource,
                                manualCookieHeader: settings.augmentCookieHeader))
                    }
                    let context = ProviderFetchContext(
                        runtime: .app,
                        sourceMode: sourceMode,
                        includeCredits: false,
                        webTimeout: 60,
                        webDebugDumpHTML: false,
                        verbose: false,
                        env: ProcessInfo.processInfo.environment,
                        settings: snapshot,
                        fetcher: codexFetcher,
                        claudeFetcher: claudeFetcher)
                    return await descriptor.fetchOutcome(context: context)
                })
            specs[provider] = spec
        }

        return specs
    }

    private static let defaultMetadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata
}
