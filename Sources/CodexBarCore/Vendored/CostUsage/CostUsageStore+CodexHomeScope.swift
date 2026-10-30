import Foundation

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

enum CodexHomeCostStoreScope {
    static func key(options: CostUsageScanner.Options = .init()) -> String {
        self.key(sessionsRoot: CostUsageScanner.codexSessionsRoots(options: options)[0])
    }

    static func key(sessionsRoot: URL) -> String {
        CostUsageScanner.codexPathKey(sessionsRoot.resolvingSymlinksInPath().standardizedFileURL)
    }
}

extension CostUsageStore {
    /// The old singleton belongs to its recorded home, not the first new profile opening the store.
    func migrateHomeScope(_ database: OpaquePointer) throws {
        let metadata = try Self.readSingleton(
            CostUsageStoreMetadata.self, database: database, table: "scan_metadata", home: nil)
        let roots = (metadata?.rootMtimes?.keys.map { URL(fileURLWithPath: $0) } ?? [])
            .sorted { $0.path < $1.path }
        let primary = roots.first(where: { $0.lastPathComponent == "sessions" }) ?? roots.first
        let home = primary.map { CodexHomeCostStoreScope.key(sessionsRoot: $0) }
            ?? CodexHomeCostStoreScope.key()

        for table in ["scan_metadata", "discovery_state", "lookback_state"] {
            try Self.execute(database, "ALTER TABLE \(table) RENAME TO legacy_\(table)")
            try Self.execute(database, """
            CREATE TABLE \(table) (
                home TEXT NOT NULL,
                id INTEGER NOT NULL CHECK (id = 1),
                payload BLOB NOT NULL,
                PRIMARY KEY(home, id)
            )
            """)
            let copy = try Self.prepare(database, "INSERT INTO \(table) SELECT ?, id, payload FROM legacy_\(table)")
            Self.bind(home, to: copy, at: 1)
            defer { sqlite3_finalize(copy) }
            try Self.stepDone(copy, database: database)
            try Self.execute(database, "DROP TABLE legacy_\(table)")
        }

        try Self.execute(database, "ALTER TABLE files ADD COLUMN home TEXT NOT NULL DEFAULT ''")
        let files = try Self.prepare(database, "UPDATE files SET home = ?")
        defer { sqlite3_finalize(files) }
        Self.bind(home, to: files, at: 1)
        try Self.stepDone(files, database: database)
        try Self.execute(database, "CREATE INDEX files_home_path_idx ON files(home, path)")

        // Aggregates are small; token, request, buffer and checkpoint rows keep their existing file IDs.
        try Self.execute(database, "ALTER TABLE day_aggregates RENAME TO legacy_day_aggregates")
        try Self.execute(database, Self.dayAggregatesSchemaSQL)
        let aggregates = try Self.prepare(database, "INSERT INTO day_aggregates SELECT ?, * FROM legacy_day_aggregates")
        defer { sqlite3_finalize(aggregates) }
        Self.bind(home, to: aggregates, at: 1)
        try Self.stepDone(aggregates, database: database)
        try Self.execute(database, "DROP TABLE legacy_day_aggregates")
    }
}
