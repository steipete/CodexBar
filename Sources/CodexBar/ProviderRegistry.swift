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
        codexFetcher: UsageFetcher,
        claudeFetcher: any ClaudeUsageFetching,
        browserDetection: BrowserDetection,
        allowBrowserCookieAccess: @escaping @MainActor () -> Bool) -> [UsageProvider: ProviderSpec]
    {
        var specs: [UsageProvider: ProviderSpec] = [:]
        specs.reserveCapacity(UsageProvider.allCases.count)

        for provider in UsageProvider.allCases {
            let descriptor = ProviderDescriptorRegistry.descriptor(for: provider)
            guard let meta = self.metadata[provider] ?? Self.defaultMetadata[provider] else {
                assertionFailure("Missing metadata for provider \(provider.rawValue)")
                continue
            }
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
                        let allowCookies = allowBrowserCookieAccess()
                        let codexCookieSource = Self.resolvedCookieSource(
                            settings.codexCookieSource,
                            allowCookies: allowCookies)
                        let claudeCookieSource = Self.resolvedCookieSource(
                            settings.claudeCookieSource,
                            allowCookies: allowCookies)
                        let cursorCookieSource = Self.resolvedCookieSource(
                            settings.cursorCookieSource,
                            allowCookies: allowCookies)
                        let factoryCookieSource = Self.resolvedCookieSource(
                            settings.factoryCookieSource,
                            allowCookies: allowCookies)
                        let minimaxCookieSource = Self.resolvedCookieSource(
                            settings.minimaxCookieSource,
                            allowCookies: allowCookies)
                        let augmentCookieSource = Self.resolvedCookieSource(
                            settings.augmentCookieSource,
                            allowCookies: allowCookies)
                        // Gate webExtras on cookie access - web extras require cookie scans
                        let claudeWebExtras = allowCookies && settings.claudeWebExtrasEnabled
                        return ProviderSettingsSnapshot(
                            debugMenuEnabled: settings.debugMenuEnabled,
                            codex: ProviderSettingsSnapshot.CodexProviderSettings(
                                usageDataSource: settings.codexUsageDataSource,
                                cookieSource: codexCookieSource,
                                manualCookieHeader: settings.codexCookieHeader),
                            claude: ProviderSettingsSnapshot.ClaudeProviderSettings(
                                usageDataSource: settings.claudeUsageDataSource,
                                webExtrasEnabled: claudeWebExtras,
                                cookieSource: claudeCookieSource,
                                manualCookieHeader: settings.claudeCookieHeader),
                            cursor: ProviderSettingsSnapshot.CursorProviderSettings(
                                cookieSource: cursorCookieSource,
                                manualCookieHeader: settings.cursorCookieHeader),
                            factory: ProviderSettingsSnapshot.FactoryProviderSettings(
                                cookieSource: factoryCookieSource,
                                manualCookieHeader: settings.factoryCookieHeader),
                            minimax: ProviderSettingsSnapshot.MiniMaxProviderSettings(
                                cookieSource: minimaxCookieSource,
                                manualCookieHeader: settings.minimaxCookieHeader),
                            zai: ProviderSettingsSnapshot.ZaiProviderSettings(),
                            copilot: ProviderSettingsSnapshot.CopilotProviderSettings(),
                            augment: ProviderSettingsSnapshot.AugmentProviderSettings(
                                cookieSource: augmentCookieSource,
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
                        claudeFetcher: claudeFetcher,
                        browserDetection: browserDetection)
                    return await descriptor.fetchOutcome(context: context)
                })
            specs[provider] = spec
        }

        return specs
    }

    private static let defaultMetadata: [UsageProvider: ProviderMetadata] = ProviderDescriptorRegistry.metadata

    private static func resolvedCookieSource(
        _ source: ProviderCookieSource,
        allowCookies: Bool) -> ProviderCookieSource
    {
        if allowCookies { return source }
        switch source {
        case .manual, .off:
            return source
        case .auto:
            return .off
        }
    }
}
