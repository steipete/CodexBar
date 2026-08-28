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
    func `reviewed hash adoption preserves pi and omp parsing but still invalidates pricing`(
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
        #expect(cached?.data == original.data)
        let counter = PiSessionParseCounter()
        let observer: @Sendable () -> Void = { counter.increment() }
        try PiSessionCostScanner.$sessionParseObserverForTesting.withValue(observer) {
            _ = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options,
                checkCancellation: nil)
            #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).lastScanUnixMs == predecessor.lastScanUnixMs)
            options.refreshMinIntervalSeconds = 0
            let refreshed = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options,
                checkCancellation: nil)
            #expect(refreshed.data == original.data)
            #expect(counter.value == 0)
            let adopted = PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot)
            #expect(adopted.pricingKey == currentKey)
            #expect(adopted.files.mapValues(\.parsedBytes) == predecessor.files.mapValues(\.parsedBytes))
            #expect(adopted.files.mapValues(\.entryUsages) == predecessor.files.mapValues(\.entryUsages))
            #expect(adopted.daysByProvider == predecessor.daysByProvider)
            #expect(adopted.files.mapValues(\.contributions) == predecessor.files.mapValues(\.contributions))
            for (formula, fingerprint) in [(1, "none"), (2, "changed-custom-rates")] {
                var changedPricing = predecessor
                changedPricing.pricingKey = CostUsagePricingKey.codex(
                    modelsDevArtifact: ModelsDevCache.load(now: day, cacheRoot: env.cacheRoot).artifact,
                    formulaVersion: formula,
                    parserHash: predecessorHash,
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
            var unrelated = predecessor
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
            _ = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options,
                checkCancellation: nil)
            #expect(counter.value == 6)
            // Restore the old key before changing real rates: adoption must not mask a pricing change.
            PiSessionCostCacheIO.save(cache: predecessor, cacheRoot: env.cacheRoot)
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
            _ = try PiSessionCostScanner.loadDailyReportCancellable(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(3),
                options: options,
                checkCancellation: nil)
            #expect(counter.value == 8)
            #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).pricingKey != currentKey)
        }
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
