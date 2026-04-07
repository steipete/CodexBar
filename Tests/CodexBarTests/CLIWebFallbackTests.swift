import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CLIWebFallbackTests {
    private func makeContext(
        runtime: ProviderRuntime = .cli,
        sourceMode: ProviderSourceMode = .auto,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: runtime,
            sourceMode: sourceMode,
            includeCredits: true,
            webTimeout: 60,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    private func makeClaudeSettingsSnapshot(cookieHeader: String?) -> ProviderSettingsSnapshot {
        ProviderSettingsSnapshot.make(
            claude: .init(
                usageDataSource: .auto,
                webExtrasEnabled: false,
                cookieSource: .manual,
                manualCookieHeader: cookieHeader))
    }

    @Test
    func `codex falls back when cookies missing`() {
        let context = self.makeContext()
        let strategy = CodexWebDashboardStrategy()
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardBrowserCookieImporter.ImportError.noCookiesFound,
            context: context))
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardBrowserCookieImporter.ImportError.noMatchingAccount(found: []),
            context: context))
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardBrowserCookieImporter.ImportError.browserAccessDenied(details: "no access"),
            context: context))
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardBrowserCookieImporter.ImportError.dashboardStillRequiresLogin,
            context: context))
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardFetcher.FetchError.loginRequired,
            context: context))
    }

    @Test
    func `codex falls back for dashboard data errors in auto`() {
        let context = self.makeContext()
        let strategy = CodexWebDashboardStrategy()
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardFetcher.FetchError.noDashboardData(body: "missing"),
            context: context))
    }

    @Test
    func `codex display only falls back in auto`() {
        let strategy = CodexWebDashboardStrategy()
        let decision = self.makeCodexDisplayOnlyDecision()

        #expect(strategy.shouldFallback(
            on: CodexDashboardPolicyError.displayOnly(decision),
            context: self.makeContext(sourceMode: .auto)))
    }

    @Test
    func `codex display only does not fall back in explicit web`() {
        let strategy = CodexWebDashboardStrategy()
        let decision = self.makeCodexDisplayOnlyDecision()

        #expect(!strategy.shouldFallback(
            on: CodexDashboardPolicyError.displayOnly(decision),
            context: self.makeContext(sourceMode: .web)))
    }

    @Test
    func `codex web strategy is unavailable when managed account store is unreadable`() async {
        let context = self.makeContext(settings: ProviderSettingsSnapshot.make(
            codex: .init(
                usageDataSource: .auto,
                cookieSource: .auto,
                manualCookieHeader: nil,
                managedAccountStoreUnreadable: true)))
        let strategy = CodexWebDashboardStrategy()
        let available = await strategy.isAvailable(context)

        #expect(!available)
    }

    @Test
    func `codex web strategy is unavailable when selected managed target is unavailable`() async {
        let context = self.makeContext(settings: ProviderSettingsSnapshot.make(
            codex: .init(
                usageDataSource: .auto,
                cookieSource: .auto,
                manualCookieHeader: nil,
                managedAccountTargetUnavailable: true)))
        let strategy = CodexWebDashboardStrategy()
        let available = await strategy.isAvailable(context)

        #expect(!available)
    }

    @Test
    func `claude falls back when no session key`() {
        let context = self.makeContext()
        let strategy = ClaudeWebFetchStrategy(browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(strategy.shouldFallback(on: ClaudeWebAPIFetcher.FetchError.noSessionKeyFound, context: context))
        #expect(strategy.shouldFallback(on: ClaudeWebAPIFetcher.FetchError.unauthorized, context: context))
    }

    @Test
    func `claude CLI fallback is enabled only for app auto`() {
        let strategy = ClaudeCLIFetchStrategy(
            useWebExtras: false,
            manualCookieHeader: nil,
            browserDetection: BrowserDetection(cacheTTL: 0))
        let error = ClaudeUsageError.parseFailed("cli failed")
        let webAvailableSettings = self.makeClaudeSettingsSnapshot(cookieHeader: "sessionKey=sk-ant-test")
        let webUnavailableSettings = self.makeClaudeSettingsSnapshot(cookieHeader: "foo=bar")

        #expect(strategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .auto, settings: webAvailableSettings)))
        #expect(!strategy.shouldFallback(
            on: error,
            context: self.makeContext(runtime: .app, sourceMode: .auto, settings: webUnavailableSettings)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .cli)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .web)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .oauth)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .cli, sourceMode: .auto)))
    }

    @Test
    func `claude web fallback is disabled for app auto`() {
        let strategy = ClaudeWebFetchStrategy(browserDetection: BrowserDetection(cacheTTL: 0))
        let error = ClaudeWebAPIFetcher.FetchError.unauthorized
        #expect(strategy.shouldFallback(on: error, context: self.makeContext(runtime: .cli, sourceMode: .auto)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .auto)))
    }

    private func makeCodexDisplayOnlyDecision() -> CodexDashboardAuthorityDecision {
        CodexDashboardAuthority.evaluate(
            CodexDashboardAuthorityInput(
                sourceKind: .liveWeb,
                proof: CodexDashboardOwnershipProofContext(
                    currentIdentity: .emailOnly(normalizedEmail: "shared@example.com"),
                    expectedScopedEmail: nil,
                    trustedCurrentUsageEmail: nil,
                    dashboardSignedInEmail: "shared@example.com",
                    knownOwners: [
                        CodexDashboardKnownOwnerCandidate(
                            identity: .providerAccount(id: "acct-alpha"),
                            normalizedEmail: "shared@example.com"),
                        CodexDashboardKnownOwnerCandidate(
                            identity: .providerAccount(id: "acct-beta"),
                            normalizedEmail: "shared@example.com"),
                    ]),
                routing: CodexDashboardRoutingHints(
                    targetEmail: "shared@example.com",
                    lastKnownDashboardRoutingEmail: nil)))
    }
}
