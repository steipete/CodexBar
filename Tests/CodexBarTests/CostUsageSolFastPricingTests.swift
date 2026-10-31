import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageSolFastPricingTests {
    @Test(
        arguments: ["gpt-6.1-sol", "openai/gpt-6.1-sol", "gpt-6.1-sol-2099-01-01"],
        [1000, 272_000, 272_001])
    func `Sol Fast doubles the applicable rates including long context`(_ model: String, _ input: Int) throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let cost = CostUsagePricing.codexPriorityCostUSD(
            model: model,
            inputTokens: input,
            cachedInputTokens: 300,
            cacheWriteInputTokens: 200,
            outputTokens: 100,
            modelsDevCacheRoot: environment.cacheRoot)
        let inputMultiplier = input > 272_000 ? 2.0 : 1.0
        let outputMultiplier = input > 272_000 ? 1.5 : 1.0
        let standard = (Double(input - 500) * 2e-6 + 300 * 1e-7 + 200 * 2.5e-6)
            * inputMultiplier + 100 * 1e-5 * outputMultiplier
        #expect(try abs(#require(cost) - standard * 2) < 1e-12)
    }

    @Test
    func `persisted Sol priority rows gain Fast pricing without rescanning`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 10, day: 1)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let rows = ["standard", "priority"].enumerated().map { index, mode in
            CostUsageScanner.CodexUsageRow(
                day: range.sinceKey,
                model: "gpt-6.1-sol",
                turnID: nil,
                eventIndex: index,
                input: 300_000,
                cached: 280_000,
                output: 1000,
                pricingModel: "gpt-6.1-sol",
                pricingMode: mode)
        }
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            size: 1,
            days: [range.sinceKey: ["gpt-6.1-sol": [600_000, 560_000, 2000]]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files[environment.codexSessionsRoot.appendingPathComponent("missing.jsonl").path] = usage
        cache.days = usage.days
        cache.scanSinceKey = range.sinceKey
        cache.scanUntilKey = range.untilKey
        cache.timeZoneIdentifier = range.calendar.timeZone.identifier
        _ = CostUsageStoreAccess.replace(
            cacheRoot: environment.cacheRoot,
            home: environment.codexStoreHome,
            cache: cache,
            calendar: range.calendar)
        let restored = CostUsageStoreAccess.read(
            cacheRoot: environment.cacheRoot,
            home: environment.codexStoreHome,
            calendar: range.calendar)
        let emptyCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("{}".utf8))
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: restored, range: range, modelsDevCatalog: emptyCatalog)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.453) < 1e-12)
    }

    @Test
    func `native Sol sessions preserve mixed Standard and Fast long context costs`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 10, day: 1)
        let timestamp = environment.isoString(for: day)
        var records: [[String: Any]] = [
            ["type": "session_meta", "timestamp": timestamp, "payload": ["id": "synthetic-sol-fast"]],
        ]
        for tier in ["priority", "default"] {
            records.append(["type": "event_msg", "timestamp": timestamp, "payload": [
                "type": "thread_settings_applied", "thread_settings": ["service_tier": tier],
            ]])
            for input in [1000, 300_000] {
                let turn = "\(tier)-\(input)"
                records.append(["type": "event_msg", "timestamp": timestamp, "payload": [
                    "type": "task_started", "turn_id": turn,
                ]])
                records.append(["type": "turn_context", "timestamp": timestamp, "payload": [
                    "model": "gpt-6.1-sol", "turn_id": turn,
                ]])
                records.append(["type": "event_msg", "timestamp": timestamp, "payload": [
                    "type": "token_count", "turn_id": turn, "info": ["last_token_usage": [
                        "input_tokens": input, "cached_input_tokens": input == 1000 ? 800 : 280_000,
                        "output_tokens": input == 1000 ? 100 : 1000,
                    ]],
                ]])
            }
        }
        _ = try environment.writeCodexSessionFile(
            day: day, filename: "sol-fast.jsonl", contents: environment.jsonl(records))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            cacheRoot: environment.cacheRoot,
            codexTraceDatabaseURL: environment.root.appendingPathComponent("missing-traces.sqlite"),
            forceRescan: true)
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day, options: options)
        #expect(report.summary?.totalTokens == 604_200)
        #expect(try abs(#require(report.summary?.totalCostUSD) - 0.45744) < 1e-12)
    }
}
