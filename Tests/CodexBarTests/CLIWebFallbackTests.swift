import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

@Suite
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

    private func makeCodexSettingsSnapshot(
        cookieSource: ProviderCookieSource,
        cookieHeader: String?) -> ProviderSettingsSnapshot
    {
        ProviderSettingsSnapshot.make(
            codex: .init(
                usageDataSource: .auto,
                cookieSource: cookieSource,
                manualCookieHeader: cookieHeader))
    }

    @Test
    func codexFallsBackWhenCookiesMissing() {
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
    func codexFallsBackForDashboardDataErrorsInAuto() {
        let context = self.makeContext()
        let strategy = CodexWebDashboardStrategy()
        #expect(strategy.shouldFallback(
            on: OpenAIDashboardFetcher.FetchError.noDashboardData(body: "missing"),
            context: context))
    }

    @Test
    func claudeFallsBackWhenNoSessionKey() {
        let context = self.makeContext()
        let strategy = ClaudeWebFetchStrategy(browserDetection: BrowserDetection(cacheTTL: 0))
        #expect(strategy.shouldFallback(on: ClaudeWebAPIFetcher.FetchError.noSessionKeyFound, context: context))
        #expect(strategy.shouldFallback(on: ClaudeWebAPIFetcher.FetchError.unauthorized, context: context))
    }

    @Test
    func claudeCLIFallbackIsEnabledOnlyForAppAuto() {
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
    func claudeWebFallbackIsDisabledForAppAuto() {
        let strategy = ClaudeWebFetchStrategy(browserDetection: BrowserDetection(cacheTTL: 0))
        let error = ClaudeWebAPIFetcher.FetchError.unauthorized
        #expect(strategy.shouldFallback(on: error, context: self.makeContext(runtime: .cli, sourceMode: .auto)))
        #expect(!strategy.shouldFallback(on: error, context: self.makeContext(runtime: .app, sourceMode: .auto)))
    }

    @Test
    func codexWebImportUsesManualCookieHeaderWhenConfigured() {
        let settings = ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: .auto,
            cookieSource: .manual,
            manualCookieHeader: "__Secure-next-auth.session-token=abc; oai-sc=def")

        let input = CodexWebDashboardStrategy.resolveCookieImportInput(
            settings: settings,
            fallbackAccountEmail: "old@example.com")

        switch input.mode {
        case let .manual(cookieHeader):
            #expect(cookieHeader.contains("__Secure-next-auth.session-token="))
            #expect(input.accountEmail == nil)
        case .browser:
            Issue.record("Expected manual cookie import mode")
        }
    }

    @Test
    func codexWebImportUsesBrowserCookiesWhenManualHeaderMissing() {
        let settings = ProviderSettingsSnapshot.CodexProviderSettings(
            usageDataSource: .auto,
            cookieSource: .manual,
            manualCookieHeader: nil)

        let input = CodexWebDashboardStrategy.resolveCookieImportInput(
            settings: settings,
            fallbackAccountEmail: "old@example.com")

        switch input.mode {
        case .manual:
            Issue.record("Expected browser import mode")
        case .browser:
            #expect(input.accountEmail == "old@example.com")
        }
    }

    @Test
    func codexAppAutoPrefersWebWhenManualCookiesConfigured() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext(
            runtime: .app,
            sourceMode: .auto,
            settings: self.makeCodexSettingsSnapshot(
                cookieSource: .manual,
                cookieHeader: "__Secure-next-auth.session-token=abc")))

        #expect(strategies.map(\.id) == ["codex.web.dashboard", "codex.cli"])
    }

    @Test
    func codexAppAutoUsesOAuthThenCLIWithoutManualCookies() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .codex)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(self.makeContext(
            runtime: .app,
            sourceMode: .auto,
            settings: self.makeCodexSettingsSnapshot(
                cookieSource: .auto,
                cookieHeader: nil)))

        #expect(strategies.map(\.id) == ["codex.oauth", "codex.cli"])
    }
}
