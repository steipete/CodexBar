import Foundation
import Testing
@testable import CodexBarCore

struct CodexLongContextThresholdTests {
    @Test(arguments: [false, true])
    func `Sol uses documented threshold with legacy and explicit catalog tiers`(explicitTier: Bool) throws {
        let catalog = try Self.catalog(model: "gpt-6.1-sol", explicitTier: explicitTier)
        for input in [200_000, 200_001, 210_000, 272_000, 272_001] {
            let cost = try #require(CostUsagePricing.codexCostUSD(
                model: "gpt-6.1-sol",
                inputTokens: input,
                cachedInputTokens: 200_000,
                outputTokens: 1000,
                modelsDevCatalog: catalog))
            let expected = input > 272_000
                ? Double(input - 200_000) * 4e-6 + 0.04 + 0.015
                : Double(input - 200_000) * 2e-6 + 0.02 + 0.01
            #expect(abs(cost - expected) < 1e-12)
        }
    }

    @Test(arguments: [
        "gpt-5.4",
        "gpt-5.4-pro",
        "gpt-5.5",
        "gpt-5.5-pro",
        "gpt-5.6",
        "gpt-5.6-sol",
        "gpt-5.6-terra",
        "gpt-5.6-luna",
        "gpt-daybreak-blue-latest",
        "gpt-6-astra",
        "gpt-6-sol",
        "gpt-6-luna",
        "gpt-6.1-sol",
    ])
    func `OpenAI legacy context lane uses published threshold`(model: String) throws {
        let catalog = try Self.catalog(model: model, explicitTier: false)
        #expect(catalog.pricing(providerID: "openai", modelID: model)?.pricing.thresholdTokens == 272_000)
    }

    @Test
    func `explicit context size wins and other providers keep legacy default`() throws {
        for provider in ["openai", "fixture-provider"] {
            let catalog = try Self.catalog(
                model: "gpt-6.1-sol",
                explicitTier: true,
                provider: provider,
                threshold: 300_000)
            let pricing = try #require(catalog.pricing(providerID: provider, modelID: "gpt-6.1-sol")?.pricing)
            #expect(pricing.thresholdTokens == 300_000)
            if provider == "openai" {
                #expect(CostUsagePricing.resolvedCodexPricing(
                    model: "gpt-6.1-sol",
                    modelsDevCatalog: catalog,
                    modelsDevCacheRoot: nil)?.thresholdTokens == 300_000)
            }
        }
        let catalog = try Self.catalog(model: "gpt-6.1-sol", explicitTier: false, provider: "fixture-provider")
        #expect(catalog.pricing(providerID: "fixture-provider", modelID: "gpt-6.1-sol")?.pricing
            .thresholdTokens == 200_000)
    }

    @Test
    func `catalog threshold changes invalidate cached pricing`() throws {
        let keys = try [200_000, 272_000].map { threshold in
            let catalog = try Self.catalog(model: "gpt-6.1-sol", explicitTier: true, threshold: threshold)
            return CostUsagePricingKey.codex(
                modelsDevArtifact: .init(
                    version: ModelsDevCache.artifactVersion,
                    fetchedAt: Date(timeIntervalSince1970: 0),
                    catalog: catalog),
                formulaVersion: 1,
                customPricingFingerprint: "fixture")
        }
        #expect(keys[0] != keys[1])
    }

    @Test
    func `persisted requests reprice after the catalog threshold is corrected`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 10, day: 1)
        let timestamp = env.isoString(for: day)
        _ = try env.writeCodexSessionFile(day: day, filename: "session.jsonl", contents: env.jsonl([
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-6.1-sol"]],
            ["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "token_count", "info": ["last_token_usage": [
                    "input_tokens": 210_000, "cached_input_tokens": 200_000, "output_tokens": 1000,
                ]],
            ]],
        ]))
        #expect(try ModelsDevCache.save(
            catalog: Self.catalog(model: "gpt-6.1-sol", explicitTier: true, threshold: 200_000),
            fetchedAt: day,
            cacheRoot: env.cacheRoot))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        let old = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day, options: options)
        #expect(abs((old.summary?.totalCostUSD ?? -1) - 0.095) < 1e-12)
        #expect(try ModelsDevCache.save(
            catalog: Self.catalog(model: "gpt-6.1-sol", explicitTier: true),
            fetchedAt: day,
            cacheRoot: env.cacheRoot))
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let reopened = CostUsageStoreAccess.read(
            cacheRoot: env.cacheRoot,
            home: env.codexStoreHome,
            calendar: range.calendar)
        let corrected = CostUsageScanner.buildCodexReportFromCache(
            cache: reopened, range: range, modelsDevCacheRoot: env.cacheRoot)
        #expect(abs((corrected.summary?.totalCostUSD ?? -1) - 0.050) < 1e-12)
        #expect(corrected.summary?.totalTokens == old.summary?.totalTokens)
    }

    private static func catalog(
        model: String,
        explicitTier: Bool,
        provider: String = "openai",
        threshold: Int = 272_000) throws -> ModelsDevCatalog
    {
        let tier = explicitTier ? """
        , "tiers": [{"input":4,"output":15,"cache_read":0.2,"cache_write":5,
        "tier":{"type":"context","size":\(threshold)}}]
        """ : ""
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"\(provider)":{"id":"\(provider)","models":{"\(model)":{"id":"\(model)",
        "cost":{"input":2,"output":10,"cache_read":0.1,"cache_write":2.5,
        "context_over_200k":{"input":4,"output":15,"cache_read":0.2,"cache_write":5}\(tier)}}}}}
        """.utf8))
    }
}
