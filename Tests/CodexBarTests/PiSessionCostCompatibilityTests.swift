import Foundation
import Testing
@testable import CodexBarCore

private final class PiSessionParseCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }
}

struct PiSessionCostCompatibilityTests {
    @Test(arguments: [false, true], ["c6c46a376ba16304", "55f640e6bb0ccba4", "21f10143afe00c55", "f8577be489f4c13d"])
    func `parser changes reprice pi and omp while current caches preserve independent invalidation`(
        catalogPresent: Bool, predecessorHash: String) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 10)
        if catalogPresent {
            #expect(try ModelsDevCache.save(
                catalog: Self.modelsDevCatalog(inputCostPerMillion: 4),
                fetchedAt: day,
                cacheRoot: env.cacheRoot))
        }
        let contents = try env.jsonl([[
            "type": "message", "timestamp": env.isoString(for: day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "gpt-5.6-sol",
                "usage": ["input": 100, "output": 0, "totalTokens": 100],
            ],
        ]])
        _ = try env.writePiSessionFile(relativePath: "2026-07-10T10-00-00-000Z_pi.jsonl", contents: contents)
        let ompRoot = env.root.appendingPathComponent("omp")
        try FileManager.default.createDirectory(at: ompRoot, withIntermediateDirectories: true)
        try contents.write(
            to: ompRoot.appendingPathComponent("2026-07-10T10-00-00-000Z_omp.jsonl"),
            atomically: true,
            encoding: .utf8)
        var options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: ompRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        let original = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        var predecessor = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let currentKey = predecessor.pricingKey
        predecessor.pricingKey = CostUsagePricingKey.codex(
            modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
            formulaVersion: 2,
            parserHash: predecessorHash,
            modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs)),
            customPricingFingerprint: CostUsageCustomPricing.empty.fingerprint)
        PiSessionCostCacheIO.save(cache: predecessor, cacheRoot: env.cacheRoot)
        let cached = PiSessionCostScanner.loadCachedDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            cacheRoot: env.cacheRoot)
        #expect(cached == nil)
        let counter = PiSessionParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            let repriced = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options,
                checkCancellation: nil)
            #expect(repriced.data == original.data)
            #expect(counter.value == 2)
            #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).lastScanUnixMs > predecessor.lastScanUnixMs)
            options.refreshMinIntervalSeconds = 0
            let refreshed = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options,
                checkCancellation: nil)
            #expect(refreshed.data == original.data)
            #expect(counter.value == 2)
            let adopted = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
            #expect(adopted.pricingKey == currentKey)
            #expect(adopted.files.mapValues(\.parsedBytes) == predecessor.files.mapValues(\.parsedBytes))
            #expect(adopted.files.mapValues(\.entryUsages) == predecessor.files.mapValues(\.entryUsages))
            #expect(adopted.daysByProvider == predecessor.daysByProvider)
            #expect(adopted.files.mapValues(\.contributions) == predecessor.files.mapValues(\.contributions))
            for (formula, fingerprint) in [(1, "none"), (2, "changed-custom-rates")] {
                var changedPricing = adopted
                changedPricing.pricingKey = CostUsagePricingKey.codex(
                    modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
                    formulaVersion: formula,
                    parserHash: CodexParserHash.value,
                    modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                        Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs)),
                    customPricingFingerprint: fingerprint)
                PiSessionCostCacheIO.save(cache: changedPricing, cacheRoot: env.cacheRoot)
                #expect(PiSessionCostScanner.loadCachedDailyReport(
                    provider: .codex, since: day, until: day, now: day, cacheRoot: env.cacheRoot) == nil)
                let parsesBefore = counter.value
                _ = try PiSessionCostScanner.loadDailyReportCancellable(
                    provider: .codex,
                    since: day,
                    until: day,
                    now: day.addingTimeInterval(2),
                    options: options,
                    checkCancellation: nil)
                #expect(counter.value == parsesBefore + 2)
            }
            var unrelated = adopted
            unrelated.pricingKey = CostUsagePricingKey.codex(
                modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
                formulaVersion: 2,
                parserHash: "unreviewed-parser-transition",
                modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                    Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs)),
                customPricingFingerprint: CostUsageCustomPricing.empty.fingerprint)
            PiSessionCostCacheIO.save(cache: unrelated, cacheRoot: env.cacheRoot)
            #expect(PiSessionCostScanner.loadCachedDailyReport(
                provider: .codex, since: day, until: day, now: day, cacheRoot: env.cacheRoot) == nil)
            let parsesBeforeUnrelated = counter.value
            _ = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options,
                checkCancellation: nil)
            #expect(counter.value == parsesBeforeUnrelated + 2)
            // Change only catalog rates so this cannot pass merely because a parser key is stale.
            PiSessionCostCacheIO.save(cache: adopted, cacheRoot: env.cacheRoot)
            #expect(try ModelsDevCache.save(
                catalog: Self.modelsDevCatalog(inputCostPerMillion: 8),
                fetchedAt: day,
                cacheRoot: env.cacheRoot))
            #expect(PiSessionCostScanner.loadCachedDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                cacheRoot: env.cacheRoot) == nil)
            let parsesBeforeCatalogChange = counter.value
            _ = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(3),
                options: options,
                checkCancellation: nil)
            #expect(counter.value == parsesBeforeCatalogChange + 2)
            #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).pricingKey != currentKey)
        }
    }

    @Test
    func `predecessor Claude alias cache is rejected and repriced inside refresh interval`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 28)
        _ = try env.writePiSessionFile(
            relativePath: "2026-08-28T12-00-00-000Z_alias.jsonl",
            contents: env.jsonl([[
                "type": "message", "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant", "provider": "anthropic", "model": "k3[1m]",
                    "usage": ["input": 100, "output": 10, "totalTokens": 110],
                ],
            ]]))
        let options = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            ompSessionsRoot: env.root.appendingPathComponent("empty-omp"),
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 3600)
        #expect(try ModelsDevCache.save(
            catalog: Self.modelsDevCatalog(inputCostPerMillion: 4), fetchedAt: day, cacheRoot: env.cacheRoot))
        let unknown = PiSessionCostScanner.loadDailyReport(
            provider: .claude, since: day, until: day, now: day, options: options)
        #expect(try #require(unknown.data.first?.modelBreakdowns?.first).costUSD == nil)
        var predecessor = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"kimi-for-coding":{"models":{"k3":{"id":"k3","cost":{"input":2,"output":8}}}}}
        """.utf8))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: day, cacheRoot: env.cacheRoot))
        // Reproduce the old parser's unknown row under the same catalog; only its parser fingerprint is old.
        predecessor.pricingKey = CostUsagePricingKey.codex(
            modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
            formulaVersion: 2,
            parserHash: "f8577be489f4c13d",
            modelsDevProviderIDs: CostUsagePricing.codexModelsDevProviderIDs.union(
                Set(CostUsagePricing.claudeFirstPartyModelsDevProviderIDs)),
            customPricingFingerprint: CostUsageCustomPricing.empty.fingerprint)
        PiSessionCostCacheIO.save(cache: predecessor, cacheRoot: env.cacheRoot)
        #expect(PiSessionCostScanner.loadCachedDailyReport(
            provider: .claude, since: day, until: day, now: day, cacheRoot: env.cacheRoot) == nil)
        let counter = PiSessionParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        let report = PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            PiSessionCostScanner.loadDailyReport(
                provider: .claude, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        }
        let row = try #require(report.data.first?.modelBreakdowns?.first)
        #expect(row.modelName == "k3[1m]")
        #expect(row.totalTokens == 110)
        #expect(try abs(#require(row.costUSD) - 0.00028) < 1e-12)
        #expect(counter.value == 1)
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).pricingKey != predecessor.pricingKey)
    }

    private static func modelsDevCatalog(inputCostPerMillion: Double) throws -> ModelsDevCatalog {
        let json = """
        {"openai":{"id":"openai","models":{"gpt-5.6-sol":{
          "id":"gpt-5.6-sol",
          "cost":{"input":\(inputCostPerMillion),"output":30,"cache_read":0.5,"cache_write":6.25}
        }}}}
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }
}
