import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [2, 16])
    func `unchanged scan receipt skips persisted histories`(fileCount: Int) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: fileCount == 2 ? 4 : 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        let before = await fixture.store.persistenceWriteMetricsForTesting()
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.unloadedTokenSnapshotPaths.count == fileCount)
        #expect(loaded.cache.files.values.allSatisfy { $0.codexTokenSnapshots == nil })
        #expect(loaded.cache.files.values.allSatisfy { $0.codexRows != nil })
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 1)
        var refreshed = loaded.cache
        refreshed.lastScanUnixMs += 1000
        let saved = fixture.save(refreshed, load: loaded)
        let after = await fixture.store.persistenceWriteMetricsForTesting()
        let work = recorder.snapshot()
        #expect(!saved.catchUpRequired)
        #expect(work.fullSnapshotReads == 0)
        #expect(work.scannerSnapshotReads == 1)
        #expect(work.cacheConversions == 1)
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
        #expect(work.usageRows == fixture.rowCount)
        #expect(work.aggregateGroupingRowVisits == 0)
        #expect(after.rows - before.rows == 1)
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
        var expected = fixture.canonical
        expected.lastScanUnixMs = refreshed.lastScanUnixMs
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
        print("[lazy-baseline-proof] files=\(fileCount) rows=\(fixture.rowCount) " +
            "scanner_snapshots=\(work.scannerSnapshotReads) decodes=\(work.usageRowDecodeAttempts) " +
            "freshness_writes=\(after.rows - before.rows) grouping_visits=\(work.aggregateGroupingRowVisits)")
    }

    @Test
    func `external commit inside initial read never blesses an older snapshot`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        CostUsageStore.codexBaselineReadCheckpointForTesting = (fixture.store.databaseURL, {
            try writer.execute("UPDATE files SET parsed_bytes = 999")
        })
        defer { CostUsageStore.codexBaselineReadCheckpointForTesting = nil }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.cache.files.isEmpty)
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
        #expect(fixture.save(fixture.canonical, load: loaded).catchUpRequired)
        #expect(await fixture.store.readSnapshot().files.allSatisfy { $0.parsedBytes == 999 })
        #expect(await fixture.store.rebuildCount == 0)
        CostUsageStore.codexBaselineReadCheckpointForTesting = nil
        let retry = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { retry.release() }
        #expect(retry.cache.files.values.allSatisfy { $0.parsedBytes == 999 })
    }

    @Test
    func `schema change during initial read preserves the concurrent database`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        CostUsageStore.codexBaselineReadCheckpointForTesting = (fixture.store.databaseURL, {
            try writer.execute("DROP TABLE meta")
        })
        defer { CostUsageStore.codexBaselineReadCheckpointForTesting = nil }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.cache.files.isEmpty)
        #expect(fixture.save(fixture.canonical, load: loaded).catchUpRequired)
        #expect(await fixture.store.rebuildCount == 0)
        #expect(await fixture.store.readSnapshot().files.count == fixture.fileCount)
    }

    @Test
    func `failed read transaction cannot produce a reusable receipt`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        CostUsageStore.codexBaselineReadCheckpointForTesting = (fixture.store.databaseURL, {
            throw CostUsageStore.StoreError.sqlite(SQLITE_BUSY)
        })
        defer { CostUsageStore.codexBaselineReadCheckpointForTesting = nil }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.cache.files.isEmpty)
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
        #expect(fixture.save(fixture.canonical, load: loaded).catchUpRequired)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == fixture.canonical)
        #expect(await fixture.store.rebuildCount == 0)
    }

    @Test
    func `failed retention cannot bless unchanged freshness`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        try writer.execute("""
        CREATE TRIGGER reject_retention BEFORE UPDATE ON scan_metadata
        BEGIN SELECT RAISE(ABORT, 'synthetic retention failure'); END
        """)
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let saved = fixture.store.syncSaveCodexCache(
            loaded.cache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
            fileBudgetBytes: 1,
            skipIdenticalContent: true,
            receipt: loaded.receipt)
        #expect(saved.catchUpRequired)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == fixture.canonical)
        #expect(await fixture.store.rebuildCount == 0)
    }

    @Test(arguments: [false, true])
    func `external commit before writer lock preserves current content`(changed: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var incoming = loaded.cache
        incoming.lastScanUnixMs += 1000
        if changed {
            incoming.codexProjectMetadataVersion = 999
        }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        CostUsageStore.identicalContentPreLockCheckpointForTesting = (fixture.store.databaseURL, {
            do {
                try writer.execute("UPDATE files SET parsed_bytes = 777")
            } catch {
                Issue.record(error)
            }
        })
        defer { CostUsageStore.identicalContentPreLockCheckpointForTesting = nil }
        #expect(fixture.save(incoming, load: loaded).catchUpRequired)
        #expect(await fixture.store.readSnapshot().files.allSatisfy { $0.parsedBytes == 777 })
        #expect(await fixture.store.fetchMetadata().lastScanUnixMs == fixture.canonical.lastScanUnixMs)
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
    }

    @Test(arguments: ["metadata", "retention", "rows", "schema", "failure"])
    func `same connection changes invalidate a receipt`(mutation: String) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let before = await fixture.store.baselineDataVersionForTesting()
        switch mutation {
        case "metadata":
            var metadata = await fixture.store.fetchMetadata()
            metadata.pricingKey = "new-pricing"
            #expect(await fixture.store.setMetadata(metadata))
        case "retention":
            _ = await fixture.store.retainDayWindow(
                sinceDay: "2026-08-02",
                untilDay: "2026-08-02",
                calendar: fixture.calendar)
        case "rows":
            #expect(try await fixture.store.deleteFile(path: #require(loaded.cache.files.keys.first)))
        case "schema":
            #expect(await fixture.store.baselineExecuteForTesting("CREATE TABLE receipt_schema_probe (id INTEGER)"))
        default:
            #expect(await fixture.store.baselineExecuteForTesting(
                "INSERT INTO files(path, mtime_ms, size, scan_state, scan_complete, updated_at_ms) " +
                    "VALUES (NULL, 0, 0, X'00', 1, 0)") == false)
        }
        #expect(await fixture.store.baselineDataVersionForTesting() == before)
        let current = await fixture.store.readSnapshot()
        #expect(fixture.save(loaded.cache, load: loaded).catchUpRequired)
        #expect(await fixture.store.readSnapshot() == current)
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
    }

    @Test
    func `retention under tight protected budgets rechecks fresh state under lock`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var incoming = loaded.cache
        incoming.lastScanUnixMs += 1000
        let saved = fixture.store.syncSaveCodexCache(
            incoming,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
            rowBudget: 1,
            fileBudgetBytes: 1,
            unloadedTokenSnapshotPaths: loaded.unloadedTokenSnapshotPaths,
            skipIdenticalContent: true,
            receipt: loaded.receipt)
        #expect(!saved.catchUpRequired)
        #expect(saved.rowCount == 2)
        #expect(saved.fileBytes > 1)
        var expected = fixture.canonical
        expected.lastScanUnixMs = incoming.lastScanUnixMs
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
    }

    @Test
    func `retention pruning cannot resurrect removed files from the decoded baseline`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let stalePath = try #require(fixture.canonical.files.keys.min())
        var cache = fixture.canonical
        cache.files[stalePath]?.mtimeUnixMs = 0
        cache.files[stalePath]?.days = ["2025-01-01": [ReadWorkFixture.model: [40, 8, 12]]]
        #expect(!fixture.save(cache).catchUpRequired)
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let saved = fixture.store.syncSaveCodexCache(
            loaded.cache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
            rowBudget: 1,
            skipIdenticalContent: true,
            receipt: loaded.receipt)
        #expect(saved.catchUpRequired)
        #expect(saved.deletedRows == 1)
        #expect(await fixture.store.readSnapshot().files.count == 1)
        #expect(await fixture.store.fetchFile(path: stalePath) == nil)
    }

    @Test
    func `superseded foreign consumed and released receipts cannot overwrite newer data`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        let second = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { first.release(); second.release() }
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 1)
        #expect(fixture.save(first.cache, load: first).catchUpRequired)
        let other = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
        #expect(other.syncSaveCodexCache(
            second.cache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
            receipt: second.receipt).catchUpRequired)
        var incoming = second.cache
        incoming.lastScanUnixMs += 1000
        #expect(!fixture.save(incoming, load: second).catchUpRequired)
        #expect(fixture.save(first.cache, load: second).catchUpRequired)
        var expected = fixture.canonical
        expected.lastScanUnixMs = incoming.lastScanUnixMs
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == expected)
        for _ in 0..<4 {
            let abandoned = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            #expect(await fixture.store.retainedCodexBaselineCountForTesting == 1)
            abandoned.release()
            #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
            #expect(fixture.save(abandoned.cache, load: abandoned).catchUpRequired)
        }
    }

    @Test
    func `dropping an abandoned receipt releases the actor owned baseline`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        await withCheckedContinuation { continuation in
            Task {
                await fixture.store.observeBaselineReleaseForTesting { continuation.resume() }
                let abandoned = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
                #expect(await fixture.store.retainedCodexBaselineCountForTesting == 1)
                #expect(abandoned.unloadedTokenSnapshotPaths.count == fixture.fileCount)
            }
        }
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
    }

    @Test(arguments: [false, true])
    func `connection reopen and legacy recovery reject old receipts`(recover: Bool) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        if recover {
            let legacy = fixture.store.databaseURL.deletingLastPathComponent().appendingPathComponent("codex-v11.json")
            try Data("synthetic legacy".utf8).write(to: legacy)
            #expect(await fixture.store.removeLegacyCodexArtifactIfPresent())
        } else {
            await fixture.store.closeConnectionForTesting()
        }
        let current = await fixture.store.readSnapshot()
        #expect(fixture.save(loaded.cache, load: loaded).catchUpRequired)
        #expect(await fixture.store.readSnapshot() == current)
        #expect(await fixture.store.rebuildCount == (recover ? 1 : 0))
    }

    @Test
    func `reuse validation never rebuilds a concurrently changed schema`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        CostUsageStore.identicalContentPreLockCheckpointForTesting = (fixture.store.databaseURL, {
            do { try writer.execute("DROP TABLE meta") } catch { Issue.record(error) }
        })
        defer { CostUsageStore.identicalContentPreLockCheckpointForTesting = nil }
        #expect(fixture.save(loaded.cache, load: loaded).catchUpRequired)
        #expect(await fixture.store.rebuildCount == 0)
        #expect(await fixture.store.readSnapshot().files.count == fixture.fileCount)
    }

    @Test(arguments: ["4a593b5d59c7bcf3", "7e293e8fc9e25700", "e0b0319de43e22d7"])
    func `schema adoption invalidates a predecessor connection receipt`(predecessorHash: String) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion, parserHash: predecessorHash)
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        try writer.execute("UPDATE meta SET value = '\(predecessorHash)' WHERE key = 'parser_hash'")
        try writer.execute("PRAGMA user_version = \(predecessorVersion)")
        let predecessor = CostUsageStore(
            cacheRoot: fixture.env.cacheRoot, schemaVersion: predecessorVersion, parserHash: predecessorHash)
        let loaded = predecessor.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        #expect(loaded.unloadedTokenSnapshotPaths.count == fixture.fileCount)
        let adopter = CostUsageStore(cacheRoot: fixture.env.cacheRoot)
        let adopted = adopter.syncLoadCodexCache(calendar: fixture.calendar)
        #expect(adopted == fixture.canonical)
        #expect(predecessor.syncSaveCodexCache(
            loaded.cache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
            receipt: loaded.receipt).catchUpRequired)
        #expect(adopter.syncLoadCodexCache(calendar: fixture.calendar) == adopted)
        #expect(await adopter.rebuildCount == 0)
        #expect(await predecessor.rebuildCount == 0)
    }

    @Test
    func `database replacement rejects receipt and reopens the current inode`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let replacement = CostUsageStore(cacheRoot: fixture.env.root.appendingPathComponent("replacement"))
        var replacementCache = fixture.canonical
        replacementCache.codexProjectMetadataVersion = 777
        #expect(!replacement.syncSaveCodexCache(
            replacementCache,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day)).catchUpRequired)
        #expect(await replacement.truncateWALForTesting())
        await replacement.closeConnectionForTesting()
        #expect(await fixture.store.truncateWALForTesting())
        // Rename the whole owned directory, keeping the old connection's sidecars together.
        let oldDirectory = fixture.store.databaseURL.deletingLastPathComponent()
        let retired = fixture.env.root.appendingPathComponent("retired-store")
        try FileManager.default.moveItem(at: oldDirectory, to: retired)
        try FileManager.default.moveItem(at: replacement.databaseURL.deletingLastPathComponent(), to: oldDirectory)
        #expect(fixture.save(loaded.cache, load: loaded).catchUpRequired)
        #expect(fixture.store.syncLoadCodexCache(calendar: fixture.calendar) == replacementCache)
        #expect(await fixture.store.rebuildCount == 0)
    }
}

