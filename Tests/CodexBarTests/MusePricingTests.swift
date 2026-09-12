import Foundation
import Testing
@testable import CodexBarCore

struct MusePricingTests {
    @Test
    func `normalizes muse model variants correctly`() {
        #expect(CostUsagePricing.normalizeMuseModel("muse-spark-1.3") == "muse-spark-1.3")
        #expect(CostUsagePricing.normalizeMuseModel("meta/muse-spark-1.2") == "muse-spark-1.2")
        #expect(CostUsagePricing.normalizeMuseModel("muse-spark-2026-03") == "muse-spark")
        #expect(CostUsagePricing.normalizeMuseModel("muse-code-latest") == "muse-code")
        #expect(CostUsagePricing.normalizeMuseModel("muse-custom") == "muse-custom")
    }

    @Test
    func `muse cost computes standard pricing correctly`() {
        let cost = CostUsagePricing.museCostUSD(
            model: "muse-spark-1.3",
            inputTokens: 1000,
            cacheReadInputTokens: 100,
            outputTokens: 50,
            isContributor: false)

        let expected = (900.0 * 1.25e-6) + (100.0 * 0.125e-6) + (50.0 * 4.25e-6)
        #expect(abs((cost ?? 0) - expected) < 1e-9)
    }

    @Test
    func `muse cost computes contributor pricing correctly`() {
        let cost = CostUsagePricing.museCostUSD(
            model: "muse-spark-1.3",
            inputTokens: 1000,
            cacheReadInputTokens: 100,
            outputTokens: 50,
            isContributor: true)

        let expected = (900.0 * 0.10e-6) + (100.0 * 0.01e-6) + (50.0 * 0.20e-6)
        #expect(abs((cost ?? 0) - expected) < 1e-9)
    }

    @Test
    func `contributor pricing survives model fallback`() {
        // Unknown model → Contributor Spark rates, never the standard entry.
        let unknown = CostUsagePricing.museCostUSD(
            model: "muse-experimental", inputTokens: 1_000_000, outputTokens: 0, isContributor: true)
        #expect(abs((unknown ?? 0) - 0.10) < 1e-9)
        // muse-code has its own Contributor entry.
        let code = CostUsagePricing.museCostUSD(
            model: "muse-code", inputTokens: 1_000_000, outputTokens: 0, isContributor: true)
        #expect(abs((code ?? 0) - 0.10) < 1e-9)
        // A model name that already carries the Contributor suffix keeps that tier.
        let suffixed = CostUsagePricing.museCostUSD(
            model: "muse-spark-1.2-contributor", inputTokens: 1_000_000, outputTokens: 0, isContributor: false)
        #expect(abs((suffixed ?? 0) - 0.10) < 1e-9)
        // Standard accounts keep standard rates for known and unknown models.
        let standard = CostUsagePricing.museCostUSD(
            model: "muse-experimental", inputTokens: 1_000_000, outputTokens: 0, isContributor: false)
        #expect(abs((standard ?? 0) - 1.25) < 1e-9)
    }

    @Test
    func `muse cost falls back gracefully for unknown models`() {
        let cost = CostUsagePricing.museCostUSD(
            model: "unknown-muse-variant",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            outputTokens: 100)

        let expected = (1000.0 * 1.25e-6) + (100.0 * 4.25e-6)
        #expect(abs((cost ?? 0) - expected) < 1e-9)
    }
}
