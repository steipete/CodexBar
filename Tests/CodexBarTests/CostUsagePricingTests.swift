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

        let expected = (90.0 * 5e-6) + (10.0 * 5e-7) + (5.0 * 3e-5)
        #expect(cost == expected)
    }

    @Test
    func `codex cost applies gpt54 and gpt55 long context tiers`() throws {
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

        #expect(gpt54 == (272_000.0 * 2.5e-6) + (1.0 * 5e-6) + (10.0 * 1.5e-5))
        #expect(gpt55 == (272_000.0 * 5e-6) + (1.0 * 1e-5) + (10.0 * 3e-5))
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
        let gpt54Mini = CostUsagePricing.codexPriorityCostUSD(
            model: "gpt-5.4-mini",
            inputTokens: 272_001,
            cachedInputTokens: 0,
            outputTokens: 10)

        #expect(gpt55 == nil)
        #expect(gpt54Mini == nil)
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
        #expect(aboveBoundary == (272_000.0 * 5e-6) + (1.0 * 1e-5) + (10.0 * 3e-5))
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

        let expected = (200_000.0 * 3e-6)
            + (10.0 * 6e-6)
            + (5.0 * 0.3e-6)
            + (5.0 * 3.75e-6)
            + (5.0 * 15e-6)
        #expect(cost == expected)
    }

    private static func seedModelsDevCache(_ json: String) throws -> URL {
        let root = try Self.cacheRoot()
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: root)
        return root
    }

    private static func cacheRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-pricing-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }
}
