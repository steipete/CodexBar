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

    @Test
    func `codex cache re-buckets unchanged files when the time zone changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let utc = try Self.calendar(timeZoneIdentifier: "UTC")
        let bangkok = try Self.calendar(timeZoneIdentifier: "Asia/Bangkok")
        let boundary = try Self.date("2026-07-22T18:00:00Z")
        let windowStart = try Self.date("2026-07-20T12:00:00Z")
        let windowEnd = try Self.date("2026-07-24T12:00:00Z")
        _ = try Self.writeCodexSession(
            env: env,
            day: boundary,
            partitionCalendar: utc,
            filename: "time-zone-change.jsonl",
            tokens: 10)

        let utcReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.codexOptions(env: env, calendar: utc))
        let utcCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(utcReport.data.map(\.date) == ["2026-07-22"])
        #expect(utcCache.timeZoneIdentifier == utc.timeZone.identifier)
        #expect(utcCache.files.values.compactMap(\.sessionId) == ["calendar-time-zone-change.jsonl"])

        let bangkokReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.codexOptions(env: env, calendar: bangkok))
        let bangkokCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(bangkokReport.data.map(\.date) == ["2026-07-23"])
        #expect(bangkokReport.data.first?.totalTokens == 10)
        #expect(bangkokCache.timeZoneIdentifier == "Asia/Bangkok")
    }

    @Test
    func `codex cache does not mix old and new zones after an append`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let utc = try Self.calendar(timeZoneIdentifier: "UTC")
        let bangkok = try Self.calendar(timeZoneIdentifier: "Asia/Bangkok")
        let boundary = try Self.date("2026-07-22T18:00:00Z")
        let windowStart = try Self.date("2026-07-20T12:00:00Z")
        let windowEnd = try Self.date("2026-07-24T12:00:00Z")
        let fileURL = try Self.writeCodexSession(
            env: env,
            day: boundary,
            partitionCalendar: utc,
            filename: "time-zone-append.jsonl",
            tokens: 10)

        let utcReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.codexOptions(env: env, calendar: utc))
        #expect(utcReport.data.map(\.date) == ["2026-07-22"])

        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        let appended = try env.jsonl([
            Self.codexTokenCount(
                timestamp: env.isoString(for: boundary.addingTimeInterval(2)),
                tokens: 30),
        ])
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        let bangkokReport = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.codexOptions(env: env, calendar: bangkok))
        #expect(bangkokReport.data.map(\.date) == ["2026-07-23"])
        #expect(bangkokReport.data.first?.totalTokens == 30)
    }

    @Test
    func `fetcher keeps daily project session and cached ranges in the injected zone`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let utc = try Self.calendar(timeZoneIdentifier: "UTC")
        let bangkok = try Self.calendar(timeZoneIdentifier: "Asia/Bangkok")
        let boundary = try Self.date("2026-07-22T18:00:00Z")
        _ = try Self.writeCodexSession(
            env: env,
            day: boundary,
            partitionCalendar: utc,
            filename: "fetcher-time-zone.jsonl",
            tokens: 10)

        try await Self.expectFetcherSnapshot(
            env: env,
            now: boundary,
            calendar: utc,
            expectedDay: "2026-07-22")
        try await Self.expectFetcherSnapshot(
            env: env,
            now: boundary,
            calendar: bangkok,
            expectedDay: "2026-07-23")
    }

    @Test
    func `claude and pi caches re-bucket unchanged files when the time zone changes`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let utc = try Self.calendar(timeZoneIdentifier: "UTC")
        let bangkok = try Self.calendar(timeZoneIdentifier: "Asia/Bangkok")
        let boundary = try Self.date("2026-07-22T18:00:00Z")
        let windowStart = try Self.date("2026-07-20T12:00:00Z")
        let windowEnd = try Self.date("2026-07-24T12:00:00Z")
        _ = try env.writeClaudeProjectFile(
            relativePath: "calendar/session.jsonl",
            contents: env.jsonl([
                [
                    "type": "assistant",
                    "timestamp": env.isoString(for: boundary),
                    "sessionId": "claude-calendar-session",
                    "requestId": "claude-calendar-request",
                    "message": [
                        "id": "claude-calendar-message",
                        "model": "claude-sonnet-4-20250514",
                        "usage": [
                            "input_tokens": 10,
                            "cache_creation_input_tokens": 0,
                            "cache_read_input_tokens": 0,
                            "output_tokens": 2,
                        ],
                    ],
                ],
            ]))
        _ = try env.writePiSessionFile(
            relativePath: "calendar/2026-07-22T18-00-00-000Z_session.jsonl",
            contents: env.jsonl([
                [
                    "type": "message",
                    "timestamp": env.isoString(for: boundary),
                    "message": [
                        "role": "assistant",
                        "provider": "openai-codex",
                        "model": "openai/gpt-5.4",
                        "timestamp": Int(boundary.timeIntervalSince1970 * 1000),
                        "usage": [
                            "input": 10,
                            "output": 2,
                            "cacheRead": 0,
                            "cacheWrite": 0,
                            "totalTokens": 12,
                        ],
                    ],
                ],
            ]))

        let utcClaude = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.claudeOptions(env: env, calendar: utc))
        let bangkokClaude = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.claudeOptions(env: env, calendar: bangkok))
        #expect(utcClaude.data.map(\.date) == ["2026-07-22"])
        #expect(bangkokClaude.data.map(\.date) == ["2026-07-23"])
        #expect(CostUsageCacheIO.load(
            provider: .claude,
            cacheRoot: env.cacheRoot).timeZoneIdentifier == "Asia/Bangkok")

        let utcPi = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.piOptions(env: env, calendar: utc))
        let bangkokPi = PiSessionCostScanner.loadDailyReport(
            provider: .codex,
            since: windowStart,
            until: windowEnd,
            now: windowEnd,
            options: Self.piOptions(env: env, calendar: bangkok))
        #expect(utcPi.data.map(\.date) == ["2026-07-22"])
        #expect(bangkokPi.data.map(\.date) == ["2026-07-23"])
        #expect(PiSessionCostCacheIO.load(cacheRoot: env.cacheRoot).timeZoneIdentifier == "Asia/Bangkok")
    }

    private static func expectFetcherSnapshot(
        env: CostUsageTestEnvironment,
        now: Date,
        calendar: Calendar,
        expectedDay: String) async throws
    {
        let options = Self.codexOptions(env: env, calendar: calendar)
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: now,
            historyDays: 1,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(snapshot.daily.map(\.date) == [expectedDay])
        #expect(snapshot.projects.flatMap(\.daily).map(\.date) == [expectedDay])
        #expect(snapshot.sessions.map(\.sessionID) == ["calendar-fetcher-time-zone.jsonl"])
        #expect(snapshot.sessionTokens == 10)

        let cached = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: now,
            historyDays: 1,
            scannerOptions: options)
        #expect(cached?.daily.map(\.date) == [expectedDay])
        #expect(cached?.projects.flatMap(\.daily).map(\.date) == [expectedDay])
        #expect(cached?.sessions.map(\.sessionID) == ["calendar-fetcher-time-zone.jsonl"])
        #expect(cached?.sessionTokens == 10)
    }

    private static func codexOptions(
        env: CostUsageTestEnvironment,
        calendar: Calendar) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing-traces.sqlite"),
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func claudeOptions(
        env: CostUsageTestEnvironment,
        calendar: Calendar) -> CostUsageScanner.Options
    {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            calendar: calendar)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    private static func piOptions(
        env: CostUsageTestEnvironment,
        calendar: Calendar) -> PiSessionCostScanner.Options
    {
        PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            calendar: calendar,
            refreshMinIntervalSeconds: 0)
    }

    private static func calendar(timeZoneIdentifier: String) throws -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: timeZoneIdentifier))
        return calendar
    }

    private static func date(_ text: String) throws -> Date {
        try #require(ISO8601DateFormatter().date(from: text))
    }

    private static func codexTokenCount(
        timestamp: String,
        tokens: Int,
        model: String = "openai/gpt-5.4") -> [String: Any]
    {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": tokens,
                        "cached_input_tokens": 0,
                        "output_tokens": 0,
                    ],
                    "model": model,
                ],
            ],
        ]
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
                "type": "session_meta",
                "timestamp": env.isoString(for: day),
                "payload": [
                    "id": "calendar-\(filename)",
                    "cwd": env.root.appendingPathComponent("calendar-project", isDirectory: true).path,
                ],
            ],
            [
                "type": "turn_context",
                "timestamp": env.isoString(for: day),
                "payload": ["model": model],
            ],
            Self.codexTokenCount(
                timestamp: env.isoString(for: day.addingTimeInterval(1)),
                tokens: tokens,
                model: model),
        ]).write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
