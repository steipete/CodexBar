import Foundation
import Testing
@testable import CodexBarCore

struct CostUsagePricingClaudeThresholdTests {
    @Test(arguments: [200_001, 271_999, 272_000, 272_001], [0, 100_000])
    func `Claude uses the OpenAI prompt boundary while retaining catalog rates`(
        totalInput: Int,
        cacheRead: Int) throws
    {
        let catalog = try Self.catalog()
        let cacheWrite = 10000
        let input = totalInput - cacheRead - cacheWrite
        let claude = try #require(CostUsagePricing.claudeCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: input,
            cacheReadInputTokens: cacheRead,
            cacheCreationInputTokens: cacheWrite,
            outputTokens: 13,
            modelsDevCatalog: catalog))
        let codex = try #require(CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: totalInput,
            cachedInputTokens: cacheRead,
            outputTokens: 13,
            cacheWriteInputTokens: cacheWrite,
            modelsDevCatalog: catalog))
        let expected = totalInput > 272_000
            ? Double(input) * 7e-6 + Double(cacheRead) * 0.5e-6 + Double(cacheWrite) * 9e-6 + 13 * 11e-6
            : Double(input) * 2e-6 + Double(cacheRead) * 0.25e-6 + Double(cacheWrite) * 3e-6 + 13 * 4e-6
        #expect(abs(claude - expected) < 1e-10)
        #expect(abs(claude - codex) < 1e-10)
    }

    @Test(arguments: ["anthropic", "openai"])
    func `models without a bundled OpenAI threshold retain the catalog boundary`(provider: String) throws {
        let catalog = try Self.catalog(provider: provider, model: "threshold-fixture")
        let cost = try #require(CostUsagePricing.claudeCostUSD(
            model: "\(provider)/threshold-fixture",
            inputTokens: 100_001,
            cacheReadInputTokens: 90000,
            cacheCreationInputTokens: 10000,
            outputTokens: 13,
            modelsDevCatalog: catalog))
        #expect(abs(cost - (100_001 * 7e-6 + 90000 * 0.5e-6 + 10000 * 9e-6 + 13 * 11e-6)) < 1e-10)
    }

    /// Deliberately distinct from bundled rates: only the boundary may come from the bundled table.
    static func catalog(provider: String = "openai", model: String = "gpt-5.6-sol") throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"\(provider)":{"id":"\(provider)","models":{"\(model)":{"id":"\(model)","cost":{
          "input":2,"output":4,"cache_read":0.25,"cache_write":3,
          "context_over_200k":{"input":7,"output":11,"cache_read":0.5,"cache_write":9}
        }}}}}
        """.utf8))
    }
}
