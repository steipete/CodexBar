import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

extension GrokCostUsagePricingTests {
    @Test
    func `xai routes normalize response build suffix only after exact lookup`() throws {
        let normalizedOnly = try Self.catalog()
        let exactJSON = """
        {
          "xai": {
            "id": "xai",
            "models": {
              "grok-4.6-build": {
                "id": "grok-4.6-build",
                "cost": { "input": 7, "output": 14 }
              },
              "grok-4.6": {
                "id": "grok-4.6",
                "cost": { "input": 2, "output": 6 }
              }
            }
          }
        }
        """
        let exactCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(exactJSON.utf8))

        let normalized = CostUsagePricing.codexCostUSD(
            model: "xai/grok-4.6-build",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: normalizedOnly)
        let realBuild = CostUsagePricing.codexCostUSD(
            model: "xai/grok-build-0.1",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: normalizedOnly)
        let exact = CostUsagePricing.codexCostUSD(
            model: "xai/grok-4.6-build",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: exactCatalog)
        let bare = CostUsagePricing.codexCostUSD(
            model: "grok-4.6-build",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: normalizedOnly)

        #expect(normalized == 100.0 * 2e-6)
        #expect(realBuild == 100.0 * 10e-6)
        #expect(exact == 100.0 * 7e-6)
        #expect(bare == nil)
    }
}
