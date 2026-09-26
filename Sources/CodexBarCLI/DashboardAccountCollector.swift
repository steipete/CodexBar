import CodexBarCore
import Foundation

extension CodexBarCLI {
    static func serveUsageOutput(
        selection: ProviderSelection,
        context: ServeUsageContext,
        fetchUsage: @escaping ServeUsageFetcher = CodexBarCLI
            .fetchServeProviderUsage) async throws -> UsageCommandOutput
    {
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: context.config,
            verbose: false)

        let allTokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: true),
            config: context.config,
            verbose: false)
        let browserDetection = BrowserDetection()
        let command = UsageCommandContext(
            format: .json,
            includeCredits: true,
            sourceModeOverride: nil,
            antigravityPlanDebug: false,
            augmentDebug: false,
            webDebugDumpHTML: false,
            webTimeout: context.providerTimeout ?? 60,
            verbose: false,
            useColor: false,
            resetStyle: Self.resetTimeDisplayStyleFromDefaults(),
            weeklyWorkDays: Self.weeklyProgressWorkDaysFromDefaults(),
            jsonOnly: true,
            includeAllCodexAccounts: context.includeAllCodexAccounts,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            persistCLISessions: context.persistCLISessions,
            persistentCLISessionIdleWindow: Self.serveCLISessionIdleWindow(
                refreshInterval: context.refreshInterval))

        return await Self.serveCollectUsageOutputs(
            providers: selection.asList,
            configFingerprint: Self.serveUsageOperationFingerprint(
                configFingerprint: context.configFingerprint,
                includeAllCodexAccounts: context.includeAllCodexAccounts,
                includeAllAccounts: context.includeAllAccounts),
            deadline: context.providerDeadline,
            operations: context.providerOperations)
        { provider, publish in
            await ProviderInteractionContext.$current.withValue(.background) {
                await fetchUsage(
                    provider,
                    Self.serveIncludesConfiguredAccounts(
                        provider: provider, config: context.config, allAccounts: context.includeAllAccounts)
                        ? allTokenContext : tokenContext,
                    command,
                    context.includeAllAccounts ? publish : nil)
            }
        }
    }

    static func serveUsageOperationFingerprint(
        configFingerprint: String,
        includeAllCodexAccounts: Bool,
        includeAllAccounts: Bool = false) -> String
    {
        "\(configFingerprint):codex-accounts=\(includeAllCodexAccounts ? "all" : "selected")"
            + (includeAllAccounts ? ":token-accounts=all" : "")
    }

    typealias ServeUsageFetcher = @Sendable (
        UsageProvider, TokenAccountCLIContext, UsageCommandContext,
        CLIServeOperationCoordinator<UsageCommandOutput>.PublishPartial?) async -> UsageCommandOutput

    static let fetchServeProviderUsage: ServeUsageFetcher = { provider, tokenContext, command, publish in
        await Self.fetchUsageOutputs(
            provider: provider,
            status: nil,
            tokenContext: tokenContext,
            command: command,
            publishPartial: publish)
    }

    static func serveIncludesConfiguredAccounts(
        provider: UsageProvider, config: CodexBarConfig, allAccounts: Bool) -> Bool
    {
        guard allAccounts else { return false }
        // Provider-specific by design: Claude-swap supplies account rows; keep normal provider-level usage only.
        if provider == .claude, dashboardClaudeSwapIsEligible(config: config) { return false }
        return TokenAccountSupportCatalog.support(for: provider) != nil
            && config.providerConfig(for: provider.instanceID)?.tokenAccounts?.accounts.isEmpty == false
    }

    /// Publish a complete fallback shape before each fetch. Finished siblings keep
    /// their data; unfinished accounts have account-local timeout rows without usage-cache keys.
    static func collectAccountUsage(
        provider: UsageProvider,
        accounts: [DashboardUsageAccount?],
        inventoryIncomplete: Bool = false,
        minimumDelay: Duration? = nil,
        publishPartial: CLIServeOperationCoordinator<UsageCommandOutput>.PublishPartial? = nil,
        fetch: @Sendable (Int) async -> UsageCommandOutput) async -> UsageCommandOutput
    {
        var output = UsageCommandOutput()
        for index in accounts.indices {
            var fallback = output
            if publishPartial != nil {
                for account in accounts[index...] {
                    var timeout = Self.serveProviderTimeoutOutput(provider: provider)
                    timeout.attachDashboardAccount(account, inventoryIncomplete: inventoryIncomplete)
                    fallback.merge(timeout)
                }
            }
            if let publishPartial {
                await publishPartial(fallback)
                if Task.isCancelled { return fallback }
            }
            if index > 0, let minimumDelay {
                do {
                    try await Task.sleep(for: minimumDelay)
                } catch {
                    return publishPartial == nil ? output : fallback
                }
            }
            var result = await fetch(index)
            result.attachDashboardAccount(accounts[index], inventoryIncomplete: inventoryIncomplete)
            output.merge(result)
        }
        return output
    }
}
