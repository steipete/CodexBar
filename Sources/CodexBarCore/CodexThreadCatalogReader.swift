import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CodexThreadCatalog: Sendable {
    static let empty = CodexThreadCatalog(entriesById: [:], entriesByRolloutPath: [:], fingerprint: nil)

    let entriesById: [String: CodexThreadCatalogEntry]
    let entriesByRolloutPath: [String: CodexThreadCatalogEntry]
    let fingerprint: String?

    func entry(sessionId: String?, rolloutPath: String) -> CodexThreadCatalogEntry? {
        if let sessionId, let entry = self.entriesById[sessionId] {
            return entry
        }
        return self.entriesByRolloutPath[URL(fileURLWithPath: rolloutPath).standardizedFileURL.path]
    }
}

enum CodexThreadCatalogCompleteness: Sendable, Equatable {
    case complete
    case unavailable(CodexThreadCatalogFailure)
}

enum CodexThreadCatalogFailure: Sendable, Equatable {
    case missing
    case locked
    case corrupt
    case incompatible
    case unreadable
}

struct CodexThreadCatalogReadResult: Sendable {
    let catalog: CodexThreadCatalog
    let databaseURL: URL
    let completeness: CodexThreadCatalogCompleteness

    var isComplete: Bool {
        if case .complete = self.completeness { return true }
        return false
    }
}

struct CodexThreadCatalogEntry: Sendable, Equatable {
    let id: String
    let rolloutPath: String
    let cwd: String?
    let title: String?
    let preview: String?
    let modelProvider: String?
    let model: String?
    let reasoningEffort: String?
    let createdAtUnixMs: Int64?
    let updatedAtUnixMs: Int64?
    let archived: Bool
}

enum CodexThreadCatalogReader {
    static func load(options: CostUsageScanner.Options) -> CodexThreadCatalog {
        self.loadResult(options: options).catalog
    }

    static func loadResult(options: CostUsageScanner.Options) -> CodexThreadCatalogReadResult {
        let url = self.databaseURL(options: options)
        guard FileManager.default.fileExists(atPath: url.path) else {
            return CodexThreadCatalogReadResult(
                catalog: .empty,
                databaseURL: url,
                completeness: .unavailable(.missing))
        }

        #if canImport(SQLite3) || canImport(CSQLite3)
        var db: OpaquePointer?
        let openResult = sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil)
        guard openResult == SQLITE_OK else {
            let failure: CodexThreadCatalogFailure = openResult == SQLITE_BUSY || openResult == SQLITE_LOCKED
                ? .locked
                : openResult == SQLITE_CORRUPT || openResult == SQLITE_NOTADB ? .corrupt : .unreadable
            sqlite3_close(db)
            return CodexThreadCatalogReadResult(
                catalog: .empty,
                databaseURL: url,
                completeness: .unavailable(failure))
        }
        defer { sqlite3_close(db) }
        sqlite3_busy_timeout(db, 250)
        sqlite3_exec(db, "PRAGMA query_only = ON", nil, nil, nil)

