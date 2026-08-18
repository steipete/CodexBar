import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCustomPricingTests {
    @Test
    func `overlay exact match uses per-million rates and treats zero as free`() throws {
        let pricing = CostUsageCustomPricing.parse(Data("""
        {
          "openai/gpt-5.4": { "input": 2.5, "output": 15, "cacheRead": 0, "cacheWrite": 3.125 }
        }
        """.utf8))
        let cost = try #require(pricing.costUSD(
            providerID: "openai",
            model: "gpt-5.4",
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            cacheWriteTokens: 1_000_000))
        #expect(abs(cost - (2.5 + 15 + 0 + 3.125)) < 0.000_001)
    }

    @Test
    func `missing overlay fields stay unknown instead of falling through`() {
        let pricing = CostUsageCustomPricing.parse(Data("""
        { "gpt-5.4": { "input": 2.5 } }
        """.utf8))
        #expect(pricing.costUSD(model: "gpt-5.4", inputTokens: 100, outputTokens: 10) == nil)
        #expect(pricing.costUSD(model: "gpt-5.4", inputTokens: 100, outputTokens: 0) == 100 * 2.5 / 1_000_000)
        #expect(pricing.rates(model: "other-model") == nil)
    }

    @Test
    func `codex cost prefers overlay over bundled list prices`() {
        let overlay = CostUsageCustomPricing.parse(Data("""
        { "gpt-5.4": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 } }
        """.utf8))
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 1000,
            cachedInputTokens: 0,
            outputTokens: 100,
            customPricing: overlay)
        #expect(cost == 0)
    }

    @Test
    func `matching partial overlay stays unknown instead of using bundled list prices`() {
        let overlay = CostUsageCustomPricing.parse(Data("""
        { "gpt-5.4": { "input": 2.5 } }
        """.utf8))
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 1000,
            cachedInputTokens: 0,
            outputTokens: 100,
            customPricing: overlay)
        let aggregate = CostUsagePricing.codexAggregateCostUSD(
            model: "gpt-5.4",
            inputTokens: 1000,
            cachedInputTokens: 0,
            outputTokens: 100,
            customPricing: overlay)

        #expect(cost == nil)
        #expect(aggregate == nil)
    }

    @Test
    func `overlay fingerprint invalidates the Codex pricing key`() {
        let first = CostUsagePricingKey.codex(
            modelsDevArtifact: nil,
            formulaVersion: 1,
            customPricingFingerprint: "first")
        let second = CostUsagePricingKey.codex(
            modelsDevArtifact: nil,
            formulaVersion: 1,
            customPricingFingerprint: "second")

        #expect(first != second)
    }

    @Test
    func `aggregate fallback consults the overlay before bundled rates`() {
        let overlay = CostUsageCustomPricing.parse(Data("""
        { "gpt-5.4": { "input": 0, "output": 0, "cacheRead": 0, "cacheWrite": 0 } }
        """.utf8))
        let cost = CostUsagePricing.codexAggregateCostUSD(
            model: "gpt-5.4",
            inputTokens: 1000,
            cachedInputTokens: 0,
            outputTokens: 100,
            customPricing: overlay)
        #expect(cost == 0)
        let bundled = CostUsagePricing.codexAggregateCostUSD(
            model: "gpt-5.4",
            inputTokens: 1000,
            cachedInputTokens: 0,
            outputTokens: 100,
            customPricing: .empty)
        #expect(bundled != 0)
        #expect(bundled != nil)
    }
}
