import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

/// Regression gates for the two cost-usage scan-storm classes that have shipped before:
/// re-parsing unchanged session files on every refresh (#1387, #1392) and re-running the
/// full trace-database scan on every refresh (#1392, the pre-memo priority-turns path).
@Suite(.serialized)
struct CostUsagePerformanceGateTests {
    @Test
    func `warm codex refresh over an unchanged session corpus must not re-parse it`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let fileURLs = try Self.writeSyntheticCodexCorpus(env: env, day: day, files: 2, turnsPerFile: 4)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let cold = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let changedFile = try #require(fileURLs.first)
        let originalAttributes = try FileManager.default.attributesOfItem(atPath: changedFile.path)
        let originalModificationDate = try #require(originalAttributes[.modificationDate] as? Date)
        let original = try String(contentsOf: changedFile, encoding: .utf8)
        let modified = original.replacingOccurrences(
            of: #""input_tokens":100,"#,
            with: #""input_tokens":900,"#)
        #expect(modified != original)
        #expect(modified.utf8.count == original.utf8.count)
        try modified.write(to: changedFile, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: originalModificationDate],
            ofItemAtPath: changedFile.path)

        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(cold.data.count == 1)
        #expect(warm.data.first?.totalTokens == cold.data.first?.totalTokens)
    }

    @Test
    func `priority turns refresh must scan only appended trace rows`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let dbURL = env.root.appendingPathComponent("logs_2.sqlite")
        try CostUsageScannerCodexPriorityTests.createTestLogsDatabase(at: dbURL)

        let epoch: Int64 = 1_760_000_000
        var rows: [(epochSeconds: Int64, body: String)] = (0..<50).map { index in
            (epochSeconds: epoch, body: "thread_id=t-\(index) turn.id=u-\(index) routine trace row")
        }
        rows.append((
            epochSeconds: epoch,
            body: "thread_id=thread-a turn.id=turn-a websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#))
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: rows)

        let full = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)
        #expect(full.keys.sorted() == ["turn-a"])
        let scanned = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))

        try Self.replaceTraceBody(
            dbURL: dbURL,
            rowID: 1,
            body: "thread_id=mutated turn.id=mutated-old websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)
        try CostUsageScannerCodexPriorityTests.insertTestLogs(dbURL: dbURL, rows: [(
            epochSeconds: epoch,
            body: "thread_id=thread-b turn.id=turn-b websocket request: "
                + #"{"type":"response.create","model":"gpt-5.5","service_tier":"priority"}"#)])

        let refreshed = CostUsageScanner.codexPriorityTurns(databaseURL: dbURL)

        #expect(refreshed.keys.sorted() == ["turn-a", "turn-b"])
        let advanced = try #require(CostUsageScanner._test_codexPriorityTurnsMemoState(forPath: dbURL.path))
        #expect(advanced.lastRowID == scanned.lastRowID + 1)
    }

    private static func writeSyntheticCodexCorpus(
        env: CostUsageTestEnvironment,
        day: Date,
        files: Int,
        turnsPerFile: Int) throws -> [URL]
    {
        let model = "openai/gpt-5.2-codex"
        let baseISO = env.isoString(for: day)
        var fileURLs: [URL] = []
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
            let fileURL = try env.writeCodexSessionFile(
                day: day,
                filename: "session-\(fileIndex).jsonl",
                contents: lines.joined(separator: "\n") + "\n")
            fileURLs.append(fileURL)
        }
        return fileURLs
    }

    private static func replaceTraceBody(dbURL: URL, rowID: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else {
            throw CocoaError(.fileReadUnknown)
        }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update logs set feedback_log_body = ? where id = ?", -1, &statement, nil)
            == SQLITE_OK
        else {
            throw CocoaError(.fileWriteUnknown)
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else {
            throw CocoaError(.fileWriteUnknown)
        }
    }
}
#endif
