import Testing
@testable import CodexBarCore

@Suite
struct CostUsagePricingTests {
    @Test
    func normalizesCodexModelVariantsExactly() {
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5-codex") == "gpt-5-codex")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.2-codex") == "gpt-5.2-codex")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.1-codex-max") == "gpt-5.1-codex-max")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.4-pro-2026-03-05") == "gpt-5.4-pro")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.3-codex-2026-03-05") == "gpt-5.3-codex")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.3-codex-spark") == "gpt-5.3-codex-spark")
    }

    @Test
    func codexCostSupportsGpt51CodexMax() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.1-codex-max",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func codexCostSupportsGpt53Codex() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func codexCostReturnsZeroForResearchPreviewModel() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex-spark",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)
        #expect(cost == 0)
        #expect(CostUsagePricing.codexDisplayLabel(model: "gpt-5.3-codex-spark") == "Research Preview")
        #expect(CostUsagePricing.codexDisplayLabel(model: "gpt-5.2-codex") == nil)
    }

    @Test
    func normalizesClaudeOpus41DatedVariants() {
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-4-1-20250805") == "claude-opus-4-1")
    }

    @Test
    func claudeCostSupportsOpus41DatedVariant() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-1-20250805",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func claudeCostSupportsOpus46DatedVariant() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-6-20260205",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func claudeCostReturnsNilForUnknownModels() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "glm-4.6",
            inputTokens: 100,
            cacheReadInputTokens: 500,
            cacheCreationInputTokens: 0,
            outputTokens: 40)
        #expect(cost == nil)
    }
}
