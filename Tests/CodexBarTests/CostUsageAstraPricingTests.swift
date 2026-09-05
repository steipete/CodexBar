import Foundation
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct CostUsageAstraPricingTests {
    @Test(arguments: ["gpt-6-astra", "openai/gpt-6-astra", "gpt-6-astra-2099-01-01"])
    func `Astra fallback prices input cache reads cache writes and output`(_ model: String) throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let cost = CostUsagePricing.codexCostUSD(
            model: model,
            inputTokens: 1000,
            cachedInputTokens: 300,
            outputTokens: 100,
            cacheWriteInputTokens: 200,
            modelsDevCacheRoot: environment.cacheRoot)
        let expected = (500.0 * 10e-6) + (300.0 * 1e-6) + (200.0 * 12.5e-6) + (100.0 * 50e-6)
        #expect(try abs(#require(cost) - expected) < 1e-12)
    }

    @Test(arguments: [272_000, 272_001])
    func `Astra switches the entire request at the long context boundary`(_ input: Int) throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let cost = CostUsagePricing.codexCostUSD(
            model: "gpt-6-astra",
            inputTokens: input,
            cachedInputTokens: 100_000,
            outputTokens: 1000,
            cacheWriteInputTokens: 100_000,
            modelsDevCacheRoot: environment.cacheRoot)
        let inputMultiplier = input > 272_000 ? 2.0 : 1.0
        let outputMultiplier = input > 272_000 ? 1.5 : 1.0
        let expected = (Double(input - 200_000) * 10e-6 + 100_000 * 1e-6 + 100_000 * 12.5e-6)
            * inputMultiplier + 1000 * 50e-6 * outputMultiplier
        #expect(try abs(#require(cost) - expected) < 1e-12)
        let fast = CostUsagePricing.codexPriorityCostUSD(
            model: "openai/gpt-6-astra",
            inputTokens: input,
            cachedInputTokens: 100_000,
            cacheWriteInputTokens: 100_000,
            outputTokens: 1000,
            modelsDevCacheRoot: environment.cacheRoot)
        #expect(try abs(#require(fast) - expected * 2) < 1e-12)
    }

    @Test
    func `persisted unknown Astra rows gain cost without rescanning session files`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 9, day: 4)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let row = CostUsageScanner.CodexUsageRow(
            day: range.sinceKey,
            model: "gpt-6-astra",
            turnID: nil,
            eventIndex: 0,
            input: 1000,
            cached: 900,
            output: 100)
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            size: 1,
            days: [range.sinceKey: ["gpt-6-astra": [1000, 900, 100]]],
            parsedBytes: 1,
            codexRows: [row],
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files[environment.codexSessionsRoot.appendingPathComponent("missing.jsonl").path] = usage
        cache.days = usage.days
        cache.scanSinceKey = range.sinceKey
        cache.scanUntilKey = range.untilKey
        cache.timeZoneIdentifier = range.calendar.timeZone.identifier
        _ = CostUsageStoreAccess.replace(cacheRoot: environment.cacheRoot, cache: cache, calendar: range.calendar)
        let restored = CostUsageStoreAccess.read(cacheRoot: environment.cacheRoot, calendar: range.calendar)
        let emptyCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("{}".utf8))
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: restored, range: range, modelsDevCatalog: emptyCatalog)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.0069) < 1e-12)
        #expect(report.data.first?.modelBreakdowns?.first?.modelName == "gpt-6-astra")
    }

    @Test
    func `native Astra session reaches CLI text and JSON with a cost`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 9, day: 4)
        let timestamp = environment.isoString(for: day)
        let entries: [[String: Any]] = [
            ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-6-astra"]],
            [
                "type": "event_msg",
                "timestamp": timestamp,
                "payload": [
                    "type": "token_count",
                    "info": ["last_token_usage": [
                        "input_tokens": 1000, "cached_input_tokens": 900, "output_tokens": 100,
                    ]],
                ],
            ],
        ]
        _ = try environment.writeCodexSessionFile(
            day: day, filename: "astra.jsonl", contents: environment.jsonl(entries))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            cacheRoot: environment.cacheRoot,
            forceRescan: true)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: day,
            forceRefresh: true,
            codexHomePath: environment.codexHomeRoot.path,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            retryUnknownPricing: false)
        let payload = CodexBarCLI.makeCostPayload(provider: .codex, snapshot: snapshot, error: nil)
        #expect(try abs(#require(payload.totals?.totalCostUSD) - 0.0069) < 1e-12)
        #expect(payload.daily.first?.modelBreakdowns?.first?.modelName == "gpt-6-astra")
        let text = CodexBarCLI.renderCostText(provider: .codex, snapshot: snapshot, groupBy: .none, useColor: false)
        #expect(text.contains("$0.01"))
        let json = try JSONEncoder().encode(payload)
        let object = try #require(JSONSerialization.jsonObject(with: json) as? [String: Any])
        let totals = try #require(object["totals"] as? [String: Any])
        #expect(try abs(#require(totals["totalCost"] as? Double) - 0.0069) < 1e-12)
    }

    @Test
    func `unpublished Astra aliases and other providers remain unpriced`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        for model in ["gpt-6", "other-provider/gpt-6-astra"] {
            #expect(CostUsagePricing.codexCostUSD(
                model: model,
                inputTokens: 1000,
                cachedInputTokens: 0,
                outputTokens: 100,
                modelsDevCacheRoot: environment.cacheRoot) == nil)
        }
    }
}