extension ReadWorkFixture {
    func save(_ cache: CostUsageCache, load: CostUsageStoreLoad) -> CostUsageStoreBudgetResult {
        let unloadedTokenPaths = load.unloadedTokenSnapshotPaths.filter {
            cache.files[$0]?.codexTokenSnapshots == nil
        }
        return self.store.syncSaveCodexCache(
            cache,
            calendar: self.calendar,
            requestedScanWindow: (sinceKey: self.canonical.scanSinceKey!, untilKey: self.canonical.scanUntilKey!),
            unloadedTokenSnapshotPaths: unloadedTokenPaths,
            skipIdenticalContent: true,
            receipt: load.receipt)
    }
}

final class BaselineSQLiteConnection: @unchecked Sendable {
    private let database: OpaquePointer

    init(url: URL) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        guard result == SQLITE_OK, let database else {
            if let database {
                sqlite3_close_v2(database)
            }
            throw CostUsageStore.StoreError.sqlite(result)
        }
        self.database = database
    }

    deinit { sqlite3_close_v2(self.database) }

    func execute(_ sql: String) throws {
        try CostUsageStore.execute(self.database, sql)
    }
}

extension CostUsageStore {
    fileprivate func observeBaselineReleaseForTesting(_ observer: @escaping @Sendable () -> Void) {
        self.codexBaselineReleaseObserverForTesting = observer
    }

    fileprivate func baselineDataVersionForTesting() -> Int64 {
        self.withDatabase(default: -1) { try Self.scalarInt($0, "PRAGMA data_version") }
    }

    fileprivate func baselineExecuteForTesting(_ sql: String) -> Bool {
        self.withDatabase(default: false) {
            try Self.execute($0, sql)
            return true
        }
    }
}
