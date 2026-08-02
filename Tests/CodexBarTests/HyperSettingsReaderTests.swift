import Testing
@testable import CodexBarCore

struct HyperSettingsReaderTests {
    @Test
    func `reads and cleans Hyper API key from environment`() {
        #expect(HyperSettingsReader.apiKey(environment: ["HYPER_API_KEY": "  'hyper-key'  "]) == "hyper-key")
    }

    @Test
    func `API key only disables the session strategy`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .hyper)
        let environment = ["HYPER_API_KEY": "hyper-key"]
        let settings = ProviderSettingsSnapshot.make(
            hyper: .init(cookieSource: .off, manualCookieHeader: nil))
        let context = Self.context(environment: environment, settings: settings)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(descriptor.metadata.displayName == "Charm Hyper")
        #expect(descriptor.metadata.cliName == "hyper")
        #expect(descriptor.metadata.dashboardURL == "https://hyper.charm.land")
        #expect(strategies.map(\.id) == ["hyper.api"])
    }

    @Test
    func `signed in session is preferred over an API key`() async {
        let settings = ProviderSettingsSnapshot.make(
            hyper: .init(cookieSource: .manual, manualCookieHeader: "session=fixture"))
        let context = Self.context(
            environment: ["HYPER_API_KEY": "hyper-key"],
            settings: settings)
        let strategies = await HyperProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["hyper.web", "hyper.api"])
        #expect(await strategies[0].isAvailable(context))
    }

    @Test
    func `missing session and API key return setup guidance`() async {
        let settings = ProviderSettingsSnapshot.make(
            hyper: .init(cookieSource: .off, manualCookieHeader: nil))
        let context = Self.context(environment: [:], settings: settings)
        let strategies = await HyperProviderDescriptor.descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(strategies.map(\.id) == ["hyper.api"])
        await #expect(throws: HyperUsageError.missingCredentials) {
            try await strategies[0].fetch(context)
        }
        #expect(HyperUsageError.missingCredentials.errorDescription?.contains("Sign in") == true)
        #expect(HyperUsageError.missingCredentials.errorDescription?.contains("API key") == true)
    }

    private static func context(
        environment: [String: String],
        settings: ProviderSettingsSnapshot) -> ProviderFetchContext
    {
        let browserDetection = BrowserDetection(cacheTTL: 0)
        return ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: settings,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
    }
}
