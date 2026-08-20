import Testing
@testable import CodexBar
@testable import CodexBarCore

struct GrokXAISpendCatalogTests {
    @Test
    func `grok and xai publish through the snapshot-backed spend catalog`() {
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.grok))
        #expect(UsageStore.tokenCostRequiresProviderSnapshot(.xai))
        #expect(ProviderDescriptorRegistry.descriptor(for: .grok).tokenCost.supportsTokenCost)
        #expect(ProviderDescriptorRegistry.descriptor(for: .xai).tokenCost.supportsTokenCost)
    }
}
