import CodexBarCore
import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI

@Suite(.serialized)
@MainActor
struct ClaudeTokenAccountRoutingTests {
    @Test(arguments: [
        ProviderSourceMode.auto,
        ProviderSourceMode.api,
        ProviderSourceMode.web,
        ProviderSourceMode.cli,
        ProviderSourceMode.oauth,
    ])
    func `CLI web account override wins over every global source`(
        sourceMode: ProviderSourceMode) async throws
    {
        let account = ProviderTokenAccount(
            id: UUID(),
            label: "Web",
            token: "sk-ant-session-token",
            addedAt: 0,
            lastUsed: nil)
        let config = CodexBarConfig(providers: [ProviderConfig(id: .claude)])
        let tokenContext = try TokenAccountCLIContext(
            selection: TokenAccountCLISelection(label: nil, index: nil, allAccounts: false),
            config: config,
            verbose: false)
        let effectiveSourceMode = tokenContext.effectiveSourceMode(
            base: sourceMode,
            provider: .claude,
            account: account)
        let settings = try #require(tokenContext.settingsSnapshot(for: .claude, account: account))
        let env = tokenContext.environment(base: [:], provider: .claude, account: account)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .cli,
            sourceMode: effectiveSourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: settings,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: account.id)

        let strategies = await ProviderDescriptorRegistry.descriptor(for: .claude)
            .fetchPlan.pipeline.resolveStrategies(context)

        #expect(effectiveSourceMode == .web)
        #expect(settings.claude?.usageDataSource == .web)
        #expect(strategies.map(\.id) == ["claude.web"])
    }

    @Test
    func `OAuth account override wins over global source and active account`() throws {
        let settings = testSettingsStore(suiteName: "ClaudeTokenAccountRoutingTests-multi-account")
        settings.claudeUsageDataSource = .api
        settings.addTokenAccount(provider: .claude, label: "First", token: "Bearer sk-ant-oat-first-token")
        settings.addTokenAccount(provider: .claude, label: "Second", token: "Bearer sk-ant-oat-second-token")
        let first = try #require(settings.tokenAccounts(for: .claude).first)
        let active = try #require(settings.selectedTokenAccount(for: .claude))
        let accountOverride = TokenAccountOverride(provider: .claude, account: first)

        let env = ProviderRegistry.makeEnvironment(
            base: ["FOO": "bar"],
            provider: .claude,
            settings: settings,
            tokenOverride: accountOverride)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(
            settings: settings,
            tokenOverride: accountOverride)

        #expect(active.label == "Second")
        #expect(settings.selectedTokenAccount(for: .claude)?.id == active.id)
        #expect(env["FOO"] == "bar")
        #expect(env[ClaudeOAuthCredentialsStore.environmentTokenKey] == "sk-ant-oat-first-token")
        #expect(snapshot.claude?.usageDataSource == .oauth)
        #expect(snapshot.claude?.cookieSource == .off)
    }

    @Test(arguments: [
        ProviderSourceMode.auto,
        ProviderSourceMode.api,
        ProviderSourceMode.web,
        ProviderSourceMode.cli,
        ProviderSourceMode.oauth,
    ])
    func `selected web account overrides every global source`(sourceMode: ProviderSourceMode) async throws {
        let settings = testSettingsStore(suiteName: "ClaudeTokenAccountRoutingTests-web-\(sourceMode.rawValue)")
        settings.claudeUsageDataSource = .api
        settings.addTokenAccount(
            provider: .claude,
            label: "Web session",
            token: "sessionKey=sk-ant-selected-session-token")
        let account = try #require(settings.selectedTokenAccount(for: .claude))
        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: snapshot,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: account.id)

        let strategies = await ProviderDescriptorRegistry.descriptor(for: .claude)
            .fetchPlan.pipeline.resolveStrategies(context)

        #expect(snapshot.claude?.usageDataSource == .web)
        #expect(snapshot.claude?.cookieSource == .manual)
        #expect(snapshot.claude?.manualCookieHeader == "sessionKey=sk-ant-selected-session-token")
        #expect(strategies.map(\.id) == ["claude.web"])
        #expect(await strategies[0].isAvailable(context))
    }

    @Test(arguments: [
        ProviderSourceMode.auto,
        ProviderSourceMode.api,
        ProviderSourceMode.web,
        ProviderSourceMode.cli,
        ProviderSourceMode.oauth,
    ])
    func `malformed selected account fails closed under every global source`(
        sourceMode: ProviderSourceMode) async throws
    {
        let settings = testSettingsStore(suiteName: "ClaudeTokenAccountRoutingTests-invalid-\(sourceMode.rawValue)")
        settings.addTokenAccount(provider: .claude, label: "Invalid", token: "Cookie:")
        let account = try #require(settings.selectedTokenAccount(for: .claude))
        let env = ProviderRegistry.makeEnvironment(
            base: [:],
            provider: .claude,
            settings: settings,
            tokenOverride: nil)
        let snapshot = ProviderRegistry.makeSettingsSnapshot(settings: settings, tokenOverride: nil)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: env,
            settings: snapshot,
            fetcher: UsageFetcher(environment: env),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection,
            selectedTokenAccountID: account.id)

        let descriptor = ProviderDescriptorRegistry.descriptor(for: .claude)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)
        let outcome = await descriptor.fetchOutcome(context: context)

        #expect(strategies.isEmpty)
        #expect(outcome.attempts.isEmpty)
        guard case let .failure(error as ProviderFetchError) = outcome.result,
              case let .noAvailableStrategy(provider) = error
        else {
            Issue.record("Expected selected malformed account to fail with noAvailableStrategy")
            return
        }
        #expect(provider == .claude)
    }
}
