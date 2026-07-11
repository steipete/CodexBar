import Foundation
import Testing
@testable import CodexBarCore

struct CostUsagePricingTests {
    @Test
    func `normalizes codex model variants exactly`() {
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5-codex") == "gpt-5-codex")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.2-codex") == "gpt-5.2-codex")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.1-codex-max") == "gpt-5.1-codex-max")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.4-pro-2026-03-05") == "gpt-5.4-pro")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.4-mini-2026-03-17") == "gpt-5.4-mini")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.4-nano-2026-03-17") == "gpt-5.4-nano")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.5-2026-04-23") == "gpt-5.5")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.5-pro-2026-04-23") == "gpt-5.5-pro")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.3-codex-2026-03-05") == "gpt-5.3-codex")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.3-codex-spark") == "gpt-5.3-codex-spark")
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5.6-sol") == "gpt-5.6-sol")
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5.6-terra") == "gpt-5.6-terra")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.6-luna") == "gpt-5.6-luna")
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.6") == "gpt-5.6-sol")
        // Fictitious dated suffixes only exercise normalize stripping (not released snapshot IDs).
        #expect(CostUsagePricing.normalizeCodexModel("gpt-5.6-sol-2099-01-01") == "gpt-5.6-sol")
        #expect(CostUsagePricing.normalizeCodexModel("openai/gpt-5.6-terra-2099-01-01") == "gpt-5.6-terra")
    }

    @Test
    func `unattributed codex usage stays unpriced despite a catalog collision`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "unknown": {
                "id": "unknown",
                "cost": { "input": 99, "output": 199 }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: CostUsagePricing.codexUnattributedModel,
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        #expect(cost == nil)
    }

    @Test
    func `codex cost supports gpt51 codex max`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.1-codex-max",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func `codex cost supports gpt53 codex`() {
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func `codex cost supports gpt54 mini and nano`() {
        let mini = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4-mini-2026-03-17",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)
        let nano = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4-nano",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5)

        #expect(mini != nil)
        #expect(nano != nil)
    }

    @Test
    func `codex cost supports gpt55 bundled fallback`() throws {
        let root = try Self.cacheRoot()
        let cost = CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5.5-2026-04-23",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        // Codex `input_tokens` includes cached reads, so only the 90 non-cached tokens are
        // billed at the input rate; the 10 cached tokens are billed at the cache rate.
        let expected = (90.0 * 5e-6) + (10.0 * 5e-7) + (5.0 * 3e-5)
        #expect(cost == expected)
    }

    @Test
    func `codex cost supports gpt56 sol terra luna bundled fallback`() throws {
        // Empty models.dev cache root forces the built-in table for GPT-5.6 tiers.
        let root = try Self.cacheRoot()

        let sol = CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        let terra = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        let luna = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-luna",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        let alias = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        // Rates per token: Sol $5/$30 per 1M, Terra $2.50/$15, Luna $1/$6;
        // cache read is 10% of input. Non-cached input is 90 tokens.
        #expect(sol == (90.0 * 5e-6) + (10.0 * 5e-7) + (5.0 * 3e-5))
        #expect(terra == (90.0 * 2.5e-6) + (10.0 * 2.5e-7) + (5.0 * 1.5e-5))
        #expect(luna == (90.0 * 1e-6) + (10.0 * 1e-7) + (5.0 * 6e-6))
        // Unsuffixed gpt-5.6 alias routes to Sol.
        #expect(alias == sol)
    }

    @Test
    func `codex models dev falls back from gpt56 alias to canonical sol pricing`() throws {
        let canonicalOnlyRoot = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 7, "output": 31 }
              }
            }
          }
        }
        """)
        let aliasAndCanonicalRoot = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6": {
                "id": "gpt-5.6",
                "cost": { "input": 3, "output": 13 }
              },
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 7, "output": 31 }
              }
            }
          }
        }
        """)

        let canonicalFallback = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: canonicalOnlyRoot)
        let exactAlias = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCacheRoot: aliasAndCanonicalRoot)

        #expect(canonicalFallback == 100.0 * 7e-6)
        #expect(exactAlias == 100.0 * 3e-6)
    }

    @Test
    func `codex pricing key distinguishes an empty long context block from no block`() throws {
        let withoutLongContext = try Self.modelsDevArtifact("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 5, "output": 30 }
              }
            }
          }
        }
        """)
        let withEmptyLongContext = try Self.modelsDevArtifact("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": {
                  "input": 5,
                  "output": 30,
                  "context_over_200k": {}
                }
              }
            }
          }
        }
        """)

        let withoutKey = CostUsagePricingKey.codex(
            modelsDevArtifact: withoutLongContext,
            formulaVersion: 1)
        let withEmptyKey = CostUsagePricingKey.codex(
            modelsDevArtifact: withEmptyLongContext,
            formulaVersion: 1)

        #expect(withoutKey != withEmptyKey)
    }

    @Test
    func `codex cost applies gpt56 long context rates`() throws {
        let root = try Self.cacheRoot()
        let sol = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 272_001,
            cachedInputTokens: 10,
            outputTokens: 10,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: root)
        let terra = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 272_001,
            cachedInputTokens: 10,
            outputTokens: 10,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: root)
        let luna = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-luna",
            inputTokens: 272_001,
            cachedInputTokens: 10,
            outputTokens: 10,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: root)

        // Long-context (>272K) rates apply to the entire request. Total input contains 10 cached,
        // 20 cache-write, and 271,971 ordinary input tokens.
        #expect(sol == (271_971.0 * 1e-5) + (10.0 * 1e-6) + (20.0 * 1.25e-5) + (10.0 * 4.5e-5))
        #expect(terra == (271_971.0 * 5e-6) + (10.0 * 5e-7) + (20.0 * 6.25e-6) + (10.0 * 2.25e-5))
        #expect(luna == (271_971.0 * 2e-6) + (10.0 * 2e-7) + (20.0 * 2.5e-6) + (10.0 * 9e-6))
    }

    @Test
    func `codex cost bills gpt56 cache writes at one point two five x input`() throws {
        let root = try Self.cacheRoot()
        // Total prompt 100: 70 uncached + 20 cache-write + 10 cache-read.
        let sol = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: root)

        let expected = (70.0 * 5e-6) + (10.0 * 5e-7) + (20.0 * 6.25e-6) + (5.0 * 3e-5)
        #expect(sol == expected)
    }

    @Test
    func `codex priority cost supports gpt56 tiers`() {
        let sol = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10)
        let terra = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10)
        let luna = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-luna",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10)

        // Priority is 2x short-context rates (Sol input $10/1M, etc.).
        #expect(sol == (80.0 * 1e-5) + (20.0 * 1e-6) + (10.0 * 6e-5))
        #expect(terra == (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5))
        #expect(luna == (80.0 * 2e-6) + (20.0 * 2e-7) + (10.0 * 1.2e-5))
    }

    @Test
    func `codex priority cost uses explicit cache write rates`() {
        let sol = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            cacheWriteInputTokens: 20,
            outputTokens: 5)
        let terra = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 100,
            cachedInputTokens: 10,
            cacheWriteInputTokens: 20,
            outputTokens: 5)
        let luna = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-luna",
            inputTokens: 100,
            cachedInputTokens: 10,
            cacheWriteInputTokens: 20,
            outputTokens: 5)
        let modelWithoutCacheWriteSupport = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 10,
            cacheWriteInputTokens: 20,
            outputTokens: 5)

        #expect(sol == (70.0 * 1e-5) + (10.0 * 1e-6) + (20.0 * 1.25e-5) + (5.0 * 6e-5))
        #expect(terra == (70.0 * 5e-6) + (10.0 * 5e-7) + (20.0 * 6.25e-6) + (5.0 * 3e-5))
        #expect(luna == (70.0 * 2e-6) + (10.0 * 2e-7) + (20.0 * 2.5e-6) + (5.0 * 1.2e-5))
        // A model without an explicit Priority cache-write price keeps the legacy input-rate fold.
        #expect(
            modelWithoutCacheWriteSupport ==
                (90.0 * 1.25e-5) + (10.0 * 1.25e-6) + (5.0 * 7.5e-5))
    }

    @Test
    func `codex cost applies gpt54 and gpt55 long context rates to full session`() throws {
        let root = try Self.cacheRoot()
        let gpt54 = CostUsagePricing.codexCostUSD(
            model: "gpt-5.4",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10,
            modelsDevCacheRoot: root)
        let gpt55 = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10,
            modelsDevCacheRoot: root)

        #expect(gpt54 == (272_001.0 * 5e-6) + (10.0 * 2.25e-5))
        #expect(gpt55 == (272_001.0 * 1e-5) + (10.0 * 4.5e-5))
    }

    @Test
    func `codex cost keeps normal rates at long context input boundary`() throws {
        let root = try Self.cacheRoot()
        let gpt55 = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_000,
            cachedInputTokens: 0,
            outputTokens: 128_000,
            modelsDevCacheRoot: root)

        #expect(gpt55 == (272_000.0 * 5e-6) + (128_000.0 * 3e-5))
    }

    @Test
    func `codex cost applies long context rates to all cached and non cached input`() throws {
        let root = try Self.cacheRoot()
        let gpt55 = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 300_000,
            cachedInputTokens: 200_000,
            outputTokens: 10,
            modelsDevCacheRoot: root)

        // 200K cached reads are a subset of the 300K input, leaving 100K non-cached input.
        let cached = 200_000.0 * 1e-6
        let nonCached = 100_000.0 * 1e-5
        let output = 10.0 * 4.5e-5

        #expect(gpt55 == cached + nonCached + output)
    }

    @Test
    func `codex cost clamps cache reads to input tokens`() throws {
        // `cached_input_tokens` can never exceed `input_tokens` in real Codex data; if it does,
        // clamp cached to input so the surplus is not invented and input is never double-billed.
        let root = try Self.cacheRoot()
        let gpt55 = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 20,
            cachedInputTokens: 500,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        let expected = (20.0 * 5e-7) + (5.0 * 3e-5)

        #expect(gpt55 == expected)
    }

    @Test
    func `codex cost does not double bill cached input tokens`() throws {
        // Regression for the cached double-count: input_tokens includes cached reads, so a turn
        // with 1000 input / 900 cached must bill 100 tokens at the input rate and 900 at the
        // cache rate — not the full 1000 at the input rate plus 900 again at the cache rate.
        let root = try Self.cacheRoot()
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5-codex",
            inputTokens: 1000,
            cachedInputTokens: 900,
            outputTokens: 10,
            modelsDevCacheRoot: root)

        let expected = (100.0 * 1.25e-6) + (900.0 * 1.25e-7) + (10.0 * 1e-5)
        #expect(cost == expected)
    }

    @Test
    func `codex priority cost applies model specific fast rates`() {
        let gpt54 = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.4",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10)
        let gpt55 = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10)
        let gpt54Mini = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.4-mini",
            inputTokens: 100,
            cachedInputTokens: 20,
            outputTokens: 10)

        #expect(gpt54 == (80.0 * 5e-6) + (20.0 * 5e-7) + (10.0 * 3e-5))
        #expect(gpt55 == (80.0 * 1.25e-5) + (20.0 * 1.25e-6) + (10.0 * 7.5e-5))
        #expect(gpt54Mini == (80.0 * 1.5e-6) + (20.0 * 1.5e-7) + (10.0 * 9e-6))
    }

    @Test
    func `codex priority cost is unavailable for long context requests`() {
        let gpt55 = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)
        let gpt56Sol = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)
        let gpt56Terra = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-terra",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)
        let gpt56Luna = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.6-luna",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)
        let gpt54Mini = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.4-mini",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)

        #expect(gpt55 == nil)
        #expect(gpt56Sol == nil)
        #expect(gpt56Terra == nil)
        #expect(gpt56Luna == nil)
        #expect(gpt54Mini == nil)
    }

    @Test
    func `codex priority cost counts only input tokens toward the limit`() {
        let eligible = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 200_000,
            cachedInputTokens: 100_000,
            outputTokens: 10)
        let boundary = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_000,
            cachedInputTokens: 0,
            outputTokens: 10)
        let overLimit = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)

        #expect(eligible == (100_000.0 * 1.25e-5) + (100_000.0 * 1.25e-6) + (10.0 * 7.5e-5))
        #expect(boundary != nil)
        #expect(overLimit == nil)
    }

    @Test
    func `codex priority cost remains available at priority input boundary`() {
        let gpt55 = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_000,
            cachedInputTokens: 0,
            outputTokens: 10)

        #expect(gpt55 == (272_000.0 * 1.25e-5) + (10.0 * 7.5e-5))
    }

    @Test
    func `codex models dev pricing uses codex long context threshold`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.5": {
                "id": "gpt-5.5",
                "cost": {
                  "input": 5,
                  "output": 30,
                  "cache_read": 0.5,
                  "context_over_200k": {
                    "input": 10,
                    "output": 45,
                    "cache_read": 1
                  }
                }
              }
            }
          }
        }
        """)

        let atBoundary = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_000,
            cachedInputTokens: 0,
            outputTokens: 10,
            modelsDevCacheRoot: root)
        let aboveBoundary = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10,
            modelsDevCacheRoot: root)

        #expect(atBoundary == (272_000.0 * 5e-6) + (10.0 * 3e-5))
        #expect(aboveBoundary == (272_001.0 * 1e-5) + (10.0 * 4.5e-5))
    }

    @Test
    func `codex models dev cached fallback uses long context input rate when cache read is absent`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.5": {
                "id": "gpt-5.5",
                "cost": {
                  "input": 5,
                  "output": 30,
                  "context_over_200k": {
                    "input": 10,
                    "output": 45
                  }
                }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.5",
            inputTokens: 300_000,
            cachedInputTokens: 200_000,
            outputTokens: 10,
            modelsDevCacheRoot: root)

        // The catalog has a long-context block but omits cache_read, so preserve its omission
        // semantics: cached tokens fall back to the long-context input rate rather than mixing in
        // one field from the bundled table.
        let expected = (100_000.0 * 10e-6) + (200_000.0 * 10e-6) + (10.0 * 45e-6)
        #expect(cost == expected)
    }
}

extension CostUsagePricingTests {
    @Test
    func `codex models dev uses bundled short cache rates only when catalog omits them`() throws {
        let missingRoot = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 5, "output": 30 }
              }
            }
          }
        }
        """)
        let explicitZeroRoot = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": { "input": 5, "output": 30, "cache_read": 0, "cache_write": 0 }
              }
            }
          }
        }
        """)

        let missing = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 0,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: missingRoot)
        let explicitZero = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 0,
            cacheWriteInputTokens: 20,
            modelsDevCacheRoot: explicitZeroRoot)

        #expect(missing == (70.0 * 5e-6) + (10.0 * 5e-7) + (20.0 * 6.25e-6))
        #expect(explicitZero == 70.0 * 5e-6)
    }

    @Test
    func `codex models dev falls back bundled long context rates when catalog omits them`() throws {
        // Catalog has short-context rates only; bundled table supplies the 272K threshold + rates.
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": {
                  "input": 5,
                  "output": 30,
                  "cache_read": 0.5
                }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10,
            modelsDevCacheRoot: root)

        // Without bundled above-threshold fallback this would bill short rates ($5/$30) despite
        // entering long-context mode via the bundled threshold.
        #expect(cost == (272_001.0 * 1e-5) + (10.0 * 4.5e-5))
    }

    @Test
    func `codex models dev overrides every gpt56 long context token bucket`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.6-sol": {
                "id": "gpt-5.6-sol",
                "cost": {
                  "input": 1,
                  "output": 2,
                  "cache_read": 0.1,
                  "cache_write": 1.25,
                  "context_over_200k": {
                    "input": 11,
                    "output": 22,
                    "cache_read": 1.1,
                    "cache_write": 13.75
                  }
                }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.6-sol",
            inputTokens: 272_001,
            cachedInputTokens: 100_000,
            outputTokens: 10,
            cacheWriteInputTokens: 50000,
            modelsDevCacheRoot: root)

        let expected = (122_001.0 * 11e-6)
            + (100_000.0 * 1.1e-6)
            + (50000.0 * 13.75e-6)
            + (10.0 * 22e-6)
        #expect(cost == expected)
    }

    @Test
    func `codex cost supports gpt55 pro bundled fallback`() throws {
        let root = try Self.cacheRoot()
        let cost = CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5.5-pro-2026-04-23",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        // gpt-5.5-pro has no cache-read rate, so cached falls back to the input rate; with 90
        // non-cached + 10 cached priced at the same rate this is 100 tokens at 3e-5.
        let expected = (100.0 * 3e-5) + (5.0 * 1.8e-4)
        #expect(cost == expected)
    }

    @Test
    func `codex cost returns zero for research preview fallback model`() throws {
        let root = try Self.cacheRoot()
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex-spark",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)
        #expect(cost == 0)
        #expect(CostUsagePricing.codexDisplayLabel(model: "gpt-5.3-codex-spark") == "Research Preview")
        #expect(CostUsagePricing.codexDisplayLabel(model: "gpt-5.2-codex") == nil)
    }

    @Test
    func `codex cost prefers models dev cache over bundled fallback`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.5": {
                "id": "gpt-5.5",
                "cost": { "input": 10, "output": 20, "cache_read": 1 }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        let expected = (90.0 * 10e-6) + (10.0 * 1e-6) + (5.0 * 20e-6)
        #expect(cost == expected)
    }

    @Test
    func `codex cost lets models dev override research preview fallback`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-5.3-codex-spark": {
                "id": "gpt-5.3-codex-spark",
                "cost": { "input": 2, "output": 8, "cache_read": 0.2 }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-5.3-codex-spark",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        let expected = (90.0 * 2e-6) + (10.0 * 0.2e-6) + (5.0 * 8e-6)
        #expect(cost == expected)
        #expect(CostUsagePricing.codexDisplayLabel(model: "gpt-5.3-codex-spark") == "Research Preview")
    }

    @Test
    func `codex cost falls back to bundled pricing when models dev misses provider model`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "gpt-5.5": {
                "id": "gpt-5.5",
                "cost": { "input": 10, "output": 20, "cache_read": 1 }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.codexCostUSD(
            model: "openai/gpt-5.5",
            inputTokens: 100,
            cachedInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        let expected = (90.0 * 5e-6) + (10.0 * 5e-7) + (5.0 * 3e-5)
        #expect(cost == expected)
    }

    @Test
    func `normalizes claude opus41 dated variants`() {
        #expect(CostUsagePricing.normalizeClaudeModel("claude-opus-4-1-20250805") == "claude-opus-4-1")
    }

    @Test
    func `claude cost supports opus41 dated variant`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-1-20250805",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func `claude cost supports opus46 dated variant`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-6-20260205",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        #expect(cost != nil)
    }

    @Test
    func `claude cost supports opus47`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-7",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5)
        let expected = (10.0 * 5e-6) + (5.0 * 2.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost supports opus48`() throws {
        // Point at a fresh, empty cache root so the models.dev lookup misses and this
        // exercises the built-in fallback table specifically — not a local cache hit.
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-opus-4-8",
            inputTokens: 10,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 5,
            modelsDevCacheRoot: emptyCacheRoot)
        let expected = (10.0 * 5e-6) + (5.0 * 2.5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost supports fable5 bundled fallback`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 10,
            outputTokens: 5,
            modelsDevCacheRoot: emptyCacheRoot)
        let expected = (100.0 * 1e-5) + (20.0 * 1e-6) + (10.0 * 1.25e-5) + (5.0 * 5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost preserves historical sonnet46 long context pricing`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let historical = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_359_999),
            modelsDevCacheRoot: emptyCacheRoot)
        let current = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_360_000),
            modelsDevCacheRoot: emptyCacheRoot)

        #expect(historical == 1.44)
        #expect(current == 0.72)
    }

    @Test
    func `claude cost ignores stale sonnet46 threshold catalog after cutover`() throws {
        let cacheRoot = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 240_000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            pricingDate: Date(timeIntervalSince1970: 1_773_360_000),
            modelsDevCacheRoot: cacheRoot)

        #expect(cost == 0.72)
    }

    @Test
    func `claude cost prices one hour cache writes separately`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-fable-5",
            inputTokens: 100,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 30,
            cacheCreationInputTokens1h: 20,
            outputTokens: 5,
            modelsDevCacheRoot: emptyCacheRoot)
        let expected = (100.0 * 1e-5)
            + (20.0 * 1e-6)
            + (10.0 * 1.25e-5)
            + (20.0 * 2e-5)
            + (5.0 * 5e-5)
        #expect(cost == expected)
    }

    @Test
    func `claude cost applies long context rates across cache write durations`() throws {
        let cacheRoot = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-threshold-model": {
                "id": "claude-threshold-model",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-threshold-model",
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 240_000,
            cacheCreationInputTokens1h: 120_000,
            outputTokens: 0,
            modelsDevCacheRoot: cacheRoot)
        let expected = (120_000.0 * 12e-6)
            + (120_000.0 * 7.5e-6)
        #expect(cost == expected)
    }

    @Test
    func `claude sonnet46 uses standard pricing across full context`() throws {
        let emptyCacheRoot = try Self.cacheRoot()
        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 0,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 240_000,
            outputTokens: 0,
            modelsDevCacheRoot: emptyCacheRoot)
        #expect(cost == 240_000.0 * 3.75e-6)
    }

    @Test
    func `claude cost returns nil for unknown models`() {
        let cost = CostUsagePricing.claudeCostUSD(
            model: "glm-4.6",
            inputTokens: 100,
            cacheReadInputTokens: 500,
            cacheCreationInputTokens: 0,
            outputTokens: 40)
        #expect(cost == nil)
    }

    @Test
    func `claude cost prefers models dev cache with threshold pricing`() throws {
        let root = try Self.seedModelsDevCache("""
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-6": {
                "id": "claude-sonnet-4-6",
                "cost": {
                  "input": 3,
                  "output": 15,
                  "cache_read": 0.3,
                  "cache_write": 3.75,
                  "context_over_200k": {
                    "input": 6,
                    "output": 22.5,
                    "cache_read": 0.6,
                    "cache_write": 7.5
                  }
                }
              }
            }
          }
        }
        """)

        let cost = CostUsagePricing.claudeCostUSD(
            model: "claude-sonnet-4-6",
            inputTokens: 200_010,
            cacheReadInputTokens: 5,
            cacheCreationInputTokens: 5,
            outputTokens: 5,
            modelsDevCacheRoot: root)

        let expected = (200_010.0 * 6e-6)
            + (5.0 * 0.6e-6)
            + (5.0 * 7.5e-6)
            + (5.0 * 22.5e-6)
        #expect(cost == expected)
    }

    private static func seedModelsDevCache(_ json: String) throws -> URL {
        let root = try Self.cacheRoot()
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: root)
        return root
    }

    private static func modelsDevArtifact(_ json: String) throws -> ModelsDevCacheArtifact {
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        return ModelsDevCacheArtifact(
            version: ModelsDevCache.artifactVersion,
            fetchedAt: Date(timeIntervalSince1970: 0),
            catalog: catalog)
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
