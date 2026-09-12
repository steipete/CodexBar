import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerReserveTests {
    @Test
    func `reserve usage is priced in fresh and existing cached reports`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 7)
        let timestamp = env.isoString(for: day)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "reserve.jsonl",
            contents: env.jsonl([
                ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "reserve-fixture"]],
                ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "gpt-reserve"]],
                [
                    "type": "event_msg", "timestamp": timestamp,
                    "payload": [
                        "type": "token_count",
                        "info": [
                            "total_token_usage": [
                                "input_tokens": 100_000, "cached_input_tokens": 40000, "output_tokens": 10000,
                            ],
                        ],
                    ],
                ],
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let fresh = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day, options: options)
        #expect(fresh.summary?.totalTokens == 110_000)
        #expect(try abs(#require(fresh.summary?.totalCostUSD) - 0.0248) < 0.000_000_001)

        // Older scans can store the raw alias; it must still contribute after repricing.
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first)
        var file = try #require(cache.files[path])
        file.codexRows = [CostUsageScanner.CodexUsageRow(
            day: dayKey,
            model: "gpt-reserve",
            turnID: nil,
            eventIndex: 0,
            input: 100_000,
            cached: 40000,
            output: 10000)]
        file.codexCostNanos = nil
        file.codexStandardCostNanos = nil
        file.codexPriorityCostNanos = nil
        cache.files[path] = file
        cache.codexPricingKey = "builtin-before-reserve"
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        options.refreshMinIntervalSeconds = 3600
        let cached = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        #expect(cached.summary?.totalTokens == 110_000)
        #expect(try abs(#require(cached.summary?.totalCostUSD) - 0.0248) < 0.000_000_001)
        let retained = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[path])
        #expect(retained.parsedBytes == file.parsedBytes)
    }
}
