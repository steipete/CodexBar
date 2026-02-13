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
}
