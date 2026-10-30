import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct CostUsageStoreHomeMigrationTests {
    @Test
    func `opening another home preserves legacy singleton ownership and rows in place`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let databaseURL = CostUsageStore.databaseURL(cacheRoot: env.cacheRoot)
        let path = env.codexSessionsRoot.appendingPathComponent("legacy.jsonl").path
        var metadata = CostUsageStoreMetadata.empty
        metadata.lastScanUnixMs = 42
        metadata.rootMtimes = [env.codexSessionsRoot.path: 1, env.codexArchivedSessionsRoot.path: 2]
        metadata.scanSinceDay = "2026-04-01"
        metadata.scanUntilDay = "2026-04-30"
        let discovery = CostUsageStoreDiscoveryState(
            roots: [env.codexSessionsRoot.path],
            directoryPaths: [],
            nextDirectoryIndex: 0,
            filePaths: [path],
            nextFileIndex: 1,
            filePathBySessionID: [:],
            missingSessionIDs: [],
            pendingSessionIDs: [],
            validationDirectoryIndex: 0,
            isComplete: true)
        let lookback = CostUsageStoreLookbackState(
            scanSinceDay: "2026-04-01",
            rootPaths: [env.codexSessionsRoot.path],
            nextDayByRoot: [:],
            completedRootPaths: [env.codexSessionsRoot.path],
            pendingFilePaths: [],
            legacyRecursivePendingRootPaths: [])
        try Self.seedLegacy(databaseURL, path: path, metadata: metadata, discovery: discovery, lookback: lookback)
        let inode = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.systemFileNumber] as? NSNumber

        let homeA = CodexHomeCostStoreScope.key(sessionsRoot: env.codexSessionsRoot)
        let homeB = CodexHomeCostStoreScope.key(sessionsRoot: env.root.appendingPathComponent("home-b/sessions"))
        let other = CostUsageStore(cacheRoot: env.cacheRoot, home: homeB)
        #expect(await other.readSnapshot().files.isEmpty)
        #expect(await other.fetchMetadata() == .empty)
        #expect(await other.rebuildCount == 0)

        let original = CostUsageStore(cacheRoot: env.cacheRoot, home: homeA)
        let snapshot = await original.readSnapshot()
        #expect(snapshot.metadata == metadata)
        #expect(snapshot.discoveryState == discovery)
        #expect(snapshot.lookbackState == lookback)
        #expect(snapshot.files.map(\.path) == [path])
        #expect(snapshot.tokenSnapshots.first?.total?.input == 303)
        #expect(snapshot.usageRows.first?.payload == Data("fixture-row".utf8))
        #expect(snapshot.dayAggregates.first?.inputTokens == 303)
        #expect(snapshot.fileDayAggregates.first?.aggregate.inputTokens == 303)
        #expect(await original.rebuildCount == 0)
        #expect(await original.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
        let after = try FileManager.default.attributesOfItem(atPath: databaseURL.path)[.systemFileNumber] as? NSNumber
        #expect(inode == after)
        let (fileID, _) = try await original.measureSQLWork { store in
            store.withDatabase(default: Int64(-1)) { try CostUsageStore.scalarInt($0, "SELECT id FROM files LIMIT 1") }
        }
        #expect(fileID == 7)
    }

    @Test
    func `legacy OpenCode rows retain their shared writer after a custom home scan`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let path = "opencode-sqlite:fixture"
        var metadata = CostUsageStoreMetadata.empty
        metadata.rootMtimes = [env.codexSessionsRoot.path: 1]
        try Self.seedLegacy(
            CostUsageStore.databaseURL(cacheRoot: env.cacheRoot),
            path: path,
            metadata: metadata,
            discovery: .init(
                roots: [],
                directoryPaths: [],
                nextDirectoryIndex: 0,
                filePaths: [],
                nextFileIndex: 0,
                filePathBySessionID: [:],
                missingSessionIDs: [],
                pendingSessionIDs: [],
                validationDirectoryIndex: 0,
                isComplete: true),
            lookback: .init(
                scanSinceDay: "2026-04-01",
                rootPaths: [],
                nextDayByRoot: [:],
                completedRootPaths: [],
                pendingFilePaths: [],
                legacyRecursivePendingRootPaths: []),
            source: .opencodeLocalHistory)
        let writer = CostUsageStore(cacheRoot: env.cacheRoot)
        let snapshot = await writer.readSnapshot()
        var file = try #require(snapshot.files.first)
        #expect(file.path == path)
        #expect(snapshot.dayAggregates.first?.inputTokens == 303)
        file.size = 2
        #expect(await writer.upsertFile(file))
        #expect(await writer.readSnapshot().files.first?.size == 2)
    }

    private static func seedLegacy(
        _ url: URL,
        path: String,
        metadata: CostUsageStoreMetadata,
        discovery: CostUsageStoreDiscoveryState,
        lookback: CostUsageStoreLookbackState,
        source: CostUsageStoreSource? = nil) throws
    {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        var raw: OpaquePointer?
        try #require(sqlite3_open(url.path, &raw) == SQLITE_OK)
        let database = try #require(raw)
        defer { sqlite3_close(database) }
        let fixture = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .appendingPathComponent("Fixtures/CostUsage/store-v3-schema.sql")
        try CostUsageStore.execute(database, "PRAGMA auto_vacuum=INCREMENTAL; VACUUM;")
        try CostUsageStore.execute(database, String(contentsOf: fixture, encoding: .utf8))
        let legacyHash = "4e1358d00a4a47b5"
        let version = CostUsageStore.combinedSchemaVersion(base: 3, parserHash: legacyHash)
        try CostUsageStore.execute(database, "PRAGMA user_version = \(version)")
        let parser = try CostUsageStore.prepare(database, "INSERT INTO meta VALUES ('parser_hash', ?)")
        defer { sqlite3_finalize(parser) }
        CostUsageStore.bind(legacyHash, to: parser, at: 1)
        try CostUsageStore.stepDone(parser, database: database)
        let encoder = JSONEncoder()
        for (table, payload) in try [
            ("scan_metadata", encoder.encode(metadata)),
            ("discovery_state", encoder.encode(discovery)),
            ("lookback_state", encoder.encode(lookback)),
        ] {
            let statement = try CostUsageStore.prepare(database, "INSERT INTO \(table) VALUES (1, ?)")
            defer { sqlite3_finalize(statement) }
            CostUsageStore.bind(payload, to: statement, at: 1)
            try CostUsageStore.stepDone(statement, database: database)
        }
        let file = try CostUsageStore.prepare(database, """
        INSERT INTO files (id, path, mtime_ms, size, scan_state, scan_complete, updated_at_ms)
        VALUES (7, ?, 1, 1, ?, 1, 1)
        """)
        defer { sqlite3_finalize(file) }
        CostUsageStore.bind(path, to: file, at: 1)
        try CostUsageStore.bind(
            encoder.encode(CostUsageStoreScanState(source: source, isComplete: true)),
            to: file,
            at: 2)
        try CostUsageStore.stepDone(file, database: database)
        try CostUsageStore.execute(database, """
        INSERT INTO token_snapshots (file_id, event_index, timestamp, total_input, total_cached, total_output)
        VALUES (7, 0, '2026-04-08T12:00:00Z', 303, 0, 0);
        INSERT INTO usage_rows VALUES (7, 0, CAST('fixture-row' AS BLOB));
        INSERT INTO day_aggregates VALUES (
            '2026-04-08', 'fixture-model', 303, 0, 0, 0, 1, 0, 303, 0, 0, 0, 0, 0, 303, 0);
        INSERT INTO file_day_aggregates SELECT 7, * FROM day_aggregates;
        """)
    }
}
