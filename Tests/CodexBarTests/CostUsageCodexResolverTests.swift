import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexResolverTests {
    @Test
    func `memoized pricing preserves scalar costs across dates thresholds routes and overlays`() throws {
        let catalog = try Self.catalog()
        let resolver = CostUsagePricing.CodexResolver(catalog: catalog)
        let models = [
            "gpt-5.4",
            "openai/gpt-5.4",
            "deepseek/gpt-5.4",
            "gpt-5.6",
            "gpt-5.6-sol",
            "gpt-6-astra",
            "unknown-model",
            "café",
            "cafe\u{301}",
        ]
        let cutoff = CostUsagePricing.codexGPT56PricingCutoff
        let dates: [Date?] = [nil, cutoff.addingTimeInterval(-0.001), cutoff, cutoff.addingTimeInterval(1)]
        let overlays = [CostUsageCustomPricing.empty, CostUsageCustomPricing.parse(Data("""
        { "gpt-5.4": { "input": 0, "output": 0 }, "unknown-model": { "input": 1 } }
        """.utf8))]
        for overlay in overlays {
            for model in models {
                for date in dates {
                    for input in [-1, 0, 100, 272_000, 272_001, 1_000_001] {
                        func costs(_ context: CostUsagePricing.CodexResolver?) -> [Double?] {
                            [
                                CostUsagePricing.codexCostUSD(
                                    model: model,
                                    inputTokens: input,
                                    cachedInputTokens: 120,
                                    outputTokens: 30,
                                    cacheWriteInputTokens: 50,
                                    pricingDate: date,
                                    modelsDevCatalog: catalog,
                                    customPricing: overlay,
                                    pricingResolver: context),
                                CostUsagePricing.codexCostUSD(
                                    aggregate: true,
                                    model: model,
                                    inputTokens: input,
                                    cachedInputTokens: 120,
                                    outputTokens: 30,
                                    cacheWriteInputTokens: 50,
                                    pricingDate: date,
                                    modelsDevCatalog: catalog,
                                    customPricing: overlay,
                                    pricingResolver: context),
                                CostUsagePricing.codexPriorityCostUSD(
                                    model: model,
                                    inputTokens: input,
                                    cachedInputTokens: 120,
                                    cacheWriteInputTokens: 50,
                                    outputTokens: 30,
                                    pricingDate: date,
                                    modelsDevCatalog: catalog,
                                    customPricing: overlay,
                                    pricingResolver: context),
                            ]
                        }
                        #expect(costs(resolver) == costs(nil))
                    }
                }
            }
        }
    }

    @Test
    func `positive negative and byte exact keys are cached within one catalog snapshot`() throws {
        let catalog = try Self.catalog()
        let resolver = CostUsagePricing.CodexResolver(catalog: catalog)
        let work = CostUsagePricing.CodexPricingWorkRecorder()
        CostUsagePricing.$codexPricingWorkRecorder.withValue(work) {
            for _ in 0..<3 {
                #expect(resolver.lookup("gpt-5.4") != nil)
                #expect(resolver.lookup("missing-model") == nil)
                #expect(resolver.lookup("café") == nil)
                #expect(resolver.lookup("cafe\u{301}") == nil)
            }
        }
        #expect(work.catalogLookups == 4)
        let empty = CostUsagePricing.CodexResolver(catalog: ModelsDevCatalog(providers: [:]))
        #expect(empty.lookup("gpt-5.4") == nil)
        #expect(resolver.lookup("gpt-5.4") != nil)
    }

    @Test
    func `saturated memos preserve hits and correctly resolve uncached models`() throws {
        let resolver = try CostUsagePricing.CodexResolver(catalog: Self.catalog())
        let work = CostUsagePricing.CodexPricingWorkRecorder()
        CostUsagePricing.$codexPricingWorkRecorder.withValue(work) {
            for index in 0..<CostUsagePricing.CodexResolver.memoEntryLimit {
                let model = "missing-\(index)"
                #expect(resolver.lookup(model) == nil)
                #expect(resolver.normalize(model) == CostUsagePricing.normalizeCodexModel(model))
            }
            for _ in 0..<2 {
                #expect(resolver.lookup("missing-0") == nil)
                #expect(resolver.lookup("gpt-5.4") != nil)
                #expect(resolver.lookup("overflow-model") == nil)
                #expect(resolver.normalize("openai/gpt-5.4") ==
                    CostUsagePricing.normalizeCodexModel("openai/gpt-5.4"))
            }
        }
        #expect(work.catalogLookups == CostUsagePricing.CodexResolver.memoEntryLimit + 4)
    }

    @Test
    func `oversized model keys bypass both memos without changing resolution`() throws {
        let resolver = try CostUsagePricing.CodexResolver(catalog: Self.catalog())
        let limit = CostUsagePricing.CodexResolver.memoKeyByteLimit
        let model = "gpt-5.4"
        let oversizedKnown = String(repeating: " ", count: limit + 1 - model.utf8.count) + model
        let oversizedUnicode = String(repeating: "é", count: limit / 2 + 1)
        #expect(oversizedUnicode.count < limit)
        #expect(oversizedUnicode.utf8.count > limit)
        let work = CostUsagePricing.CodexPricingWorkRecorder()
        CostUsagePricing.$codexPricingWorkRecorder.withValue(work) {
            for _ in 0..<2 {
                for key in [oversizedKnown, oversizedUnicode] {
                    #expect(Array(resolver.normalize(key).utf8) ==
                        Array(CostUsagePricing.normalizeCodexModel(key).utf8))
                }
                #expect(resolver.lookup(oversizedKnown) != nil)
                #expect(resolver.lookup(oversizedUnicode) == nil)
            }
            #expect(work.catalogLookups == 4)
            #expect(resolver.memoizedKeyByteCountForTesting == 0)

            let boundary = String(repeating: " ", count: limit - model.utf8.count) + model
            for _ in 0..<2 {
                #expect(resolver.normalize(boundary) == model)
                #expect(resolver.lookup(boundary) != nil)
            }
            #expect(work.catalogLookups == 5)
            #expect(resolver.memoizedKeyByteCountForTesting == 2 * limit)
        }
    }

    private static func catalog() throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": { "id": "openai", "models": {
            "gpt-5.4": { "id": "gpt-5.4", "cost": { "input": 3, "output": 9, "cache_read": 0 } }
          } },
          "deepseek": { "id": "deepseek", "models": {
            "gpt-5.4": { "id": "gpt-5.4", "cost": { "input": 1, "output": 2 } }
          } }
        }
        """.utf8))
    }
}
