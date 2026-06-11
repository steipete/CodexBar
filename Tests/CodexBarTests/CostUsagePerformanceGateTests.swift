import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

/// Regression gates for the two cost-usage scan-storm classes that have shipped before:
/// re-parsing an unchanged session corpus on every refresh (#1387, #1392) and re-running
/// the full trace-database scan on every refresh (#1392, the pre-memo priority-turns path).
/// The gates assert cold/warm work ratios rather than absolute durations, so they hold
/// across runner speeds; the margins are far below the expected ratios to stay
/// deterministic under CI contention.
@Suite(.serialized)
struct CostUsagePerformanceGateTests {
    @Test
    func `warm codex refresh over an unchanged session corpus must not re-parse it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 80, turnsPerFile: 800)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let coldStart = Date()
        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let coldDuration = Date().timeIntervalSince(coldStart)

        let warmStart = Date()
        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let warmDuration = Date().timeIntervalSince(warmStart)

        print(String(
            format: "PERF-GATE codex-session-corpus: cold=%.0fms warm=%.0fms ratio=%.0fx",
            coldDuration * 1000,
            warmDuration * 1000,
            coldDuration / max(warmDuration, 0.000_001)))
        #expect(cold.data.count == 1)
        #expect(warm.data.first?.totalTokens == cold.data.first?.totalTokens)
        // Cold parse of this corpus takes hundreds of milliseconds; a warm refresh that
        // reuses the per-file cache takes a few. A failure here means unchanged files are
        // being re-parsed on refresh — the #1387 release-day storm shape.
        #expect(
            warmDuration * 5 < coldDuration,
            "warm refresh (\(warmDuration)s) must be at least 5x faster than cold parse (\(coldDuration)s)")
    }

    @Test
    func `priority turns refresh must scan only appended trace rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)

        let epoch: Int64 = 1_760_000_000
        var rows: [(epochSeconds: Int64, body: String)] = (0..<200_000).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        rows.append((
            epochSeconds: epoch,
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        let fullStart = Date()
        let full = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let fullDuration = Date().timeIntervalSince(fullStart)
        #expect(full.keys.sorted() == ["turn-a"])
        let scanned = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)])

        let refreshStart = Date()
        let refreshed = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        let refreshDuration = Date().timeIntervalSince(refreshStart)

        print(String(
            format: "PERF-GATE priority-turns: full=%.0fms incremental=%.0fms ratio=%.0fx",
            fullDuration * 1000,
            refreshDuration * 1000,
            fullDuration / max(refreshDuration, 0.000_001)))
        #expect(refreshed.keys.sorted() == ["turn-a", "turn-b"])
        let advanced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(advanced.lastRowID == scanned.lastRowID + 1)
        // The refresh resumes from the rowid cursor: one appended row, not 200k. A failure
        // here means refreshes regressed to full-table scans — the pre-memo per-tick cost
        // that grew with logs_2.sqlite.
        #expect(
            refreshDuration * 5 < fullDuration,
            "incremental refresh (\(refreshDuration)s) must be at least 5x faster than full scan (\(fullDuration)s)")
    }

    private static func writeSyntheticCodexCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        files: Int,
        turnsPerFile: Int) throws
    {
        let model = "openai/gpt-5.2-codex"
        let baseISO = env.isoString(for: day)
        for fileIndex in 0..<files {
            var lines: [String] = []
            lines.reserveCapacity(turnsPerFile + 2)
            lines.append(
                #"{"type":"session_meta","timestamp":"\#(baseISO)","payload":{"session_id":"perf-\#(fileIndex)"}}"#)
            lines.append(
                #"{"type":"turn_context","timestamp":"\#(baseISO)","payload":{"model":"\#(model)"}}"#)
            for turn in 1...turnsPerFile {
                lines.append(
                    #"{"type":"event_msg","timestamp":"\#(baseISO)","payload":{"type":"token_count","info":"#
                        + #"{"total_token_usage":{"input_tokens":\#(turn * 100),"cached_input_tokens":\#(turn * 20),"#
                        + #""output_tokens":\#(turn * 10)},"model":"\#(model)"}}}"#)
            }
            _ = try env.writeCodexSessionFile(
                day: day,
                filename: "session-\(fileIndex).jsonl",
                contents: lines.joined(separator: "\n") + "\n")
        }
    }
}
#endif
