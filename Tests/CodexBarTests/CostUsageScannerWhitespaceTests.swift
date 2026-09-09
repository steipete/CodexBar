import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerWhitespaceTests {
    @Test(arguments: [" ", "\t"], [(false, false), (true, false), (false, true), (true, true)])
    func `spaced events survive initial scans appends and cache reopening`(
        spacing: String,
        scenario: (Bool, Bool)) throws
    {
        let (historicalFirst, limited) = scenario
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let firstDay = try env.makeLocalNoon(year: 2026, month: 9, day: 6)
        let nextDay = try env.makeLocalNoon(year: 2026, month: 9, day: 8)
        func event(_ day: Date, input: Int, cached: Int, output: Int) -> String {
            let timestamp = env.isoString(for: day)
            return "{\"type\":\(spacing)\"event_msg\",\"timestamp\":\"\(timestamp)\","
                + "\"payload\":{\"type\":\(spacing)\"token_count\",\"info\":{"
                + "\"total_token_usage\":{\"input_tokens\":\(input),"
                + "\"cached_input_tokens\":\(cached),\"output_tokens\":\(output)}}}}\n"
        }
        let context = try env.jsonl([
            [
                "type": "session_meta",
                "timestamp": env.isoString(for: firstDay),
                "payload": ["id": "whitespace-fixture"],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: firstDay),
                "payload": ["model": "gpt-5.6-luna"],
            ],
        ])
        let compactFirst = event(firstDay, input: 10, cached: 2, output: 1)
            .replacingOccurrences(of: ":\(spacing)", with: ":")
        let prefix = context + "\n" + compactFirst + event(firstDay, input: 100, cached: 20, output: 10)
        let file = try env.writeCodexSessionFile(
            day: firstDay,
            filename: "spaced.jsonl",
            contents: prefix)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex, since: firstDay, until: firstDay, now: firstDay, options: options)
        #expect(first.summary?.totalTokens == 110)
        let handle = try FileHandle(forWritingTo: file)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(event(nextDay, input: 300, cached: 60, output: 30).utf8))
        try handle.close()
        let appended = CostUsageScanner.loadDailyReport(
            provider: .codex, since: firstDay, until: nextDay, now: nextDay, options: options)
        #expect(appended.summary?.totalTokens == 330)
        let today = try #require(appended.data.first { $0.date == "2026-09-08" })
        #expect(today.totalTokens == 220)
        #expect(try abs(#require(today.costUSD) - 0.0000568) < 0.000_000_001)
        // The older parser could retain the first compact event and omit the spaced next-day event.
        var legacy = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let path = try #require(legacy.files.keys.first)
        var legacyFile = try #require(legacy.files[path])
        legacyFile.codexEventWhitespaceParsed = nil
        legacyFile.codexRows = legacyFile.codexRows.map { Array($0.prefix(1)) }
        legacyFile.days = ["2026-09-06": ["gpt-5.6-luna": [10, 2, 1]]]
        legacy.days = legacyFile.days
        legacy.files[path] = legacyFile
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: legacy)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[path]?.codexEventWhitespaceParsed == nil)
        options.refreshMinIntervalSeconds = 3600
        if limited {
            options.maxCodexScanBytesPerRefresh = Int64(prefix.utf8.count)
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: historicalFirst ? firstDay : nextDay,
                until: historicalFirst ? firstDay : nextDay,
                now: nextDay.addingTimeInterval(1),
                options: options)
            let partial = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            #expect(partial.files[path]?.codexEventWhitespaceParsed == true)
            #expect(partial.files[path]?.codexScanComplete == false)
            options.maxCodexScanBytesPerRefresh = 512 * 1024 * 1024
        }
        let refreshTime = nextDay.addingTimeInterval(limited ? 3602 : 1)
        let narrow = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: historicalFirst ? firstDay : nextDay,
            until: historicalFirst ? firstDay : nextDay,
            now: refreshTime,
            options: options)
        #expect(narrow.summary?.totalTokens == (historicalFirst ? 110 : 220))
        let cached = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstDay,
            until: nextDay,
            now: refreshTime,
            options: options)
        #expect(cached.summary?.totalTokens == 330)
        #expect(cached.data == appended.data)
        #expect(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files[path]?.codexEventWhitespaceParsed == true)
    }
}
