import Foundation
#if canImport(SQLite3)
import SQLite3

extension CodexCombinedPriorityEvidence {
    /// The native trace resolver keys completions by turn ID. Audit their original ownership before
    /// using a completed model override in a multi-host report; never expose trace bodies in errors.
    static func validateCompletions(
        url: URL,
        models: [Int64: String],
        turn: Turn,
        session: String,
        requestModels: Set<String>) throws
    {
        guard !models.isEmpty else { return }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READONLY, nil)
        defer { if let opened { sqlite3_close(opened) } }
        guard result == SQLITE_OK, let database = opened else { throw CodexCombinedCostError.pricingEvidence }
        sqlite3_busy_timeout(database, 250)
        guard sqlite3_exec(database, "BEGIN", nil, nil, nil) == SQLITE_OK else {
            throw CodexCombinedCostError.pricingEvidence
        }
        defer { sqlite3_exec(database, "ROLLBACK", nil, nil, nil) }
        var prepared: OpaquePointer?
        guard sqlite3_prepare_v2(
            database, "SELECT feedback_log_body FROM logs WHERE rowid = ?", -1, &prepared, nil) == SQLITE_OK,
            let statement = prepared else { throw CodexCombinedCostError.pricingEvidence }
        defer { sqlite3_finalize(statement) }
        for (rowID, model) in models {
            sqlite3_reset(statement)
            sqlite3_bind_int64(statement, 1, rowID)
            guard sqlite3_step(statement) == SQLITE_ROW, let body = sqlite3_column_text(statement, 0),
                  let completed = CostUsageScanner.parseCodexCompletedTraceRow(body: String(cString: body)),
                  completed.turnID == turn.turnID, completed.model == model
            else { throw CodexCombinedCostError.pricingEvidence }
            if let thread = completed.threadID {
                guard thread == session else { throw CodexCombinedCostError.pricingEvidence }
            } else {
                // A threadless completion may confirm an already-owned model, but cannot introduce another one.
                guard requestModels == [model] else { throw CodexCombinedCostError.pricingEvidence }
            }
        }
    }
}
#endif
