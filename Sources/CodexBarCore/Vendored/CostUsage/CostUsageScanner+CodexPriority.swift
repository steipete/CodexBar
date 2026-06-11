import Foundation
#if canImport(os)
import os
#endif
#if canImport(SQLite3)
import SQLite3
#endif

extension CostUsageScanner {
    struct CodexPriorityTurnMetadata: Codable, Equatable {
        var threadID: String?
        var turnID: String
        var model: String?
        var timestamp: String?
    }

    private static let requestMarker = "websocket request:"

    static func defaultCodexPriorityDatabaseURL() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex", isDirectory: true)
            .appendingPathComponent("logs_2.sqlite", isDirectory: false)
    }

    #if canImport(SQLite3)
    /// Accumulated priority-turn state for one trace database. The `logs` table is an
    /// append-only log with an `INTEGER PRIMARY KEY AUTOINCREMENT` id, so rowids are
    /// monotonic and never reused: rows at or below `lastRowID` have already been examined
    /// and only newer rows need scanning on subsequent refreshes.
    struct CodexPriorityTurnsMemoState: Codable {
        var coverageSinceEpoch: Int64
        var lastRowID: Int64
        var fileIdentity: UInt64?
        var turns: [String: CodexPriorityTurnMetadata]
        var completedModelsByTurnID: [String: String]
        var completedTurnIDInsertionOrder: [String]
    }

    /// Completed-turn models are retained so a priority request parsed later — in the same
    /// batch or a later refresh — can still resolve its model alias. Whether a turn is
    /// priority is unknowable when its completion row is parsed, so non-priority completions
    /// land in the map too; without a bound it would grow with every completed turn for the
    /// process lifetime. Once the map exceeds this limit the oldest completions are evicted,
    /// keeping memory constant while preserving completion-before-request ordering and late
    /// model upgrades within the retention window.
    static let codexPriorityCompletedModelRetentionLimit = 4096

    static let codexPriorityTurnsMemo =
        OSAllocatedUnfairLock<[String: CodexPriorityTurnsMemoState]>(initialState: [:])

    /// Scans run outside the lock, so two overlapping refreshes can both read the same memo,
    /// scan independently, and write back out of order. Stored state only advances: a snapshot
    /// is discarded when the stored one already covers it (same file, coverage starting at
    /// least as early, cursor at least as far), so a slower writer with an older cursor can
    /// never replace newer accumulated state. Writers that neither dominate nor are dominated
    /// (e.g. one expanded coverage while another advanced the cursor) overwrite and converge
    /// through the rescan checks on the next refresh.
    static func storeCodexPriorityTurnsMemoIfNewer(
        _ updated: CodexPriorityTurnsMemoState,
        forPath path: String)
    {
        let stored = self.codexPriorityTurnsMemo.withLock { memo in
            if let existing = memo[path],
               existing.fileIdentity == updated.fileIdentity,
               existing.coverageSinceEpoch <= updated.coverageSinceEpoch,
               existing.lastRowID >= updated.lastRowID
            {
                return false
            }
            memo[path] = updated
            return true
        }
        if stored { self.markCodexPriorityTurnsMemoDirty() }
    }

    static func _test_resetCodexPriorityTurnsMemo() {
        self.codexPriorityTurnsMemo.withLock { $0.removeAll() }
    }

    static func _test_codexPriorityTurnsMemoState(forPath path: String) -> CodexPriorityTurnsMemoState? {
        self.codexPriorityTurnsMemo.withLock { $0[path] }
    }

    static func _test_removeCodexPriorityTurnsMemoState(forPath path: String) {
        self.codexPriorityTurnsMemo.withLock { $0[path] = nil }
    }
    #endif

    /// Resolves priority turn metadata from the codex CLI trace database. The full-table
    /// `LIKE` scan over `feedback_log_body` grows with the database (hundreds of megabytes on
    /// active machines) and used to run on every refresh past the scan interval. For windows
    /// that extend through today — every live refresh — the result is now accumulated per
    /// database in process memory and only rows appended since the last call are examined; the
    /// database shrinking or being replaced, or the requested window expanding earlier than
    /// the accumulated coverage, triggers a full rescan. Windows that end before today keep
    /// the original bounded one-shot query so historical lookups never pay an open-ended scan.
    static func codexPriorityTurns(
        databaseURL: URL? = nil,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil) -> [String: CodexPriorityTurnMetadata]
    {
        let url = databaseURL ?? self.defaultCodexPriorityDatabaseURL()
        guard FileManager.default.fileExists(atPath: url.path) else { return [:] }

        #if canImport(SQLite3)
        if let untilDayKey, untilDayKey < CostUsageDayRange.dayKey(from: Date()) {
            return self.boundedCodexPriorityTurns(
                databaseURL: url,
                sinceDayKey: sinceDayKey,
                untilDayKey: untilDayKey)
        }

        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        guard let maxRowID = self.maxLogsRowID(db) else { return [:] }

        let requestedSinceEpoch: Int64 = if sinceDayKey != nil || untilDayKey != nil {
            self.epochSeconds(forDayKey: sinceDayKey ?? "0000-01-01") ?? 0
        } else {
            0
        }

        let fileIdentity = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber]
            .flatMap { $0 as? UInt64 }

        var state = self.codexPriorityTurnsMemo.withLock { $0[url.path] }
        if let memo = state,
           maxRowID < memo.lastRowID
           || requestedSinceEpoch < memo.coverageSinceEpoch
           || memo.fileIdentity != fileIdentity
        {
            state = nil
        }
        var resolved = state ?? CodexPriorityTurnsMemoState(
            coverageSinceEpoch: requestedSinceEpoch,
            lastRowID: 0,
            fileIdentity: fileIdentity,
            turns: [:],
            completedModelsByTurnID: [:],
            completedTurnIDInsertionOrder: [])

        if maxRowID > resolved.lastRowID {
            guard self.accumulateCodexPriorityTurns(db, into: &resolved) else { return [:] }
            resolved.lastRowID = maxRowID
            self.storeCodexPriorityTurnsMemoIfNewer(resolved, forPath: url.path)
        }

        guard sinceDayKey != nil || untilDayKey != nil else { return resolved.turns }
        return resolved.turns.filter { _, turn in
            self.timestamp(turn.timestamp, isInRangeSince: sinceDayKey, until: untilDayKey)
        }
        #else
        return [:]
        #endif
    }

    #if canImport(SQLite3)
    /// The pre-memo one-shot query, kept for windows that end before today: both `ts` bounds
    /// stay in SQL, so a narrow historical window never scans the database tail.
    private static func boundedCodexPriorityTurns(
        databaseURL: URL,
        sinceDayKey: String?,
        untilDayKey: String?) -> [String: CodexPriorityTurnMetadata]
    {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return [:]
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let query = """
        select ts, feedback_log_body
        from logs
        where ts >= ? and ts < ?
          and (feedback_log_body like '%websocket request:%'
               or feedback_log_body like '%response.completed%')
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return [:] }
        defer { sqlite3_finalize(stmt) }
        let start = self.epochSeconds(forDayKey: sinceDayKey ?? "0000-01-01") ?? 0
        let end = self.epochSeconds(forDayKey: self.nextDayKey(after: untilDayKey ?? "9999-12-30"))
            ?? Int64.max
        sqlite3_bind_int64(stmt, 1, start)
        sqlite3_bind_int64(stmt, 2, end)

        var turns: [String: CodexPriorityTurnMetadata] = [:]
        var completedModelsByTurnID: [String: String] = [:]
        while sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = self.timestamp(stmt: stmt, index: 0)
            guard self.timestamp(timestamp, isInRangeSince: sinceDayKey, until: untilDayKey),
                  let body = self.text(stmt: stmt, index: 1)
            else { continue }
            if let completed = self.parseCodexCompletedTraceRow(body: body) {
                completedModelsByTurnID[completed.turnID] = completed.model
                if var existing = turns[completed.turnID] {
                    existing.model = completed.model
                    turns[completed.turnID] = existing
                }
                continue
            }
            guard var parsed = self.parseCodexPriorityTraceRow(timestamp: timestamp, body: body)
            else { continue }
            if let completedModel = completedModelsByTurnID[parsed.turnID] {
                parsed.model = completedModel
            }
            turns[parsed.turnID] = parsed
        }
        return turns
    }

    private static func maxLogsRowID(_ db: OpaquePointer?) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select max(rowid) from logs", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func accumulateCodexPriorityTurns(
        _ db: OpaquePointer?,
        into state: inout CodexPriorityTurnsMemoState) -> Bool
    {
        let query = """
        select rowid, ts, feedback_log_body
        from logs
        where rowid > ? and ts >= ?
          and (feedback_log_body like '%websocket request:%'
               or feedback_log_body like '%response.completed%')
        order by rowid
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, state.lastRowID)
        sqlite3_bind_int64(stmt, 2, state.coverageSinceEpoch)

        while sqlite3_step(stmt) == SQLITE_ROW {
            let timestamp = self.timestamp(stmt: stmt, index: 1)
            guard let body = self.text(stmt: stmt, index: 2) else { continue }
            if let completed = self.parseCodexCompletedTraceRow(body: body) {
                if state.completedModelsByTurnID.updateValue(completed.model, forKey: completed.turnID) == nil {
                    state.completedTurnIDInsertionOrder.append(completed.turnID)
                    if state.completedTurnIDInsertionOrder.count > self.codexPriorityCompletedModelRetentionLimit {
                        let evicted = state.completedTurnIDInsertionOrder.removeFirst()
                        state.completedModelsByTurnID.removeValue(forKey: evicted)
                    }
                }
                if var existing = state.turns[completed.turnID] {
                    existing.model = completed.model
                    state.turns[completed.turnID] = existing
                }
                continue
            }
            guard var parsed = self.parseCodexPriorityTraceRow(timestamp: timestamp, body: body)
            else { continue }
            if let completedModel = state.completedModelsByTurnID[parsed.turnID] {
                parsed.model = completedModel
            }
            state.turns[parsed.turnID] = parsed
        }
        return true
    }
    #endif

    static func parseCodexPriorityTraceRow(timestamp: String?, body: String) -> CodexPriorityTurnMetadata? {
        guard let markerRange = body.range(of: self.requestMarker) else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let request = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              request["type"] as? String == "response.create",
              request["service_tier"] as? String == "priority"
        else { return nil }

        let turnID = self.value(named: "turn.id", in: prefix)
            ?? self.value(named: "turn_id", in: prefix)
            ?? request["turn_id"] as? String
        guard let turnID, !turnID.isEmpty else { return nil }

        return CodexPriorityTurnMetadata(
            threadID: self.value(named: "thread_id", in: prefix),
            turnID: turnID,
            model: request["model"] as? String,
            timestamp: timestamp)
    }

    static func parseCodexCompletedTraceRow(body: String) -> (turnID: String, model: String)? {
        let marker = "websocket event:"
        guard let markerRange = body.range(of: marker) else { return nil }
        let prefix = String(body[..<markerRange.lowerBound])
        let jsonText = body[markerRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = jsonText.data(using: .utf8),
              let event = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              event["type"] as? String == "response.completed",
              let response = event["response"] as? [String: Any],
              let model = response["model"] as? String,
              !model.isEmpty
        else { return nil }

        let turnID = self.value(named: "turn.id", in: prefix)
            ?? self.value(named: "turn_id", in: prefix)
        guard let turnID, !turnID.isEmpty else { return nil }

        return (turnID: turnID, model: model)
    }

    private static func value(named name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name)=") else { return nil }
        let tail = text[range.upperBound...]
        let value = tail.prefix { char in
            !char.isWhitespace && char != "," && char != "]" && char != ")"
        }
        return value.isEmpty ? nil : String(value)
    }

    #if canImport(SQLite3)
    private static func text(stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cString)
    }

    private static func timestamp(stmt: OpaquePointer?, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL else { return nil }
        if sqlite3_column_type(stmt, index) == SQLITE_INTEGER {
            return String(sqlite3_column_int64(stmt, index))
        }
        return self.text(stmt: stmt, index: index)
    }
    #endif

    private static func timestamp(_ timestamp: String?, isInRangeSince since: String?, until: String?) -> Bool {
        guard since != nil || until != nil else { return true }
        guard let dayKey = self.dayKey(fromTimestamp: timestamp) else { return false }
        if let since, dayKey < since { return false }
        if let until, dayKey > until { return false }
        return true
    }

    private static func dayKey(fromTimestamp timestamp: String?) -> String? {
        guard let timestamp else { return nil }
        if let seconds = Int64(timestamp) {
            return CostUsageScanner.CostUsageDayRange.dayKey(
                from: Date(timeIntervalSince1970: TimeInterval(seconds)))
        }
        let dayKey = timestamp.prefix(10)
        return dayKey.count == 10 ? String(dayKey) : nil
    }

    private static func nextDayKey(after dayKey: String) -> String {
        guard let date = self.localDate(forDayKey: dayKey),
              let next = Calendar.current.date(byAdding: .day, value: 1, to: date)
        else { return dayKey }
        return CostUsageScanner.CostUsageDayRange.dayKey(from: next)
    }

    private static func epochSeconds(forDayKey dayKey: String) -> Int64? {
        guard let date = self.localDate(forDayKey: dayKey) else { return nil }
        return Int64(date.timeIntervalSince1970)
    }

    private static func localDate(forDayKey dayKey: String) -> Date? {
        let parts = dayKey.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]),
              let month = Int(parts[1]),
              let day = Int(parts[2])
        else { return nil }
        var components = DateComponents()
        components.calendar = Calendar.current
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }
}
