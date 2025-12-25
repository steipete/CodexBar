import CodexBarCore
import Foundation

struct ProviderSpec {
    let style: IconStyle
    let isEnabled: @MainActor () -> Bool
    let fetch: () async throws -> UsageSnapshot
}

struct ProviderRegistry {
    let metadata: [UsageProvider: ProviderMetadata]

    static let shared: ProviderRegistry = .init()

    init(metadata: [UsageProvider: ProviderMetadata] = ProviderDefaults.metadata) {
        self.metadata = metadata
    }

    @MainActor
    func specs(
        settings: SettingsStore,
        metadata: [UsageProvider: ProviderMetadata],
        codexFetcher: UsageFetcher,
        claudeFetcher: any ClaudeUsageFetching) -> [UsageProvider: ProviderSpec]
    {
        let codexMeta = metadata[.codex]!
        let claudeMeta = metadata[.claude]!
        let geminiMeta = metadata[.gemini]!
        let antigravityMeta = metadata[.antigravity]!
        let cursorMeta = metadata[.cursor]!

        let codexSpec = ProviderSpec(
            style: .codex,
            isEnabled: { settings.isProviderEnabled(provider: .codex, metadata: codexMeta) },
            fetch: { try await codexFetcher.loadLatestUsage() })

        let claudeSpec = ProviderSpec(
            style: .claude,
            isEnabled: { settings.isProviderEnabled(provider: .claude, metadata: claudeMeta) },
            fetch: {
                let fetcher: any ClaudeUsageFetching = settings.claudeWebExtrasEnabled
                    ? ClaudeUsageFetcher(preferWebAPI: true)
                    : claudeFetcher

                let usage = try await fetcher.loadLatestUsage(model: "sonnet")
                return UsageSnapshot(
                    primary: usage.primary,
                    secondary: usage.secondary,
                    tertiary: usage.opus,
                    providerCost: usage.providerCost,
                    updatedAt: usage.updatedAt,
                    accountEmail: usage.accountEmail,
                    accountOrganization: usage.accountOrganization,
                    loginMethod: usage.loginMethod)
            })

        let geminiSpec = ProviderSpec(
            style: .gemini,
            isEnabled: { settings.isProviderEnabled(provider: .gemini, metadata: geminiMeta) },
            fetch: {
                let probe = GeminiStatusProbe()
                let snap = try await probe.fetch()
                return snap.toUsageSnapshot()
            })

        let antigravitySpec = ProviderSpec(
            style: .antigravity,
            isEnabled: { settings.isProviderEnabled(provider: .antigravity, metadata: antigravityMeta) },
            fetch: {
                let probe = AntigravityStatusProbe()
                let snap = try await probe.fetch()
                return try snap.toUsageSnapshot()
            })

        let cursorSpec = ProviderSpec(
            style: .cursor,
            isEnabled: { settings.isProviderEnabled(provider: .cursor, metadata: cursorMeta) },
            fetch: {
                let probe = CursorStatusProbe()
                let snap = try await probe.fetch()
                return snap.toUsageSnapshot()
            })

        return [
            .codex: codexSpec,
            .claude: claudeSpec,
            .gemini: geminiSpec,
            .antigravity: antigravitySpec,
            .cursor: cursorSpec,
        ]
    }

    private static let defaultMetadata: [UsageProvider: ProviderMetadata] = ProviderDefaults.metadata
}
