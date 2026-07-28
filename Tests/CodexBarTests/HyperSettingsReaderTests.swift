import Testing
@testable import CodexBarCore

struct HyperSettingsReaderTests {
    @Test
    func `reads and cleans Hyper API key from environment`() {
        #expect(HyperSettingsReader.apiKey(environment: ["HYPER_API_KEY": "  'hyper-key'  "]) == "hyper-key")
    }

    @Test
    func `descriptor uses API credentials and Hyper CLI name`() {
        let descriptor = ProviderDescriptorRegistry.descriptor(for: .hyper)
        #expect(descriptor.metadata.displayName == "Charm Hyper")
        #expect(descriptor.metadata.cliName == "hyper")
        #expect(descriptor.metadata.dashboardURL == "https://hyper.charm.land")
        #expect(descriptor.fetchPlan.strategyID == "hyper.api")
    }
}
