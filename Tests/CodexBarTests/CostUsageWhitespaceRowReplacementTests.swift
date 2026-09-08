import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageWhitespaceRowReplacementTests {
    @Test(arguments: [false, true])
    func `legacy rows are replaced during complete and interrupted migration`(limited: Bool) async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 9, day: 7)
        let model = "gpt-5.6-luna"
        func header(_ id: String) throws -> String {
            try env.jsonl([
                ["type": "session_meta", "timestamp": env.isoString(for: day), "payload": ["id": id]],
                ["type": "turn_context", "timestamp": env.isoString(for: day), "payload": ["model": model]],
            ]) + "\n"
        }
        func event(_ input: Int, second: Double, spaced: Bool = false) throws -> String {
            let line = try env.jsonl([[
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(second)),
                "payload": [
                    "type": "token_count",
                    "info": ["total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ]],
                ],
            ]])
            return (spaced ? line
                .replacingOccurrences(of: "\"type\":\"event_msg\"", with: "\"type\": \"event_msg\"") : line)
                + "\n"
        }
        let prefix = try header("reordered") + event(100, second: 1, spaced: true)
        _ = try env.writeCodexSessionFile(
            day: day, filename: "a.jsonl", contents: prefix + event(200, second: 2))
        _ = try env.writeCodexSessionFile(
            day: day, filename: "b.jsonl", contents: header("untouched") + event(50, second: 1))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.preferNewestCodexSessionsFirst = false
        let clean = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day, options: options)
        #expect(clean.summary?.totalTokens == 250)

        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let firstPath = try #require(legacy.files.keys.first { $0.hasSuffix("/a.jsonl") })
        let otherPath = try #require(legacy.files.keys.first { $0.hasSuffix("/b.jsonl") })
        var first = try #require(legacy.files[firstPath])
        // The old parser missed the first event and assigned the entire cumulative count to the second.
        first.codexRows = [CostUsageScanner.CodexUsageRow(
            day: "2026-09-07",
            model: model,
            rawModel: model,
            turnID: nil,
            eventIndex: 0,
            timestampUnixMs: Int64(day.addingTimeInterval(2).timeIntervalSince1970 * 1000),
            input: 200,
            cached: 0,
            output: 0)]
        first.codexEventWhitespaceParsed = nil
        legacy.files[firstPath] = first
        legacy.files[otherPath]?.codexEventWhitespaceParsed = nil
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
        if limited { options.maxCodexScanBytesPerRefresh = Int64(prefix.utf8.count) }
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(3), options: options)
        if limited {
            let partial = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let started = try #require(partial.files[firstPath])
            #expect(started.codexScanComplete == false)
            #expect(started.codexEventWhitespaceParsed == true)
            #expect(started.codexRows?.contains { $0.input == 200 } == false)
            #expect(partial.files[otherPath]?.codexRows?.map(\.input) == [50])
        }
        options.maxCodexScanBytesPerRefresh = 512 * 1024 * 1024
        let final = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(4), options: options)
        #expect(final.data == clean.data)
        let reopenedStore = CostUsageStore(cacheRoot: env.cacheRoot)
        let reopened = reopenedStore.syncLoadCodexCache(calendar: .current)
        #expect(reopened.files[firstPath]?.codexRows?.map(\.input) == [100, 100])
        #expect(reopened.files[otherPath]?.codexRows?.map(\.input) == [50])
        let persisted = await reopenedStore.readSnapshot()
        #expect(persisted.dayAggregates.reduce(0) { $0 + $1.requestCount } == 3)
    }
}