        guard let hasThreadsTable = self.hasThreadsTable(db) else {
            let code = sqlite3_errcode(db)
            let failure: CodexThreadCatalogFailure = code == SQLITE_BUSY || code == SQLITE_LOCKED
                ? .locked
                : code == SQLITE_CORRUPT || code == SQLITE_NOTADB ? .corrupt : .unreadable
            return CodexThreadCatalogReadResult(
                catalog: .empty,
                databaseURL: url,
                completeness: .unavailable(failure))
        }
        guard hasThreadsTable else {
            return CodexThreadCatalogReadResult(
                catalog: .empty,
                databaseURL: url,
                completeness: .unavailable(.incompatible))
        }
        guard let entries = self.readEntries(db) else {
            let code = sqlite3_errcode(db)
            let failure: CodexThreadCatalogFailure = code == SQLITE_BUSY || code == SQLITE_LOCKED
                ? .locked
                : code == SQLITE_CORRUPT || code == SQLITE_NOTADB ? .corrupt : .unreadable
            return CodexThreadCatalogReadResult(
                catalog: .empty,
                databaseURL: url,
                completeness: .unavailable(failure))
        }
        let fingerprint = self.fingerprint(databaseURL: url, db: db)
        let catalog = CodexThreadCatalog(
            entriesById: Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) }),
            entriesByRolloutPath: Dictionary(uniqueKeysWithValues: entries.map {
                (URL(fileURLWithPath: $0.rolloutPath).standardizedFileURL.path, $0)
            }),
            fingerprint: fingerprint)
        return CodexThreadCatalogReadResult(catalog: catalog, databaseURL: url, completeness: .complete)
        #else
        return CodexThreadCatalogReadResult(
            catalog: .empty,
            databaseURL: url,
            completeness: .unavailable(.incompatible))
        #endif
    }

    private static func databaseURL(options: CostUsageScanner.Options) -> URL {
        CodexLocalDataScope.resolve(options: options).stateDatabaseURL
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func hasThreadsTable(_ db: OpaquePointer?) -> Bool? {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT 1 FROM sqlite_master WHERE type = 'table' AND name = 'threads' LIMIT 1",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { return nil }
        defer { sqlite3_finalize(stmt) }
        switch sqlite3_step(stmt) {
        case SQLITE_ROW:
            return true
        case SQLITE_DONE:
            return false
        default:
            return nil
        }
    }

    private static func readEntries(_ db: OpaquePointer?) -> [CodexThreadCatalogEntry]? {
        let query = """
        SELECT id, rollout_path, cwd, title, preview, model_provider, model, reasoning_effort,
               created_at_ms, updated_at_ms, created_at, updated_at, archived
        FROM threads
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, query, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        var entries: [CodexThreadCatalogEntry] = []
        while true {
            let step = sqlite3_step(stmt)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return nil }
            guard let id = self.text(stmt, 0),
                  let rolloutPath = self.text(stmt, 1)
            else { continue }
            entries.append(CodexThreadCatalogEntry(
                id: id,
                rolloutPath: rolloutPath,
                cwd: self.text(stmt, 2),
                title: self.nonEmptyText(stmt, 3),
                preview: self.nonEmptyText(stmt, 4),
                modelProvider: self.nonEmptyText(stmt, 5),
                model: self.nonEmptyText(stmt, 6),
                reasoningEffort: self.nonEmptyText(stmt, 7),
                createdAtUnixMs: self.integer(stmt, preferredColumn: 8, fallbackColumn: 10),
                updatedAtUnixMs: self.integer(stmt, preferredColumn: 9, fallbackColumn: 11),
                archived: sqlite3_column_int(stmt, 12) != 0))
        }
        return entries
    }

    private static func fingerprint(databaseURL: URL, db: OpaquePointer?) -> String {
        let attributes = (try? FileManager.default.attributesOfItem(atPath: databaseURL.path)) ?? [:]
        let size = (attributes[.size] as? NSNumber)?.int64Value ?? -1
        let mtime = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let walURL = URL(fileURLWithPath: databaseURL.path + "-wal")
        let walAttributes = (try? FileManager.default.attributesOfItem(atPath: walURL.path)) ?? [:]
        let walSize = (walAttributes[.size] as? NSNumber)?.int64Value ?? -1
        let walMtime = (walAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        let summary = self.catalogSummary(db)
        return [
            databaseURL.standardizedFileURL.path,
            "size=\(size)",
            "mtime=\(Int64(mtime * 1000))",
            "walSize=\(walSize)",
            "walMtime=\(Int64(walMtime * 1000))",
            "rows=\(summary.rowCount)",
            "maxUpdated=\(summary.maxUpdatedAtUnixMs ?? -1)",
        ].joined(separator: "|")
    }

    private static func catalogSummary(_ db: OpaquePointer?) -> (rowCount: Int64, maxUpdatedAtUnixMs: Int64?) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(
            db,
            "SELECT COUNT(*), MAX(CASE WHEN updated_at_ms IS NOT NULL THEN updated_at_ms " +
                "ELSE updated_at * 1000 END) FROM threads",
            -1,
            &stmt,
            nil) == SQLITE_OK
        else { return (0, nil) }
        defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { return (0, nil) }
        let rowCount = sqlite3_column_int64(stmt, 0)
        let maxUpdated = sqlite3_column_type(stmt, 1) == SQLITE_NULL ? nil : sqlite3_column_int64(stmt, 1)
        return (rowCount, maxUpdated)
    }

    private static func nonEmptyText(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        self.text(stmt, index)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func text(_ stmt: OpaquePointer?, _ index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
              let cString = sqlite3_column_text(stmt, index)
        else { return nil }
        return String(cString: cString)
    }

    private static func integer(
        _ stmt: OpaquePointer?,
        preferredColumn: Int32,
        fallbackColumn: Int32) -> Int64?
    {
        if sqlite3_column_type(stmt, preferredColumn) != SQLITE_NULL {
            return sqlite3_column_int64(stmt, preferredColumn)
        }
        if sqlite3_column_type(stmt, fallbackColumn) != SQLITE_NULL {
            return sqlite3_column_int64(stmt, fallbackColumn) * 1000
        }
        return nil
    }
    #endif
}

extension String {
    fileprivate var nilIfEmpty: String? {
        self.isEmpty ? nil : self
    }
}
