#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
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

    struct CodexPriorityCursorAnchor: Codable, Equatable {
        var rowID: Int64
        var digest: String
    }

    /// Durable scan cursor for one trace database. `observationID` is process-local and is not
    /// persisted; a restored cursor is applied only when `databasePath` matches the open DB.
    struct CodexPriorityTurnsPersistedCursor: Codable, Equatable {
        var databasePath: String
        var coverageSinceEpoch: Int64
        var lastRowID: Int64
        var fileIdentity: UInt64?
        var anchorRowID: Int64
        var anchorDigest: String
        var anchors: [CodexPriorityCursorAnchor]?
        var turns: [String: CodexPriorityTurnMetadata]
        var requestSourcesByTurnID: [String: [Int64: CodexPriorityTurnMetadata]]
        var priorityCompletedModelsByTurnID: [String: [Int64: String]]
        var completedModelsByTurnID: [String: [Int64: String]]
        var completedTurnIDInsertionOrder: [String]
        var completedTurnIDInsertionOrderStartIndex: Int
    }

    struct CodexPriorityTurnsResolution {
        var turns: [String: CodexPriorityTurnMetadata]
        var validationPending: Bool
    }

    private static let requestMarker = "websocket request:"

    static func defaultCodexPriorityDatabaseURL() -> URL {
        CodexPriorityDatabasePath.defaultURL()
    }

    static func resolvedCodexPriorityDatabaseURL(_ databaseURL: URL?) -> URL {
        databaseURL ?? self.defaultCodexPriorityDatabaseURL()
    }

    /// Restores a previously persisted cursor into the process memo when that path has no live
    /// entry. A live memo always wins; a nil, path-mismatched, or already-seeded cursor is a no-op.
    static func seedCodexPriorityTurnsMemoIfEmpty(
        _ cursor: CodexPriorityTurnsPersistedCursor?,
        databaseURL: URL)
    {
        #if canImport(SQLite3)
        guard let cursor, cursor.databasePath == databaseURL.path else { return }
        let path = databaseURL.path
        let needsSeed = self.codexPriorityTurnsMemo.withLock { $0[path] == nil }
        guard needsSeed else { return }
        let observationID = self.nextCodexPriorityTurnsObservationID()
        self.codexPriorityTurnsMemo.withLock { memo in
            guard memo[path] == nil else { return }
            memo[path] = self.memoState(from: cursor, observationID: observationID)
        }
        #endif
    }

    /// Drops process-local accumulated state so the next scan rebuilds from row 0.
    static func dropCodexPriorityTurnsMemo(databaseURL: URL) {
        #if canImport(SQLite3)
        self.codexPriorityTurnsMemo.withLock { memo in
            _ = memo.removeValue(forKey: databaseURL.path)
        }
        #endif
    }

    /// Snapshot of the live process memo for `databaseURL`. Nil when this process has not
    /// opened the DB.
    static func codexPriorityTurnsPersistedCursor(databaseURL: URL) -> CodexPriorityTurnsPersistedCursor? {
        #if canImport(SQLite3)
        return self.codexPriorityTurnsMemo.withLock { memo in
            memo[databaseURL.path].map {
                self.persistedCursor(from: $0, databasePath: databaseURL.path)
            }
        }
        #else
        return nil
        #endif
    }

    #if canImport(SQLite3)
    /// Accumulated priority-turn state for one trace database. A durable cursor is persisted
    /// with Codex cache metadata and reseeded into this process-local memo after relaunch.
    /// The `logs` table uses an `INTEGER PRIMARY KEY AUTOINCREMENT` id, so rowids are
    /// monotonic and never reused. Codex prunes old rows in place, so source row IDs are
    /// retained and cheaply revalidated before each incremental scan.
    struct CodexPriorityTurnsMemoState {
        var observationID: UInt64
        var coverageSinceEpoch: Int64
        var lastRowID: Int64
        var fileIdentity: UInt64?
        var anchorRowID: Int64 = 0
        var anchorDigest: String = ""
        var anchors: [CodexPriorityCursorAnchor]?
        var turns: [String: CodexPriorityTurnMetadata]
        var requestSourcesByTurnID: [String: [Int64: CodexPriorityTurnMetadata]]
        var priorityCompletedModelsByTurnID: [String: [Int64: String]]
        var completedModelsByTurnID: [String: [Int64: String]]
        var completedTurnIDInsertionOrder: [String]
        var completedTurnIDInsertionOrderStartIndex: Int
    }

    private static func memoState(
        from cursor: CodexPriorityTurnsPersistedCursor,
        observationID: UInt64) -> CodexPriorityTurnsMemoState
    {
        CodexPriorityTurnsMemoState(
            observationID: observationID,
            coverageSinceEpoch: cursor.coverageSinceEpoch,
            lastRowID: cursor.lastRowID,
            fileIdentity: cursor.fileIdentity,
            anchorRowID: cursor.anchorRowID,
            anchorDigest: cursor.anchorDigest,
            anchors: cursor.anchors,
            turns: cursor.turns,
            requestSourcesByTurnID: cursor.requestSourcesByTurnID,
            priorityCompletedModelsByTurnID: cursor.priorityCompletedModelsByTurnID,
            completedModelsByTurnID: cursor.completedModelsByTurnID,
            completedTurnIDInsertionOrder: cursor.completedTurnIDInsertionOrder,
            completedTurnIDInsertionOrderStartIndex: cursor.completedTurnIDInsertionOrderStartIndex)
    }

    private static func persistedCursor(
        from state: CodexPriorityTurnsMemoState,
        databasePath: String) -> CodexPriorityTurnsPersistedCursor
    {
        CodexPriorityTurnsPersistedCursor(
            databasePath: databasePath,
            coverageSinceEpoch: state.coverageSinceEpoch,
            lastRowID: state.lastRowID,
            fileIdentity: state.fileIdentity,
            anchorRowID: state.anchorRowID,
            anchorDigest: state.anchorDigest,
            anchors: state.anchors,
            turns: state.turns,
            requestSourcesByTurnID: state.requestSourcesByTurnID,
            priorityCompletedModelsByTurnID: state.priorityCompletedModelsByTurnID,
            completedModelsByTurnID: state.completedModelsByTurnID,
            completedTurnIDInsertionOrder: state.completedTurnIDInsertionOrder,
            completedTurnIDInsertionOrderStartIndex: state.completedTurnIDInsertionOrderStartIndex)
    }

    /// Completion models for known priority turns are retained with those turns. Completions
    /// seen before their request are pending and may belong to non-priority turns, so that
    /// separate map is bounded to keep memory constant while preserving ordering.
    static let codexPriorityCompletedModelRetentionLimit = 4096

    private final class CodexPriorityLockedState<State>: @unchecked Sendable {
        private let lock = NSLock()
        private var state: State

        init(_ state: State) {
            self.state = state
        }

        func withLock<Result>(_ body: (inout State) throws -> Result) rethrows -> Result {
            self.lock.lock()
            defer { self.lock.unlock() }
            return try body(&self.state)
        }
    }

    private static let codexPriorityTurnsMemo =
        CodexPriorityLockedState<[String: CodexPriorityTurnsMemoState]>([:])
    private static let codexPriorityTurnsObservationCounter = CodexPriorityLockedState<UInt64>(0)
    #if DEBUG
    private static let codexPriorityBeforeFallbackColdScanHook =
        CodexPriorityLockedState<[String: (OpaquePointer?) -> Void]>([:])
    #endif

    private static func nextCodexPriorityTurnsObservationID() -> UInt64 {
        self.codexPriorityTurnsObservationCounter.withLock {
            $0 &+= 1
            return $0
        }
    }

    /// Scans run outside the lock, so overlapping refreshes can write back out of order.
    /// A monotonically increasing observation ID makes the later-started scan authoritative;
    /// same-observation test snapshots still use coverage/cursor dominance.
    static func storeCodexPriorityTurnsMemoIfNewer(
        _ updated: CodexPriorityTurnsMemoState,
        forPath path: String)
    {
        self.codexPriorityTurnsMemo.withLock { memo in
            if let existing = memo[path],
               existing.observationID > updated.observationID
            {
                return
            }
            if let existing = memo[path],
               existing.observationID == updated.observationID,
               existing.fileIdentity == updated.fileIdentity,
               existing.coverageSinceEpoch <= updated.coverageSinceEpoch,
               existing.lastRowID >= updated.lastRowID
            {
                return
            }
            memo[path] = updated
        }
    }

    static func _test_resetCodexPriorityTurnsMemo() {
        self.codexPriorityTurnsMemo.withLock { $0.removeAll() }
        self.codexPriorityTurnsObservationCounter.withLock { $0 = 0 }
    }

    static func _test_resetCodexPriorityTurnsMemo(forPath path: String) {
        self.dropCodexPriorityTurnsMemo(databaseURL: URL(fileURLWithPath: path))
    }

    static func _test_codexPriorityTurnsMemoState(forPath path: String) -> CodexPriorityTurnsMemoState? {
        self.codexPriorityTurnsMemo.withLock { $0[path] }
    }

    static func _test_codexPriorityDatabaseFileIdentity(at url: URL) -> UInt64? {
        self.codexPriorityDatabaseFileIdentity(at: url)
    }

    static func _test_accumulateCodexPriorityTurns(
        _ db: OpaquePointer?,
        into state: inout CodexPriorityTurnsMemoState) -> Bool
    {
        self.accumulateCodexPriorityTurns(db, into: &state)
    }

    static func _test_codexPriorityAccumulationQuery(
        _ db: OpaquePointer?,
        lastRowID: Int64,
        coverageSinceEpoch: Int64) -> String
    {
        self.codexPriorityAccumulationPlan(
            db,
            lastRowID: lastRowID,
            coverageSinceEpoch: coverageSinceEpoch).query
    }

    static func _test_codexPriorityAnchorSelectionQuery() -> String {
        self.codexPriorityAnchorSelectionQuery
    }

    static func _test_codexPriorityAnchorMinimumQuery() -> String {
        self.codexPriorityAnchorMinimumQuery
    }

    static func _test_codexPriorityAnchorLookupQuery() -> String {
        self.codexPriorityAnchorLookupQuery
    }

    #if DEBUG
    static func _test_setCodexPriorityBeforeFallbackColdScanHook(
        databaseURL: URL,
        _ hook: ((OpaquePointer?) -> Void)?)
    {
        self.codexPriorityBeforeFallbackColdScanHook.withLock { hooks in
            if let hook {
                hooks[databaseURL.path] = hook
            } else {
                hooks.removeValue(forKey: databaseURL.path)
            }
        }
    }

    private static func runCodexPriorityBeforeFallbackColdScanHook(
        databaseURL: URL,
        db: OpaquePointer?)
    {
        let hook = self.codexPriorityBeforeFallbackColdScanHook.withLock { $0[databaseURL.path] }
        hook?(db)
    }
    #endif

    #endif

    /// Resolves priority turn metadata from the codex CLI trace database. The full-table
    /// `LIKE` scan over `feedback_log_body` grows with the database (hundreds of megabytes on
    /// active machines) and used to run on every refresh past the scan interval. For windows
    /// that extend through today — every live refresh — the result is now accumulated per
    /// database in a process-local memo (reseeded from the persisted cursor after relaunch)
    /// and only rows appended since the last call are examined; the database shrinking or
    /// being replaced, or the requested window expanding earlier than the accumulated
    /// coverage, triggers a full rescan. Windows that end before today keep the original
    /// bounded one-shot query so historical lookups never pay an open-ended scan.
    static func codexPriorityTurns(
        databaseURL: URL? = nil,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil) -> [String: CodexPriorityTurnMetadata]
    {
        self.resolveCodexPriorityTurns(
            databaseURL: databaseURL,
            sinceDayKey: sinceDayKey,
            untilDayKey: untilDayKey).turns
    }

    static func resolveCodexPriorityTurns(
        databaseURL: URL? = nil,
        sinceDayKey: String? = nil,
        untilDayKey: String? = nil,
        expectExistingDatabase: Bool = false) -> CodexPriorityTurnsResolution
    {
        let url = self.resolvedCodexPriorityDatabaseURL(databaseURL)
        guard FileManager.default.fileExists(atPath: url.path) else {
            // A missing optional source is normal until this same path has supplied cached evidence.
            return CodexPriorityTurnsResolution(turns: [:], validationPending: expectExistingDatabase)
        }

        #if canImport(SQLite3)
        if let untilDayKey, untilDayKey < CostUsageDayRange.dayKey(from: Date()) {
            return self.boundedCodexPriorityTurns(
                databaseURL: url,
                sinceDayKey: sinceDayKey,
                untilDayKey: untilDayKey)
        }

        guard let opened = self.openCodexPriorityDatabase(at: url) else {
            return CodexPriorityTurnsResolution(turns: [:], validationPending: true)
        }
        let db = opened.db
        let fileIdentity = opened.fileIdentity
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let observationID = self.nextCodexPriorityTurnsObservationID()
        guard let maxRowID = self.maxCodexLogsRowID(db) else {
            return CodexPriorityTurnsResolution(turns: [:], validationPending: true)
        }

        let requestedSinceEpoch: Int64 = if sinceDayKey != nil || untilDayKey != nil {
            self.epochSeconds(forDayKey: sinceDayKey ?? "0000-01-01") ?? 0
        } else {
            0
        }

        var state = self.codexPriorityTurnsMemo.withLock { $0[url.path] }
        if let memo = state,
           maxRowID < memo.lastRowID
           || requestedSinceEpoch < memo.coverageSinceEpoch
           || memo.fileIdentity != fileIdentity
        {
            state = nil
        }
        var anchorsNeedRefresh = false
        if let memo = state {
            switch self.validateCodexPriorityCursorAnchors(db, state: memo) {
            case let .valid(needsRefresh):
                anchorsNeedRefresh = needsRefresh
            case .invalid:
                state = nil
            }
        }
        let freshState = {
            CodexPriorityTurnsMemoState(
                observationID: observationID,
                coverageSinceEpoch: requestedSinceEpoch,
                lastRowID: 0,
                fileIdentity: fileIdentity,
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
        var resolved = state ?? freshState()
        resolved.observationID = observationID

        var prunedDeletedSources = false
        var failedReplacementFallback: CodexPriorityTurnsMemoState?
        if state != nil {
            var pruned = resolved
            if let didPrune = self.pruneDeletedCodexPrioritySources(db, from: &pruned) {
                resolved = pruned
                prunedDeletedSources = didPrune
            } else {
                // A retained priority source changed or could not be checked. Rebuild instead of
                // publishing metadata that may no longer match a cold scan. Keep the prior memo
                // as the failure result until the replacement scan completes successfully.
                failedReplacementFallback = resolved
                state = nil
                anchorsNeedRefresh = false
                resolved = freshState()
                #if DEBUG
                self.runCodexPriorityBeforeFallbackColdScanHook(databaseURL: url, db: db)
                #endif
            }
        }

        if maxRowID > resolved.lastRowID {
            var updated = resolved
            guard self.accumulateCodexPriorityTurns(db, into: &updated) else {
                return CodexPriorityTurnsResolution(
                    turns: self.filteredResolvedCodexPriorityTurns(
                        failedReplacementFallback ?? resolved,
                        sinceDayKey: sinceDayKey,
                        untilDayKey: untilDayKey),
                    validationPending: true)
            }
            updated.lastRowID = maxRowID
            guard self.captureCodexPriorityCursorAnchors(db, into: &updated) else {
                return CodexPriorityTurnsResolution(
                    turns: self.filteredResolvedCodexPriorityTurns(
                        updated,
                        sinceDayKey: sinceDayKey,
                        untilDayKey: untilDayKey),
                    validationPending: true)
            }
            self.storeCodexPriorityTurnsMemoIfNewer(updated, forPath: url.path)
            resolved = updated
        } else if anchorsNeedRefresh {
            var updated = resolved
            guard self.captureCodexPriorityCursorAnchors(db, into: &updated) else {
                return CodexPriorityTurnsResolution(
                    turns: self.filteredResolvedCodexPriorityTurns(
                        resolved,
                        sinceDayKey: sinceDayKey,
                        untilDayKey: untilDayKey),
                    validationPending: true)
            }
            self.storeCodexPriorityTurnsMemoIfNewer(updated, forPath: url.path)
            resolved = updated
        } else if state == nil || prunedDeletedSources {
            self.storeCodexPriorityTurnsMemoIfNewer(resolved, forPath: url.path)
        }

        return CodexPriorityTurnsResolution(
            turns: self.filteredResolvedCodexPriorityTurns(
                resolved,
                sinceDayKey: sinceDayKey,
                untilDayKey: untilDayKey),
            validationPending: false)
        #else
        return CodexPriorityTurnsResolution(turns: [:], validationPending: false)
        #endif
    }

    #if canImport(SQLite3)
    private static func filteredResolvedCodexPriorityTurns(
        _ state: CodexPriorityTurnsMemoState,
        sinceDayKey: String?,
        untilDayKey: String?) -> [String: CodexPriorityTurnMetadata]
    {
        var turns = state.turns
        for (turnID, completedModels) in state.priorityCompletedModelsByTurnID {
            turns[turnID]?.model = self.latestCodexCompletedModel(completedModels)
        }
        guard sinceDayKey != nil || untilDayKey != nil else { return turns }
        return turns.filter { _, turn in
            self.timestamp(turn.timestamp, isInRangeSince: sinceDayKey, until: untilDayKey)
        }
    }

    private static func latestCodexCompletedModel(_ modelsByRowID: [Int64: String]) -> String? {
        modelsByRowID.max { $0.key < $1.key }?.value
    }

    /// The pre-memo one-shot query, kept for windows that end before today: both `ts` bounds
    /// stay in SQL, so a narrow historical window never scans the database tail.
    private static func boundedCodexPriorityTurns(
        databaseURL: URL,
        sinceDayKey: String?,
        untilDayKey: String?) -> CodexPriorityTurnsResolution
    {
        var db: OpaquePointer?
        guard sqlite3_open_v2(databaseURL.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return CodexPriorityTurnsResolution(turns: [:], validationPending: true)
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)

        let query = """
        select ts, feedback_log_body
        from logs
        where ts >= ? and ts < ?
          and (feedback_log_body like '%websocket request:%'
               or feedback_log_body like '%response.completed%'
               or feedback_log_body like '%service_tier: Some(Some("priority"))%')
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else {
            return CodexPriorityTurnsResolution(turns: [:], validationPending: true)
        }
        defer { sqlite3_finalize(stmt) }
        let start = self.epochSeconds(forDayKey: sinceDayKey ?? "0000-01-01") ?? 0
        let end = self.epochSeconds(forDayKey: self.nextDayKey(after: untilDayKey ?? "9999-12-30"))
            ?? Int64.max
        guard sqlite3_bind_int64(stmt, 1, start) == SQLITE_OK,
              sqlite3_bind_int64(stmt, 2, end) == SQLITE_OK
        else { return CodexPriorityTurnsResolution(turns: [:], validationPending: true) }

        var turns: [String: CodexPriorityTurnMetadata] = [:]
        var completedModelsByTurnID: [String: String] = [:]
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            defer { stepResult = sqlite3_step(stmt) }
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
            if var parsed = self.parseCodexPriorityTraceRow(timestamp: timestamp, body: body) {
                if let completedModel = completedModelsByTurnID[parsed.turnID] {
                    parsed.model = completedModel
                }
                turns[parsed.turnID] = parsed
            }
        }
        return CodexPriorityTurnsResolution(
            turns: turns,
            validationPending: stepResult != SQLITE_DONE)
    }

    private static func maxCodexLogsRowID(_ db: OpaquePointer?) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, "select max(rowid) from logs", -1, &stmt, nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    static func openCodexPriorityDatabase(
        at url: URL,
        afterOpen: (() -> Void)? = nil) -> (db: OpaquePointer?, fileIdentity: UInt64)?
    {
        guard let fileIdentity = self.codexPriorityDatabaseFileIdentity(at: url) else { return nil }
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            sqlite3_close(db)
            return nil
        }
        afterOpen?()
        guard self.codexPriorityDatabaseFileIdentity(at: url) == fileIdentity else {
            sqlite3_close(db)
            return nil
        }
        return (db, fileIdentity)
    }

    private static func codexPriorityDatabaseFileIdentity(at url: URL) -> UInt64? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.systemFileNumber]
            .flatMap { $0 as? UInt64 }
    }

    private enum CodexPriorityCursorAnchorValidation {
        case valid(needsRefresh: Bool)
        case invalid
    }

    private enum CodexPriorityCursorAnchorLookup {
        case found(String)
        case missing
        case failed
    }

    private static let codexPriorityAnchorSelectionQuery = """
    select rowid, ts, feedback_log_body
    from logs
    where rowid <= ?
    order by rowid desc
    limit 1
    """

    private static let codexPriorityAnchorMinimumQuery = """
    select min(rowid)
    from logs
    where rowid <= ?
    """

    private static let codexPriorityAnchorLookupQuery = """
    select ts, feedback_log_body
    from logs
    where rowid = ?
    """

    private static func captureCodexPriorityCursorAnchors(
        _ db: OpaquePointer?,
        into state: inout CodexPriorityTurnsMemoState) -> Bool
    {
        guard state.lastRowID > 0 else {
            state.anchors = []
            state.anchorRowID = 0
            state.anchorDigest = ""
            return true
        }
        guard sqlite3_exec(db, "begin deferred transaction", nil, nil, nil) == SQLITE_OK else {
            return false
        }
        var committed = false
        defer {
            if !committed {
                sqlite3_exec(db, "rollback", nil, nil, nil)
            }
        }

        guard let minimumRowID = self.minCodexLogsRowID(db, through: state.lastRowID) else {
            return false
        }
        let span = state.lastRowID - minimumRowID
        let targets = [
            minimumRowID + span / 4,
            minimumRowID + span / 2,
            minimumRowID + (span / 4) * 3 + (span % 4) * 3 / 4,
            state.lastRowID,
        ]
        var anchors: [CodexPriorityCursorAnchor] = []
        var capturedRowIDs: Set<Int64> = []
        for target in targets {
            guard let anchor = self.codexPriorityCursorAnchor(db, atOrBefore: target) else {
                return false
            }
            if capturedRowIDs.insert(anchor.rowID).inserted {
                anchors.append(anchor)
            }
        }
        guard sqlite3_exec(db, "commit", nil, nil, nil) == SQLITE_OK else { return false }
        committed = true

        guard let terminalAnchor = anchors.last else { return false }
        state.anchors = anchors
        // Keep the terminal anchor for older CodexBar versions that ignore `anchors`.
        state.anchorRowID = terminalAnchor.rowID
        state.anchorDigest = terminalAnchor.digest
        return true
    }

    private static func validateCodexPriorityCursorAnchors(
        _ db: OpaquePointer?,
        state: CodexPriorityTurnsMemoState) -> CodexPriorityCursorAnchorValidation
    {
        if let anchors = state.anchors {
            guard !anchors.isEmpty || state.lastRowID == 0 else { return .invalid }
            guard sqlite3_exec(db, "begin deferred transaction", nil, nil, nil) == SQLITE_OK else {
                return .invalid
            }
            var matchingCount = 0
            var missingCount = 0
            var lookupFailed = false
            var digestMismatched = false
            for anchor in anchors {
                switch self.codexPriorityCursorAnchorLookup(db, rowID: anchor.rowID) {
                case let .found(digest):
                    if digest == anchor.digest {
                        matchingCount += 1
                    } else {
                        digestMismatched = true
                    }
                case .missing:
                    missingCount += 1
                case .failed:
                    lookupFailed = true
                }
            }
            guard sqlite3_exec(db, "commit", nil, nil, nil) == SQLITE_OK else {
                sqlite3_exec(db, "rollback", nil, nil, nil)
                return .invalid
            }
            guard !lookupFailed, !digestMismatched else { return .invalid }
            // With fewer than four distinct rows there is no distributed quorum to rely on.
            let requiredMatches = anchors.count < 4 ? anchors.count : 2
            guard matchingCount >= requiredMatches else { return .invalid }
            return .valid(needsRefresh: missingCount > 0)
        }

        // A cursor written before distributed anchors must still pass its strict legacy check.
        guard state.lastRowID == 0 || (state.anchorRowID > 0 && !state.anchorDigest.isEmpty) else {
            return .invalid
        }
        guard state.lastRowID > 0 else { return .valid(needsRefresh: true) }
        switch self.codexPriorityCursorAnchorLookup(db, rowID: state.anchorRowID) {
        case let .found(digest) where digest == state.anchorDigest:
            return .valid(needsRefresh: true)
        case .found, .missing, .failed:
            return .invalid
        }
    }

    private static func minCodexLogsRowID(_ db: OpaquePointer?, through rowID: Int64) -> Int64? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            self.codexPriorityAnchorMinimumQuery,
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        guard sqlite3_step(stmt) == SQLITE_ROW,
              sqlite3_column_type(stmt, 0) != SQLITE_NULL
        else { return nil }
        return sqlite3_column_int64(stmt, 0)
    }

    private static func codexPriorityCursorAnchor(
        _ db: OpaquePointer?,
        atOrBefore rowID: Int64) -> CodexPriorityCursorAnchor?
    {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            self.codexPriorityAnchorSelectionQuery,
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }

        return CodexPriorityCursorAnchor(
            rowID: sqlite3_column_int64(stmt, 0),
            digest: self.codexPriorityCursorAnchorDigest(stmt, timestampIndex: 1, bodyIndex: 2))
    }

    private static func codexPriorityCursorAnchorLookup(
        _ db: OpaquePointer?,
        rowID: Int64) -> CodexPriorityCursorAnchorLookup
    {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            self.codexPriorityAnchorLookupQuery,
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { return .failed }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, rowID)
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            return .found(self.codexPriorityCursorAnchorDigest(stmt, timestampIndex: 0, bodyIndex: 1))
        case SQLITE_DONE:
            return .missing
        default:
            return .failed
        }
    }

    private static func codexPriorityCursorAnchorDigest(
        _ stmt: OpaquePointer?,
        timestampIndex: Int32,
        bodyIndex: Int32) -> String
    {
        let timestamp = sqlite3_column_int64(stmt, timestampIndex)
        var payload = Data("\(timestamp)\n".utf8)
        if sqlite3_column_type(stmt, bodyIndex) != SQLITE_NULL {
            let byteCount = Int(sqlite3_column_bytes(stmt, bodyIndex))
            if byteCount > 0, let bytes = sqlite3_column_blob(stmt, bodyIndex) {
                payload.append(Data(bytes: bytes, count: byteCount))
            }
        }
        return SHA256.hash(data: payload).map { String(format: "%02x", $0) }.joined()
    }

    private static func pruneDeletedCodexPrioritySources(
        _ db: OpaquePointer?,
        from state: inout CodexPriorityTurnsMemoState) -> Bool?
    {
        guard let retainedRowIDs = self.retainedCodexPrioritySourceRowIDs(db, state: state) else {
            return nil
        }

        var didPrune = false
        for (turnID, sources) in state.requestSourcesByTurnID {
            let retainedSources = sources.filter { retainedRowIDs.contains($0.key) }
            guard retainedSources.count != sources.count else { continue }
            didPrune = true
            if retainedSources.isEmpty {
                state.requestSourcesByTurnID.removeValue(forKey: turnID)
                state.turns.removeValue(forKey: turnID)
                if let completedModels = state.priorityCompletedModelsByTurnID.removeValue(forKey: turnID) {
                    self.storePendingCodexCompletedModels(completedModels, turnID: turnID, in: &state)
                }
            } else {
                state.requestSourcesByTurnID[turnID] = retainedSources
                state.turns[turnID] = retainedSources.max { $0.key < $1.key }?.value
            }
        }

        didPrune = self.pruneDeletedCodexCompletedModels(
            retainedRowIDs: retainedRowIDs,
            from: &state.priorityCompletedModelsByTurnID) || didPrune
        didPrune = self.pruneDeletedCodexCompletedModels(
            retainedRowIDs: retainedRowIDs,
            from: &state.completedModelsByTurnID) || didPrune
        self.compactCodexPendingCompletionOrderPrefix(in: &state)
        state.completedTurnIDInsertionOrder.removeAll { state.completedModelsByTurnID[$0] == nil }
        return didPrune
    }

    private static func pruneDeletedCodexCompletedModels(
        retainedRowIDs: Set<Int64>,
        from modelsByTurnID: inout [String: [Int64: String]]) -> Bool
    {
        var didPrune = false
        for (turnID, modelsByRowID) in modelsByTurnID {
            let retainedModels = modelsByRowID.filter { retainedRowIDs.contains($0.key) }
            guard retainedModels.count != modelsByRowID.count else { continue }
            didPrune = true
            if retainedModels.isEmpty {
                modelsByTurnID.removeValue(forKey: turnID)
            } else {
                modelsByTurnID[turnID] = retainedModels
            }
        }
        return didPrune
    }

    private static func retainedCodexPrioritySourceRowIDs(
        _ db: OpaquePointer?,
        state: CodexPriorityTurnsMemoState) -> Set<Int64>?
    {
        var requestSources: [Int64: CodexPriorityTurnMetadata] = [:]
        for sources in state.requestSourcesByTurnID.values {
            for (rowID, source) in sources {
                if let existing = requestSources[rowID], existing != source { return nil }
                requestSources[rowID] = source
            }
        }
        var completedSources: [Int64: (turnID: String, model: String)] = [:]
        let completionMaps = [state.priorityCompletedModelsByTurnID, state.completedModelsByTurnID]
        for modelsByTurnID in completionMaps {
            for (turnID, modelsByRowID) in modelsByTurnID {
                for (rowID, model) in modelsByRowID {
                    if let existing = completedSources[rowID],
                       existing.turnID != turnID || existing.model != model
                    {
                        return nil
                    }
                    completedSources[rowID] = (turnID, model)
                }
            }
        }
        guard requestSources.keys.allSatisfy({ completedSources[$0] == nil }) else { return nil }
        let rowIDs = Array(Set(requestSources.keys).union(completedSources.keys))
        guard !rowIDs.isEmpty else { return [] }

        var retained: Set<Int64> = []
        let chunkSize = 500
        for start in stride(from: 0, to: rowIDs.count, by: chunkSize) {
            let end = min(start + chunkSize, rowIDs.count)
            let chunk = rowIDs[start..<end]
            let placeholders = Array(repeating: "?", count: chunk.count).joined(separator: ",")
            let query = "select rowid, ts, feedback_log_body from logs where rowid in (\(placeholders))"
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
            defer { sqlite3_finalize(stmt) }
            for (offset, rowID) in chunk.enumerated() {
                sqlite3_bind_int64(stmt, Int32(offset + 1), rowID)
            }
            while true {
                let stepResult = sqlite3_step(stmt)
                if stepResult == SQLITE_DONE {
                    break
                }
                guard stepResult == SQLITE_ROW else { return nil }
                let rowID = sqlite3_column_int64(stmt, 0)
                guard let body = self.text(stmt: stmt, index: 2) else { return nil }
                if let expected = requestSources[rowID] {
                    let timestamp = self.timestamp(stmt: stmt, index: 1)
                    guard self.parseCodexPriorityTraceRow(timestamp: timestamp, body: body) == expected else {
                        return nil
                    }
                } else if let expected = completedSources[rowID] {
                    guard let parsed = self.parseCodexCompletedTraceRow(body: body),
                          parsed.turnID == expected.turnID,
                          parsed.model == expected.model
                    else { return nil }
                } else {
                    return nil
                }
                retained.insert(rowID)
            }
        }
        return retained
    }

    private static func storePendingCodexCompletedModels(
        _ completedModels: [Int64: String],
        turnID: String,
        in state: inout CodexPriorityTurnsMemoState)
    {
        if state.completedModelsByTurnID[turnID] == nil {
            state.completedTurnIDInsertionOrder.append(turnID)
            let retainedCount = state.completedTurnIDInsertionOrder.count
                - state.completedTurnIDInsertionOrderStartIndex
            if retainedCount > self.codexPriorityCompletedModelRetentionLimit {
                let evicted = state.completedTurnIDInsertionOrder[
                    state.completedTurnIDInsertionOrderStartIndex,
                ]
                state.completedTurnIDInsertionOrderStartIndex += 1
                state.completedModelsByTurnID.removeValue(forKey: evicted)
                if state.completedTurnIDInsertionOrderStartIndex
                    >= self.codexPriorityCompletedModelRetentionLimit
                {
                    self.compactCodexPendingCompletionOrderPrefix(in: &state)
                }
            }
        }
        state.completedModelsByTurnID[turnID, default: [:]].merge(completedModels) { _, new in new }
    }

    private static func compactCodexPendingCompletionOrderPrefix(
        in state: inout CodexPriorityTurnsMemoState)
    {
        guard state.completedTurnIDInsertionOrderStartIndex > 0 else { return }
        state.completedTurnIDInsertionOrder.removeFirst(state.completedTurnIDInsertionOrderStartIndex)
        state.completedTurnIDInsertionOrderStartIndex = 0
    }

    private static func accumulateCodexPriorityTurns(
        _ db: OpaquePointer?,
        into state: inout CodexPriorityTurnsMemoState) -> Bool
    {
        let plan = self.codexPriorityAccumulationPlan(
            db,
            lastRowID: state.lastRowID,
            coverageSinceEpoch: state.coverageSinceEpoch)
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, plan.query, -1, &stmt, nil) == SQLITE_OK else {
            return false
        }
        defer { sqlite3_finalize(stmt) }
        if plan.usesTimestampIndex {
            sqlite3_bind_int64(stmt, 1, state.coverageSinceEpoch)
        } else {
            sqlite3_bind_int64(stmt, 1, state.lastRowID)
            sqlite3_bind_int64(stmt, 2, state.coverageSinceEpoch)
        }

        while true {
            let stepResult = sqlite3_step(stmt)
            guard stepResult == SQLITE_ROW else {
                return stepResult == SQLITE_DONE
            }
            let rowID = sqlite3_column_int64(stmt, 0)
            let timestamp = self.timestamp(stmt: stmt, index: 1)
            guard let body = self.text(stmt: stmt, index: 2) else { continue }
            if let completed = self.parseCodexCompletedTraceRow(body: body) {
                if state.turns[completed.turnID] != nil {
                    state.priorityCompletedModelsByTurnID[completed.turnID, default: [:]][rowID] = completed.model
                } else {
                    self.storePendingCodexCompletedModels(
                        [rowID: completed.model],
                        turnID: completed.turnID,
                        in: &state)
                }
                continue
            }
            guard let parsed = self.parseCodexPriorityTraceRow(timestamp: timestamp, body: body)
            else { continue }
            state.turns[parsed.turnID] = parsed
            state.requestSourcesByTurnID[parsed.turnID, default: [:]][rowID] = parsed
            if let completedModels = state.completedModelsByTurnID.removeValue(forKey: parsed.turnID) {
                self.compactCodexPendingCompletionOrderPrefix(in: &state)
                state.completedTurnIDInsertionOrder.removeAll { $0 == parsed.turnID }
                state.priorityCompletedModelsByTurnID[parsed.turnID] = completedModels
            }
        }
    }

    private static func codexPriorityAccumulationPlan(
        _ db: OpaquePointer?,
        lastRowID: Int64,
        coverageSinceEpoch: Int64) -> (query: String, usesTimestampIndex: Bool)
    {
        if lastRowID == 0,
           coverageSinceEpoch > 0,
           self.hasCodexLogsTimestampIndex(db)
        {
            return (
                """
                select rowid, ts, feedback_log_body
                from logs indexed by idx_logs_ts
                where ts >= ?
                  and (feedback_log_body like '%websocket request:%'
                       or feedback_log_body like '%response.completed%'
                       or feedback_log_body like '%service_tier: Some(Some("priority"))%')
                order by rowid
                """,
                true)
        }
        return (
            """
            select rowid, ts, feedback_log_body
            from logs
            where rowid > ? and ts >= ?
              and (feedback_log_body like '%websocket request:%'
                   or feedback_log_body like '%response.completed%'
                   or feedback_log_body like '%service_tier: Some(Some("priority"))%')
            order by rowid
            """,
            false)
    }

    private static func hasCodexLogsTimestampIndex(_ db: OpaquePointer?) -> Bool {
        var stmt: OpaquePointer?
        let query = """
        select 1
        from sqlite_master
        where type = 'index' and tbl_name = 'logs' and name = 'idx_logs_ts'
        limit 1
        """
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }
        return sqlite3_step(stmt) == SQLITE_ROW
    }
    #endif

    static func parseCodexPriorityTraceRow(timestamp: String?, body: String) -> CodexPriorityTurnMetadata? {
        guard let markerRange = body.range(of: self.requestMarker) else {
            return self.parseCodexPrioritySubmissionRow(timestamp: timestamp, body: body)
        }
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

    private static func parseCodexPrioritySubmissionRow(
        timestamp: String?,
        body: String) -> CodexPriorityTurnMetadata?
    {
        guard body.contains(#"service_tier: Some(Some("priority"))"#),
              let submissionRange = body.range(of: "Submission sub=Submission {")
        else { return nil }
        let submission = String(body[submissionRange.upperBound...])
        guard let turnID = self.quotedValue(named: "id", in: submission) else { return nil }

        return CodexPriorityTurnMetadata(
            threadID: self.value(
                named: "thread_id",
                in: String(body[..<submissionRange.lowerBound])),
            turnID: turnID,
            model: nil,
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
            !char.isWhitespace && char != "," && char != "]" && char != ")" && char != "}" && char != ":"
        }
        return value.isEmpty ? nil : String(value)
    }

    private static func quotedValue(named name: String, in text: String) -> String? {
        guard let range = text.range(of: "\(name): \"") else { return nil }
        let tail = text[range.upperBound...]
        guard let end = tail.firstIndex(of: "\"") else { return nil }
        let value = tail[..<end]
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
        if let since, dayKey < since {
            return false
        }
        if let until, dayKey > until {
            return false
        }
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
              let next = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()
                  .date(byAdding: .day, value: 1, to: date)
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
        components.calendar = CostUsageScanner.CostUsageDayRange.localGregorianCalendar()
        components.year = year
        components.month = month
        components.day = day
        return components.date
    }
}
