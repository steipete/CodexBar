import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexAutoReviewTests {
    @Test
    func `custom rates win while uncovered free requests stay unknown`() throws {
        let model = "codex-auto-review"
        let day = "2026-10-06"
        let instant = Date(timeIntervalSince1970: 1_791_270_000)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        var usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [day: [model: [1000, 0, 10]]],
            parsedBytes: 1,
            codexRows: [.init(
                day: day,
                model: model,
                turnID: nil,
                eventIndex: 0,
                timestampUnixMs: 1_791_270_000_000,
                input: 1000,
                cached: 0,
                output: 10)],
            codexScanComplete: true)
        usage.codexSession = .init(hasCreatorAccount: true)
        var cache = CostUsageCache()
        cache.files = ["/review-fixture.jsonl": usage]
        cache.days = usage.days
        let catalog = ModelsDevCatalog(providers: ["openai": .init(
            id: "openai", name: "OpenAI", models: [model: .init(
                id: model, name: nil, cost: .init(input: 1, output: 2), limit: nil)])])
        func report(_ custom: CostUsageCustomPricing = .empty) -> CostUsageDailyReport {
            CostUsageScanner.buildCodexReportFromCache(
                cache: cache,
                range: .init(since: instant, until: instant, calendar: calendar),
                modelsDevCatalog: catalog,
                customPricing: custom)
        }
        let custom = CostUsageCustomPricing.parse(Data(#"{"openai/codex-auto-review":{"input":5,"output":10}}"#.utf8))
        #expect(report().data.first?.costUSD == 0)
        #expect(abs((report(custom).data.first?.costUSD ?? -1) - 0.0051) < 1e-12)

        // A missing request makes the day's token totals larger than the retained rows.
        cache.days[day]?[model]?[0] = 1500
        let uncovered = report()
        #expect(uncovered.data.first?.costUSD == nil)
        #expect(uncovered.data.first?.coverageCounts.unpriced == 1)
        #expect(uncovered.quotaSlices.count == 1)
        #expect(uncovered.quotaSlices.first?.costUSD == nil)
        #expect(uncovered.quotaSlices.first?.costIsComplete == false)
        #expect(abs((report(custom).data.first?.costUSD ?? -1) - 0.0076) < 1e-12)
    }

    @Test
    func `only ChatGPT auto review from the cutoff is free across cache refreshes`() throws {
        let cutoff = Date(timeIntervalSince1970: 1_791_270_000)
        for creator in [nil, " \n", "account-fixture"] as [String?] {
            for instant in [cutoff.addingTimeInterval(-1), cutoff] {
                let env = try CostUsageTestEnvironment()
                defer { env.cleanup() }
                let timestamp = env.isoString(for: instant)
                var metadata: [String: Any] = ["id": "review-fixture"]
                if let creator { metadata["creator_account_id"] = creator }
                let contents = try env.jsonl([
                    ["type": "session_meta", "timestamp": timestamp, "payload": metadata],
                    ["type": "turn_context", "timestamp": timestamp, "payload": ["model": "codex-auto-review"]],
                    ["type": "event_msg", "timestamp": timestamp, "payload": [
                        "type": "token_count",
                        "info": ["last_token_usage": [
                            "input_tokens": 1000, "cached_input_tokens": 200, "output_tokens": 100,
                        ]],
                    ]],
                ])
                _ = try env.writeCodexSessionFile(day: instant, filename: "review.jsonl", contents: contents)
                var options = CostUsageScanner.Options(
                    codexSessionsRoot: env.codexSessionsRoot,
                    claudeProjectsRoots: nil,
                    cacheRoot: env.cacheRoot,
                    codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
                options.refreshMinIntervalSeconds = 0
                let isFree = creator == "account-fixture" && instant >= cutoff
                for refresh in 0..<3 {
                    if refresh == 2 {
                        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
                        for path in legacy.files.keys {
                            legacy.files[path]?.codexSession = nil
                            legacy.files[path]?.codexParserRevision = CostUsageFileUsage.currentCodexParserRevision - 1
                        }
                        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
                    }
                    _ = CostUsageScanner.loadDailyReport(
                        provider: .codex, since: instant, until: instant, now: cutoff, options: options)
                    let report = CostUsageScanner.buildCodexReportFromCache(
                        cache: CostUsageStoreAccess.read(cacheRoot: env.cacheRoot),
                        range: .init(since: instant, until: instant),
                        modelsDevCatalog: ModelsDevCatalog(providers: [:]))
                    let entry = try #require(report.data.first)
                    #expect(entry.totalTokens == 1100)
                    #expect(entry.cacheReadTokens == 200)
                    #expect(entry.coverageCounts.unmetered == 0)
                    #expect(entry.coverageCounts.unpriced == (isFree ? 0 : 1))
                    #expect(entry.costUSD == (isFree ? 0 : nil))
                    #expect(entry.modelBreakdowns?.first?.costUSD == (isFree ? 0 : nil))
                    #expect(report.quotaSlices.first?.costIsComplete == isFree)
                    #expect(report.quotaSlices.first?.costUSD == (isFree ? 0 : nil))
                    #expect(report.hourly.first?.costIsComplete == isFree)
                }
            }
        }
    }
}
