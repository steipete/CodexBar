import Testing
@testable import CodexBarCore

struct WindsurfProviderTests {
    private func makeContext(
        sourceMode: ProviderSourceMode,
        settings: ProviderSettingsSnapshot? = nil) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: sourceMode,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: [:],
            settings: settings,
            fetcher: UsageFetcher(),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }

    @Test
    func `local probe is unavailable in explicit web mode`() async {
        let strategy = WindsurfLocalFetchStrategy()

        #expect(await strategy.isAvailable(self.makeContext(sourceMode: .web)) == false)
        #expect(await strategy.isAvailable(self.makeContext(sourceMode: .auto)))
        #expect(await strategy.isAvailable(self.makeContext(sourceMode: .cli)))
    }

    @Test
    func `web mode with cookies off does not fall back to local probe`() async {
        let settings = ProviderSettingsSnapshot.make(
            windsurf: .init(
                usageDataSource: .web,
                cookieSource: .off,
                manualCookieHeader: nil))
        let context = self.makeContext(sourceMode: .web, settings: settings)

        let outcome = await WindsurfProviderDescriptor.descriptor.fetchPlan.fetchOutcome(
            context: context,
            provider: .windsurf)

        guard case let .failure(error) = outcome.result else {
            Issue.record("Expected web-only Windsurf fetch to fail when cookies are off")
            return
        }

        #expect(error is ProviderFetchError)
        #expect(outcome.attempts.map(\.strategyID) == ["windsurf.web", "windsurf.local"])
        #expect(outcome.attempts.map(\.wasAvailable) == [false, false])
    }
}
