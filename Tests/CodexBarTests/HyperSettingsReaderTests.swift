import Testing
@testable import CodexBarCore

struct HyperSettingsReaderTests {
    @Test
    func `reads and cleans Hyper API key from environment`() {
        #expect(HyperSettingsReader.apiKey(environment: ["HYPER_API_KEY": "  'hyper-key'  "]) == "hyper-key")
    }

    @Test
    func `descriptor uses API credentials and Hyper CLI name`() async {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .hyper)
        let browserDetection = BrowserDetection(cacheTTL: 0)
        let environment = ["HYPER_API_KEY": "hyper-key"]
        let context = ProviderFetchContext(
            runtime: .app,
            sourceMode: .auto,
            includeCredits: false,
            webTimeout: 1,
            webDebugDumpHTML: false,
            verbose: false,
            env: environment,
            settings: nil,
            fetcher: UsageFetcher(environment: environment),
            claudeFetcher: ClaudeUsageFetcher(browserDetection: browserDetection),
            browserDetection: browserDetection)
        let strategies = await descriptor.fetchPlan.pipeline.resolveStrategies(context)

        #expect(descriptor.metadata.displayName == "Charm Hyper")
        #expect(descriptor.metadata.cliName == "hyper")
        #expect(descriptor.metadata.dashboardURL == "https://hyper.charm.land")
        #expect(strategies.map(\.id) == ["hyper.api"])
    }
}
