import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
extension AntigravityLocalReader {
    static func hasSupportedSQLiteTable(_ database: OpaquePointer, budget: Budget) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // sqlite_master works on older SQLite versions too. Virtual tables and views have no root b-tree page.
        let query = "SELECT name, type, rootpage FROM main.sqlite_master LIMIT ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return false }
        sqlite3_bind_int64(statement, 1, Int64(min(budget.limits.schemaEntries, 128) + 1))
        var entries = 0
        var foundGenMetadata = false
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else { return false }
            entries += 1
            budget.statistics.schemaEntries += 1
            guard entries <= budget.limits.schemaEntries else { throw ScanFailure.exhausted }
            guard let name = try self.schemaText(statement, column: 0, budget: budget)?.lowercased(),
                  let type = try self.schemaText(statement, column: 1, budget: budget)
            else { continue }
            let isOrdinaryTable = type == "table" && sqlite3_column_type(statement, 2) == SQLITE_INTEGER
                && sqlite3_column_int64(statement, 2) > 0
            if name == "gen_metadata" {
                guard isOrdinaryTable else { return false }
                guard try self.hasStoredSQLiteColumns(
                    database, table: "gen_metadata", requiredColumns: ["idx", "data"], budget: budget)
                else { return false }
                foundGenMetadata = true
            } else if name == "steps" {
                guard isOrdinaryTable else { return false }
                guard try self.hasStoredSQLiteColumns(
                    database, table: "steps", requiredColumns: ["idx", "step_type", "metadata"], budget: budget)
                else { return false }
            }
        }
        return foundGenMetadata
    }

    private static func hasStoredSQLiteColumns(
        _ database: OpaquePointer,
        table: String,
        requiredColumns: Set<String>,
        budget: Budget) throws -> Bool
    {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // table_info omits generated columns. An unknown table_xinfo pragma returns no columns: fail closed.
        let sql: String = switch table {
        case "gen_metadata": "PRAGMA main.table_xinfo('gen_metadata')"
        case "steps": "PRAGMA main.table_xinfo('steps')"
        default: return false
        }
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement, sqlite3_column_count(statement) >= 7 else { return false }
        var columns = Set<String>()
        var count = 0
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return columns.isSuperset(of: requiredColumns) }
            guard step == SQLITE_ROW else { return false }
            count += 1
            budget.statistics.schemaColumns += 1
            guard count <= min(budget.limits.schemaColumns, 64) else { throw ScanFailure.exhausted }
            guard sqlite3_column_type(statement, 6) == SQLITE_INTEGER,
                  sqlite3_column_int(statement, 6) == 0 else { return false }
            guard let name = try self.schemaText(statement, column: 1, budget: budget) else { return false }
            _ = try self.schemaText(statement, column: 2, budget: budget)
            _ = try self.schemaText(statement, column: 4, budget: budget)
            columns.insert(name.lowercased())
        }
    }

    private static func schemaText(_ statement: OpaquePointer, column: Int32, budget: Budget) throws -> String? {
        guard sqlite3_column_type(statement, column) == SQLITE_TEXT,
              let pointer = sqlite3_column_text(statement, column) else { return nil }
        let count = Int(sqlite3_column_bytes(statement, column))
        try budget.chargeSchemaBytes(count)
        return String(bytes: UnsafeBufferPointer(start: pointer, count: count), encoding: .utf8)
    }

    struct SQLitePayload {
        let byteCount: Int
        private let pointer: UnsafeRawPointer?

        init(statement: OpaquePointer) {
            let isBlob = sqlite3_column_type(statement, 2) == SQLITE_BLOB
            self.pointer = isBlob ? sqlite3_column_blob(statement, 2) : nil
            self.byteCount = isBlob ? Int(sqlite3_column_bytes(statement, 2)) : 0
        }

        func copy(declaredCount: Int, limit: Int) -> [UInt8]? {
            guard self.byteCount > 0, self.byteCount == declaredCount, self.byteCount <= limit,
                  let pointer = self.pointer else { return nil }
            // Both pointer and count belong to column 2. Never use a separate SQL expression as a buffer length.
            return Array(UnsafeBufferPointer(start: pointer.assumingMemoryBound(to: UInt8.self), count: self.byteCount))
        }
    }
}
#endif
