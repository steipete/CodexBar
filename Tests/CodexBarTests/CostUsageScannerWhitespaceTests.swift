import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageScannerWhitespaceTests {
    @Test(arguments: [" ", "\t"])
    func `spaced events survive initial scans appends and cache reopening`(spacing: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let firstDay = try env.makeLocalNoon(year: 2026, month: 9, day: 6)
        let nextDay = try env.makeLocalNoon(year: 2026, month: 9, day: 7)
        func event(_ day: Date, input: Int, cached: Int, output: Int) -> String {
            let timestamp = env.isoString(for: day)
            return "{\"type\":\(spacing)\"event_msg\",\"timestamp\":\"\(timestamp)\","
                + "\"payload\":{\"type\":\(spacing)\"token_count\",\"info\":{"
                + "\"total_token_usage\":{\"input_tokens\":\(input),"
                + "\"cached_input_tokens\":\(cached),\"output_tokens\":\(output)}}}}\n"
        }
        let context = try env.jsonl([[
            "type": "turn_context",
            "timestamp": env.isoString(for: firstDay),
            "payload": ["model": "gpt-5.6-luna"],
        ]])
        let file = try env.writeCodexSessionFile(
            day: firstDay,
            filename: "spaced.jsonl",
            contents: context + "\n" + event(firstDay, input: 100, cached: 20, output: 10))
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
        let today = try #require(appended.data.first { $0.date == "2026-09-07" })
        #expect(today.totalTokens == 220)
        #expect(try abs(#require(today.costUSD) - 0.0000568) < 0.000_000_001)
        options.refreshMinIntervalSeconds = 3600
        let cached = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstDay,
            until: nextDay,
            now: nextDay.addingTimeInterval(1),
            options: options)
        #expect(cached.summary?.totalTokens == 330)
        #expect(cached.data == appended.data)
    }
}
