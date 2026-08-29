import Foundation
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

#if canImport(SQLite3) || canImport(CSQLite3)
extension AntigravityLocalReader {
    struct SupportedTables {
        var hasGenMetadata = false
        var hasSteps = false
    }

    static func supportedSQLiteTables(_ database: OpaquePointer, budget: Budget) throws -> SupportedTables {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let query = "SELECT name, type, rootpage FROM main.sqlite_master LIMIT ?"
        guard sqlite3_prepare_v2(database, query, -1, &statement, nil) == SQLITE_OK,
              let statement else { return SupportedTables() }
        sqlite3_bind_int64(statement, 1, Int64(min(budget.limits.schemaEntries, 128) + 1))
        var entries = 0
        var tables = SupportedTables()
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            // A SQLITE_CORRUPT/SQLITE_IOERR termination is not an exhaustive listing: fail closed.
            guard step == SQLITE_ROW else { return SupportedTables() }
            entries += 1
            budget.statistics.schemaEntries += 1
            guard entries <= budget.limits.schemaEntries else { throw ScanFailure.exhausted }
            let name = try self.schemaText(statement, column: 0, budget: budget)
            let type = try self.schemaText(statement, column: 1, budget: budget)
            if name?.lowercased() == "gen_metadata" {
                if type == "table", sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                   sqlite3_column_int64(statement, 2) > 0,
                   try self.hasStoredSQLiteColumns(database, budget: budget)
                {
                    tables.hasGenMetadata = true
                }
            } else if name?.lowercased() == "steps" {
                if type == "table", sqlite3_column_type(statement, 2) == SQLITE_INTEGER,
                   sqlite3_column_int64(statement, 2) > 0,
                   try self.hasStoredStepsColumns(database, budget: budget)
                {
                    tables.hasSteps = true
                }
            }
        }
        return tables
    }

    static func hasSupportedSQLiteTable(_ database: OpaquePointer, budget: Budget) throws -> Bool {
        try self.supportedSQLiteTables(database, budget: budget).hasGenMetadata
    }

    private static func hasStoredStepsColumns(_ database: OpaquePointer, budget: Budget) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA main.table_xinfo('steps')", -1, &statement, nil) == SQLITE_OK,
              let statement, sqlite3_column_count(statement) >= 7 else { return false }
        var columns = Set<String>()
        var count = 0
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return columns.isSuperset(of: ["metadata"]) }
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

    private static func hasStoredSQLiteColumns(_ database: OpaquePointer, budget: Budget) throws -> Bool {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        // table_info omits generated columns. An unknown table_xinfo pragma returns no columns: fail closed.
        guard sqlite3_prepare_v2(database, "PRAGMA main.table_xinfo('gen_metadata')", -1, &statement, nil) == SQLITE_OK,
              let statement, sqlite3_column_count(statement) >= 7 else { return false }
        var columns = Set<String>()
        var count = 0
        while true {
            try budget.check()
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { return columns.isSuperset(of: ["idx", "data"]) }
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
