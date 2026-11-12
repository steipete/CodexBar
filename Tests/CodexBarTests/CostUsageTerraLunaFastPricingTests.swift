import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageTerraLunaFastPricingTests {
    @Test(arguments: [false, true])
    func `Terra and Luna Fast use published rates on both sides of 272K`(useCatalog: Bool) throws {
        let catalog = if useCatalog {
            try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
            {
              "openai": {
                "id": "openai",
                "models": {
                  "gpt-6.1-terra": {
                    "id": "gpt-6.1-terra",
                    "cost": { "input": 1, "output": 5, "cache_read": 0.05, "cache_write": 1.25 }
                  },
                  "gpt-6-luna": {
                    "id": "gpt-6-luna",
                    "cost": { "input": 0.1, "output": 0.5, "cache_read": 0.01, "cache_write": 0.125 }
                  }
                }
              }
            }
            """.utf8))
        } else {
            ModelsDevCatalog(providers: [:])
        }

        // The catalog fixture omits context tiers to exercise the bundled long-context fallback.
        // Expected totals use 1K cached reads, 2K cache writes, and 3K output tokens.
        for (model, input, expected) in [
            ("gpt-6.1-terra", 272_000, 0.5731),
            ("openai/gpt-6.1-terra-2099-01-01", 272_001, 1.131204),
            ("gpt-6-luna", 272_000, 0.05732),
            ("openai/gpt-6-luna-2099-01-01", 272_001, 0.1131404),
        ] {
            let cost = CostUsagePricing.codexPriorityCostUSD(
                model: model,
                inputTokens: input,
                cachedInputTokens: 1000,
                cacheWriteInputTokens: 2000,
                outputTokens: 3000,
                modelsDevCatalog: catalog,
                customPricing: .empty)
            #expect(try abs(#require(cost) - expected) < 1e-12)
        }
    }
}
