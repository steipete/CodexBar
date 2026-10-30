import CryptoKit
import Foundation
#if canImport(SQLite3)
import SQLite3
import Testing
@testable import CodexBarCore

extension CostUsageScannerCodexPriorityCursorTests {
    @discardableResult
    static func loadCodexDailyReport(
        env: CostUsageTestEnvironment,
        databaseURL: URL,
        since: Date? = nil,
        until: Date? = nil,
        now: Date,
        forceRescan: Bool = false,
        refreshMinIntervalSeconds: TimeInterval = 0) -> CostUsageDailyReport
    {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: databaseURL)
        options.refreshMinIntervalSeconds = refreshMinIntervalSeconds
        options.forceRescan = forceRescan
        return CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since ?? now,
            until: until ?? now,
            now: now,
            options: options)
    }

    static func priorityRequestBody(
        threadID: String,
        turnID: String,
        model: String = "gpt-5.5") -> String
    {
        "thread_id=\(threadID) turn.id=\(turnID) websocket request: "
            + #"{"type":"response.create","model":"\#(model)","service_tier":"priority"}"#
    }

    static func completedBody(turnID: String, model: String) -> String {
        "thread_id=thread turn.id=\(turnID) websocket event: "
            + #"{"type":"response.completed","response":{"model":"\#(model)"}}"#
    }

    static func writeCodexSession(
        env: CostUsageTestEnvironment,
        now: Date,
        turnID: String = "turn-a") throws
    {
        let iso = env.isoString(for: now)
        let lines = [
            #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"cursor-skip-\#(turnID)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"gpt-5.5"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"task_started","turn_id":"\#(turnID)"}}"#,
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                + #""model":"gpt-5.5"}}}"#,
        ]
        _ = try env.writeCodexSessionFile(
            day: now,
            filename: "cursor-skip-\(turnID).jsonl",
            contents: lines.joined(separator: "\n") + "\n")
    }

    static func cacheRequiringPricingMetadataMigration(_ cache: CostUsageCache) -> CostUsageCache {
        var migrationCache = cache
        migrationCache.codexResolvedPriorityTurns = nil
        for path in migrationCache.files.keys {
            guard var usage = migrationCache.files[path] else { continue }
            usage.codexCostCacheComplete = false
            usage.codexStandardTokens = nil
            usage.codexPriorityTokens = nil
            usage.codexRows = usage.codexRows?.map { row in
                CostUsageScanner.CodexUsageRow(
                    day: row.day,
                    model: row.model,
                    rawModel: row.rawModel,
                    turnID: row.turnID,
                    eventIndex: row.eventIndex,
                    timestampUnixMs: row.timestampUnixMs,
                    input: row.input,
                    cached: row.cached,
                    output: row.output,
                    reasoning: row.reasoning,
                    knownCostNanos: row.knownCostNanos,
                    unpricedTokens: row.unpricedTokens,
                    pricingModel: row.pricingModel,
                    pricingMode: nil)
            }
            migrationCache.files[path] = usage.refreshingCodexWorkspaceUsageFingerprint()
        }
        return migrationCache
    }

    static func expectedPriorityTurnKeys(
        _ turns: [String: CostUsageScanner.CodexPriorityTurnMetadata],
        calendar: Calendar = .current) -> [String: String]?
    {
        var partsByDay: [String: [String]] = [:]
        for (turnID, turn) in turns {
            guard let timestamp = turn.timestamp, let seconds = Int64(timestamp) else { continue }
            let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(seconds)),
                calendar: calendar)
            partsByDay[dayKey, default: []].append(
                [turnID, turn.model ?? "", turn.timestamp ?? "", turn.threadID ?? ""]
                    .joined(separator: "|"))
        }
        guard !partsByDay.isEmpty else { return nil }
        var out: [String: String] = [:]
        for (dayKey, parts) in partsByDay {
            let digest = SHA256.hash(data: Data(parts.sorted().joined(separator: "\n").utf8))
            out[dayKey] = digest.map { String(format: "%02x", $0) }.joined()
        }
        return out
    }

    static func persistedCursor(
        from memo: CostUsageScanner.CodexPriorityTurnsMemoState,
        databasePath: String) -> CostUsageScanner.CodexPriorityTurnsPersistedCursor
    {
        CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: memo.coverageSinceEpoch,
            lastRowID: memo.lastRowID,
            fileIdentity: memo.fileIdentity,
            anchorRowID: memo.anchorRowID,
            anchorDigest: memo.anchorDigest,
            anchors: memo.anchors,
            turns: memo.turns,
            requestSourcesByTurnID: memo.requestSourcesByTurnID,
            priorityCompletedModelsByTurnID: memo.priorityCompletedModelsByTurnID,
            completedModelsByTurnID: memo.completedModelsByTurnID,
            completedTurnIDInsertionOrder: memo.completedTurnIDInsertionOrder,
            completedTurnIDInsertionOrderStartIndex: memo.completedTurnIDInsertionOrderStartIndex)
    }

    static func emptyMemoState(observationID: UInt64) -> CostUsageScanner.CodexPriorityTurnsMemoState {
        CostUsageScanner.CodexPriorityTurnsMemoState(
            observationID: observationID,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            anchors: [],
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
    }

    static func emptyPersistedCursor(
        databasePath: String) -> CostUsageScanner.CodexPriorityTurnsPersistedCursor
    {
        CostUsageScanner.CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: 0,
            lastRowID: 0,
            fileIdentity: nil,
            anchorRowID: 0,
            anchorDigest: "",
            anchors: [],
            turns: [:],
            requestSourcesByTurnID: [:],
            priorityCompletedModelsByTurnID: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [],
            completedTurnIDInsertionOrderStartIndex: 0)
    }

    static func updateTestLog(dbURL: URL, rowID: Int64, body: String) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "update logs set feedback_log_body = ? where id = ?", -1, &statement, nil)
            == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, body, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        sqlite3_bind_int64(statement, 2, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    static func deleteTestLog(dbURL: URL, rowID: Int64) throws {
        var db: OpaquePointer?
        guard sqlite3_open(dbURL.path, &db) == SQLITE_OK else { throw SQLiteTestError.open }
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, "delete from logs where id = ?", -1, &statement, nil) == SQLITE_OK
        else { throw SQLiteTestError.prepare }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_int64(statement, 1, rowID)
        guard sqlite3_step(statement) == SQLITE_DONE else { throw SQLiteTestError.step }
    }

    static func deleteTestLogs(dbURL: URL, rowIDs: [Int64]) throws {
        for rowID in rowIDs {
            try self.deleteTestLog(dbURL: dbURL, rowID: rowID)
        }
    }

    private enum SQLiteTestError: Error {
        case open
        case prepare
        case step
    }
}
#endif
