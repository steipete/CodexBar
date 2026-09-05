import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageClaudeResolverTests {
    private struct Tokens {
        let input: Int
        let read: Int
        let create: Int
        let hour: Int
        let output: Int
    }

    @Test
    func `memoized pricing matches independent scalar resolution across models dates and token buckets`() throws {
        let catalog = try Self.catalog()
        let resolver = CostUsagePricing.ClaudeResolver(catalog: catalog)
        let models = [
            "claude-test-known", "claude-test-unknown", "claude-test-zero", "claude-test-null",
            "claude-test-empty-context", "claude-test-partial-context", "claude-test-id-fallback",
            "claude-sonnet-4-5-20250929", "claude-sonnet-4-5", "claude-sonnet-4-5@20250929",
            "anthropic.claude-sonnet-4-5-20250929-v1:0", "us.anthropic.claude-sonnet-4-5-v1:0",
            "claude-sonnet-4-5@default", "claude-sonnet-4-6", "claude-opus-4-6",
            "anthropic/claude-sonnet-4-6", "vertex/claude-sonnet-4-5", "anthropic.anthropic.example",
            "anthropic.example", "example", "collision", "openai/collision", "unrecognized/collision",
            "gpt-fixture", "gemini-fixture", "kimi-fixture", "minimax-fixture", "deepseek-fixture",
            "kimi-coding/k3[1m]", "k3[1m]", "kimi-for-coding/k3", "opencode-free/fixture",
            "claude-test-caf\u{e9}", "claude-test-cafe\u{301}", "CLAUDE-test-known",
            " \tclaude-test-known\n", "\u{2003}claude-test-known\u{2003}", "", " \n", "unknown\0model",
        ]
        let cutoff = Date(timeIntervalSince1970: 1_773_360_000)
        let dates: [Date?] = [nil, cutoff.addingTimeInterval(-0.001), cutoff, cutoff.addingTimeInterval(1)]
        let tokens: [Tokens] = [
            Tokens(input: 0, read: 0, create: 0, hour: 0, output: 0),
            Tokens(input: -1, read: -2, create: -3, hour: -4, output: -5),
            Tokens(input: 1, read: 2, create: 3, hour: 1, output: 4),
            Tokens(input: 199_997, read: 1, create: 1, hour: 0, output: 1_000_000),
            Tokens(input: 199_998, read: 1, create: 1, hour: 1, output: 7),
            Tokens(input: 199_999, read: 1, create: 1, hour: 9, output: 8),
            Tokens(input: 0, read: 200_001, create: 0, hour: 0, output: 9),
            Tokens(input: 0, read: 0, create: 200_001, hour: 200_001, output: 10),
            Tokens(input: 150_000, read: 0, create: 1, hour: -1, output: 11),
        ]
        let reads = ModelsDevCache.MetadataReadRecorder()
        ModelsDevCache.withMetadataReadRecorderForTesting(reads) {
            // Scalar resolution remains uncached and never calls ClaudeResolver.
            for model in models + models.reversed() {
                #expect(Array(resolver.normalize(model).utf8) ==
                    Array(CostUsagePricing.normalizeClaudeModel(model).utf8))
                for date in dates {
                    for token in tokens {
                        let expected = CostUsagePricing.claudeCostUSD(
                            model: model,
                            inputTokens: token.input,
                            cacheReadInputTokens: token.read,
                            cacheCreationInputTokens: token.create,
                            cacheCreationInputTokens1h: token.hour,
                            outputTokens: token.output,
                            pricingDate: date,
                            modelsDevCatalog: catalog)
                        let actual = resolver.costUSD(
                            model: model,
                            inputTokens: token.input,
                            cacheReadInputTokens: token.read,
                            cacheCreationInputTokens: token.create,
                            cacheCreationInputTokens1h: token.hour,
                            outputTokens: token.output,
                            pricingDate: date)
                        #expect(actual == expected, "model=\(model), date=\(String(describing: date)), tokens=\(token)")
                    }
                }
            }
        }
        #expect(reads.snapshot() == 0)
    }

    @Test
    func `normalization preserves exact bytes without preloading or preseeded identities`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let resolver = CostUsagePricing.ClaudeResolver(now: Date(), cacheRoot: env.cacheRoot)
        let reads = ModelsDevCache.MetadataReadRecorder()
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        let models = ["anthropic.anthropic.example", "anthropic.example", "caf\u{e9}", "cafe\u{301}"]
        ModelsDevCache.withMetadataReadRecorderForTesting(reads) {
            CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
                for model in models + models {
                    #expect(Array(resolver.normalize(model).utf8) ==
                        Array(CostUsagePricing.normalizeClaudeModel(model).utf8))
                }
            }
        }
        #expect(resolver.normalize(models[0]) == "anthropic.example")
        #expect(resolver.normalize(models[1]) == "example")
        #expect(reads.snapshot() == 0)
        #expect(work.snapshot().normalizationCacheMisses == 4)
        #expect(work.snapshot().catalogModelLookups == 0)
    }

    @Test
    func `historical tariffs bypass catalog lookup and ambiguous misses are memoized`() throws {
        let resolver = try CostUsagePricing.ClaudeResolver(catalog: Self.catalog())
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
            let cutoff = Date(timeIntervalSince1970: 1_773_360_000)
            for date in [cutoff.addingTimeInterval(-1), cutoff, cutoff.addingTimeInterval(1)] {
                #expect(resolver.costUSD(
                    model: "claude-sonnet-4-6",
                    inputTokens: 210_000,
                    cacheReadInputTokens: 10,
                    cacheCreationInputTokens: 20,
                    outputTokens: 30,
                    pricingDate: date) != nil)
            }
            #expect(work.snapshot().catalogModelLookups == 0)
            for _ in 0..<3 {
                #expect(Self.cost(resolver, model: "collision") == nil)
                #expect(Self.cost(resolver, model: "claude-test-zero") == 0)
            }
        }
        #expect(work.snapshot().catalogModelLookups == 2)
        #expect(work.snapshot().catalogModelHits == 1)
        #expect(work.snapshot().catalogModelMisses == 1)
    }

    @Test
    func `catalog snapshot freezes unseen models and next invocation retries positive and negative results`() throws {
        let env = try CostUsageTestEnvironment()
        let other = try CostUsageTestEnvironment()
        defer { env.cleanup(); other.cleanup() }
        let now = Date(timeIntervalSince1970: 1_780_000_000)
        let first = try Self.simpleCatalog(["claude-test-a": 10, "claude-test-b": 20])
        let replacement = try Self.simpleCatalog(["claude-test-a": 30, "claude-test-b": 40, "claude-test-c": 50])
        #expect(ModelsDevCache.save(catalog: first, fetchedAt: now, cacheRoot: env.cacheRoot))
        #expect(try ModelsDevCache.save(
            catalog: Self.simpleCatalog(["claude-test-a": 90]), fetchedAt: now, cacheRoot: other.cacheRoot))
        let resolver = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: env.cacheRoot)
        #expect(Self.cost(resolver, model: "claude-test-a") == Self.scalar(first, model: "claude-test-a"))
        #expect(Self.cost(resolver, model: "claude-test-c") == nil)
        #expect(ModelsDevCache.save(catalog: replacement, fetchedAt: now, cacheRoot: env.cacheRoot))
        #expect(Self.cost(resolver, model: "claude-test-b") == Self.scalar(first, model: "claude-test-b"))
        #expect(Self.cost(resolver, model: "claude-test-a") == Self.scalar(first, model: "claude-test-a"))
        #expect(Self.cost(resolver, model: "claude-test-c") == nil)

        let fresh = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: env.cacheRoot)
        for model in ["claude-test-a", "claude-test-b", "claude-test-c"] {
            #expect(Self.cost(fresh, model: model) == Self.scalar(replacement, model: model))
        }
        let independent = CostUsagePricing.ClaudeResolver(now: now, cacheRoot: other.cacheRoot)
        #expect(Self.cost(independent, model: "claude-test-a") != Self.cost(fresh, model: "claude-test-a"))
        #expect(Self.cost(independent, model: "claude-test-c") == nil)
    }

    @Test
    func `saturated memos keep resolving uncached positive and negative inputs`() throws {
        let catalog = try Self.catalog()
        let resolver = CostUsagePricing.ClaudeResolver(catalog: catalog)
        let work = CostUsageScanner.ClaudeScanWorkRecorder()
        CostUsageScanner.withClaudeScanWorkRecorderForTesting(work) {
            for index in 0..<CostUsagePricing.ClaudeResolver.memoEntryLimit {
                #expect(Self.cost(resolver, model: "claude-test-absent-\(index)") == nil)
            }
            for _ in 0..<2 {
                #expect(Self.cost(resolver, model: "claude-test-known") ==
                    Self.scalar(catalog, model: "claude-test-known"))
                #expect(Self.cost(resolver, model: "claude-test-overflow") == nil)
                #expect(Self.cost(resolver, model: "claude-test-absent-0") == nil)
            }
        }
        #expect(work.snapshot().normalizationCacheMisses == CostUsagePricing.ClaudeResolver.memoEntryLimit + 4)
        #expect(work.snapshot().catalogModelLookups == CostUsagePricing.ClaudeResolver.memoEntryLimit + 4)
        #expect(work.snapshot().catalogModelHits == 2)
        #expect(work.snapshot().catalogModelMisses == CostUsagePricing.ClaudeResolver.memoEntryLimit + 2)
    }

    static func cost(_ resolver: CostUsagePricing.ClaudeResolver, model: String) -> Double? {
        resolver.costUSD(
            model: model,
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0)
    }

    static func scalar(_ catalog: ModelsDevCatalog, model: String) -> Double? {
        CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: catalog)
    }

    static func simpleCatalog(_ rates: [String: Double]) throws -> ModelsDevCatalog {
        var models: [String: [String: Any]] = [:]
        for (model, rate) in rates {
            models[model] = ["id": model, "cost": ["input": rate, "output": 1]]
        }
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: JSONSerialization.data(withJSONObject: [
            "anthropic": ["id": "anthropic", "models": models],
        ]))
    }

    static func catalog() throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(#"""
        {
          "anthropic": {"models": {
            "claude-test-known": {"id":"claude-test-known", "cost": {
              "input":3,"output":15,"cache_read":0.3,"cache_write":3.75,
              "context_over_200k":{"input":6,"output":22.5,"cache_read":0.6,"cache_write":7.5}}},
            "claude-test-zero": {"id":"claude-test-zero", "cost":{"input":0,"output":0}},
            "claude-test-null": {"id":"claude-test-null", "cost":{"input":null,"output":1}},
            "claude-test-empty-context": {"id":"claude-test-empty-context", "cost": {
              "input":4,"output":8,"context_over_200k":{}}},
            "claude-test-partial-context": {"id":"claude-test-partial-context", "cost": {
              "input":4,"output":8,"context_over_200k":{"input":9}}},
            "alias-key": {"id":" claude-test-id-fallback ", "cost":{"input":7,"output":11}},
            "claude-sonnet-4-5-20250929": {"id":"claude-sonnet-4-5-20250929", "cost":{"input":41,"output":42}},
            "claude-sonnet-4-5": {"id":"claude-sonnet-4-5", "cost":{"input":2,"output":3}},
            "claude-sonnet-4-6": {"id":"claude-sonnet-4-6", "cost":{"input":99,"output":100}},
            "claude-opus-4-6": {"id":"claude-opus-4-6", "cost":{"input":99,"output":100}},
            "claude-test-caf\u00e9": {"id":"claude-test-caf\u00e9", "cost":{"input":2,"output":3}},
            "example": {"id":"example", "cost":{"input":2,"output":3}},
            "collision": {"id":"collision", "cost":{"input":1,"output":2}}
          }},
          "openai": {"models": {
            "gpt-fixture":{"id":"gpt-fixture","cost":{"input":3,"output":4}},
            "collision":{"id":"collision","cost":{"input":5,"output":6}}
          }},
          "google": {"models":{"gemini-fixture":{"id":"gemini-fixture","cost":{"input":7,"output":8}}}},
          "moonshot": {"models":{"kimi-fixture":{"id":"kimi-fixture","cost":{"input":9,"output":10}}}},
          "kimi-for-coding": {"models":{"k3":{"id":"k3","cost":{"input":11,"output":12}}}},
          "minimax": {"models":{"minimax-fixture":{"id":"minimax-fixture","cost":{"input":13,"output":14}}}},
          "deepseek": {"models":{"deepseek-fixture":{"id":"deepseek-fixture","cost":{"input":15,"output":16}}}},
          "opencode": {"models":{"fixture":{"id":"fixture","cost":{"input":17,"output":18}}}}
        }
        """#.utf8))
    }
}
