import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCalendarTests {
    @Test
    func `day keys remain Gregorian under a Buddhist calendar`() throws {
        let bangkok = try #require(TimeZone(identifier: "Asia/Bangkok"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = bangkok
        let date = try #require(gregorian.date(from: DateComponents(
            timeZone: bangkok,
            year: 2026,
            month: 7,
            day: 23,
            hour: 12)))

        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok
        #expect(buddhist.component(.year, from: date) == 2569)

        let range = CostUsageScanner.CostUsageDayRange(since: date, until: date, calendar: buddhist)
        #expect(range.sinceKey == "2026-07-23")
        #expect(range.untilKey == "2026-07-23")
        #expect(range.scanSinceKey == "2026-07-22")
        #expect(range.scanUntilKey == "2026-07-24")
        #expect(CostUsageScanner.dayKeyFromTimestamp(
            "2026-07-23T05:00:00Z",
            calendar: buddhist) == "2026-07-23")
        #expect(CostUsageScanner.dayKeyFromParsedISO(
            "2026-07-23T05:00:00Z",
            calendar: buddhist) == "2026-07-23")

        let parsed = try #require(CostUsageScanner.parseDayKey("2026-07-23", calendar: buddhist))
        #expect(CostUsageScanner.CostUsageDayRange.dayKey(
            from: parsed,
            calendar: buddhist) == "2026-07-23")
    }

    @Test
    func `warm cache discovers a new Gregorian partition under a Buddhist calendar`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let bangkok = try #require(TimeZone(identifier: "Asia/Bangkok"))
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = bangkok
        let firstDay = try #require(gregorian.date(from: DateComponents(
            timeZone: bangkok,
            year: 2026,
            month: 7,
            day: 22,
            hour: 12)))
        let secondDay = try #require(gregorian.date(byAdding: .day, value: 1, to: firstDay))
        var buddhist = Calendar(identifier: .buddhist)
        buddhist.timeZone = bangkok
        #expect(buddhist.component(.year, from: secondDay) == 2569)

        let firstURL = try Self.writeCodexSession(
            env: env,
            day: firstDay,
            partitionCalendar: gregorian,
            filename: "first.jsonl",
            tokens: 10)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: buddhist)
        options.refreshMinIntervalSeconds = 0

        let firstReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: firstDay,
            until: firstDay,
            now: firstDay,
            options: options)
        #expect(firstReport.data.map(\.date) == ["2026-07-22"])
        #expect(firstReport.data.first?.totalTokens == 10)

        let secondURL = try Self.writeCodexSession(
            env: env,
            day: secondDay,
            partitionCalendar: gregorian,
            filename: "second.jsonl",
            tokens: 20)
        let secondReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: secondDay,
            until: secondDay,
            now: secondDay,
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        #expect(secondReport.data.map(\.date) == ["2026-07-23"])
        #expect(secondReport.data.first?.totalTokens == 20)
        #expect(cache.scanSinceKey == "2026-07-21")
        #expect(cache.scanUntilKey == "2026-07-24")
        #expect(Set(cache.files.keys.map { URL(fileURLWithPath: $0).standardizedFileURL.path }) == Set([
            firstURL.standardizedFileURL.path,
            secondURL.standardizedFileURL.path,
        ]))
    }

    private static func writeCodexSession(
        env: CostUsageTestEnvironment,
        day: Date,
        partitionCalendar: Calendar,
        filename: String,
        tokens: Int) throws -> URL
    {
        let components = partitionCalendar.dateComponents([.year, .month, .day], from: day)
        let directory = env.codexSessionsRoot
            .appendingPathComponent(String(format: "%04d", components.year ?? 1970), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.month ?? 1), isDirectory: true)
            .appendingPathComponent(String(format: "%02d", components.day ?? 1), isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        let model = "openai/gpt-5.4"
        let url = directory.appendingPathComponent(filename, isDirectory: false)
        try env.jsonl([
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": model],
            ],
            [
                "type": "event_msg",
                "timestamp": env.isoString(for: day.addingTimeInterval(1)),
                "payload": [
                    "type": "token_count",
                    "info": [
                        "last_token_usage": [
                            "input_tokens": tokens,
                            "cached_input_tokens": 0,
                            "output_tokens": 0,
                        ],
                        "model": model,
                    ],
                ],
            ],
        ]).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
