import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

/// Adversarial failure injection for the SQLite cost-usage store: constraint failures,
/// disk-full class errors, mid-file corruption, sidecar (-wal/-shm) damage, schema
/// downgrades, and pathological database files. The invariant under test: only
/// corruption or schema drift may destroy the database; every transient or data-shape
/// failure must preserve existing history.
struct CostUsageStoreFailureInjectionTests {
    // MARK: - Error classification

    @Test
    func `transient sqlite errors never trigger a rebuild`() {
        let preserved: [Int32] = [
            SQLITE_BUSY, SQLITE_LOCKED, SQLITE_NOMEM, SQLITE_FULL, SQLITE_IOERR,
            SQLITE_CONSTRAINT, SQLITE_TOOBIG, SQLITE_INTERRUPT, SQLITE_READONLY,
            SQLITE_PERM, SQLITE_MISUSE, SQLITE_RANGE, SQLITE_AUTH,
        ]
        for code in preserved {
            #expect(!CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.sqlite(code)))
        }
        // Extended result codes classify by their primary code.
        let extendedConstraint = SQLITE_CONSTRAINT | (5 << 8) // SQLITE_CONSTRAINT_NOTNULL
        let extendedIOErr = SQLITE_IOERR | (3 << 8) // SQLITE_IOERR_FSYNC
        #expect(!CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.sqlite(extendedConstraint)))
        #expect(!CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.sqlite(extendedIOErr)))
    }

    @Test
    func `corruption class errors trigger a rebuild`() {
        let destructive: [Int32] = [SQLITE_CORRUPT, SQLITE_NOTADB, SQLITE_ERROR, SQLITE_CANTOPEN]
        for code in destructive {
            #expect(CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.sqlite(code)))
        }
        #expect(CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.invalidData))
        #expect(CostUsageStore.shouldRebuild(after: CostUsageStore.StoreError.incompatibleSchema))
    }

    // MARK: - Constraint violations must not destroy history

    @Test
    func `token snapshots for an unknown file fail without destroying the database`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/kept.jsonl")
        #expect(await store.upsertFile(file))

        // NULL file_id from the path subquery violates NOT NULL: a data-shape error,
        // not corruption. Before classification this nuked the whole database twice.
        let orphan = Self.snapshot(path: "/rollouts/does-not-exist.jsonl", eventIndex: 0)
        #expect(await store.appendTokenSnapshots([orphan]) == false)

        #expect(await store.rebuildCount == 0)
        #expect(await store.fetchFile(path: file.path) == file)
    }

    @Test
    func `usage rows for an unknown file fail without destroying the database`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/kept.jsonl")
        #expect(await store.upsertFile(file))

        let orphan = CostUsageStoreUsageRow(path: "/missing.jsonl", rowIndex: 0, payload: Data([1]))
        #expect(await store.appendUsageRows([orphan]) == false)

        #expect(await store.rebuildCount == 0)
        #expect(await store.fetchFile(path: file.path) == file)
    }

    @Test
    func `connection stays usable after a failed transaction`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/kept.jsonl")
        #expect(await store.upsertFile(file))
        #expect(await store.appendTokenSnapshots([Self.snapshot(path: "/missing.jsonl", eventIndex: 0)]) == false)

        // The rolled-back transaction must not leave the connection wedged.
        let snapshot = Self.snapshot(path: file.path, eventIndex: 0)
        #expect(await store.appendTokenSnapshots([snapshot]))
        #expect(await store.fetchTokenSnapshots(path: file.path) == [snapshot])
        #expect(await store.rebuildCount == 0)
    }

    // MARK: - On-disk damage

    @Test
    func `structural corruption in the middle of the file is detected on open`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let url = try await Self.populateAndClose(root: fixture.root, files: 8)

        var bytes = try Data(contentsOf: url)
        #expect(bytes.count > 8192, "need multiple pages to corrupt mid-file")
        // Damage the page header of every page after the first: structural corruption
        // that PRAGMA quick_check must flag (value-only bit flips are undetectable
        // without a checksumming VFS and are out of scope here).
        let pageSize = 4096
        var offset = pageSize
        while offset + 8 <= bytes.count {
            for index in offset..<(offset + 8) {
                bytes[index] ^= 0xFF
            }
            offset += pageSize
        }
        try bytes.write(to: url)

        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.readSnapshot().files.isEmpty)
        #expect(await store.rebuildCount == 1)
        // The rebuilt store must be fully usable.
        #expect(await store.upsertFile(Self.file(path: "/rollouts/new.jsonl")))
    }

    @Test
    func `deleting the wal file of a checkpointed database loses nothing`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let url = try await Self.populateAndClose(root: fixture.root, files: 3)
        for suffix in ["-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: url.path + suffix)
        }

        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.readSnapshot().files.count == 3)
        #expect(await store.rebuildCount == 0)
    }

    @Test
    func `stale shm sidecar does not block reopen`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let url = try await Self.populateAndClose(root: fixture.root, files: 3)
        try? FileManager.default.removeItem(atPath: url.path + "-wal")
        try Data(repeating: 0xAB, count: 32768).write(to: URL(fileURLWithPath: url.path + "-shm"))

        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.readSnapshot().files.count == 3)
    }

    @Test
    func `zero byte database file rebuilds cleanly`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let url = fixture.databaseURL
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data().write(to: url)

        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.fetchMetadata() == .empty)
        #expect(await store.rebuildCount == 1)
        #expect(await store.upsertFile(Self.file(path: "/rollouts/a.jsonl")))
    }

    @Test
    func `database path occupied by a directory recovers`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        try FileManager.default.createDirectory(
            at: fixture.databaseURL,
            withIntermediateDirectories: true)

        let store = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/a.jsonl")
        #expect(await store.upsertFile(file))
        #expect(await store.fetchFile(path: file.path) == file)
    }

    @Test
    func `future schema version on disk rebuilds instead of misreading`() async throws {
        let fixture = try FailureFixture()
        defer { fixture.remove() }
        let url = try await Self.populateAndClose(root: fixture.root, files: 2)
        try Self.execute(at: url, sql: "PRAGMA user_version = \(CostUsageStore.schemaVersion &+ 1)")

        let store = CostUsageStore(cacheRoot: fixture.root)
        #expect(await store.readSnapshot().files.isEmpty)
        #expect(await store.rebuildCount == 1)
        #expect(await store.configuration()?.userVersion == Int(CostUsageStore.schemaVersion))
    }
}

// MARK: - Helpers

extension CostUsageStoreFailureInjectionTests {
    /// Creates a store, writes `files` file rows plus token snapshots, checkpoints the WAL
    /// into the main file, and releases the store so the connection closes.
    private static func populateAndClose(root: URL, files: Int) async throws -> URL {
        let url: URL
        do {
            let store = CostUsageStore(cacheRoot: root)
            url = store.databaseURL
            for index in 0..<files {
                let file = Self.file(path: "/rollouts/\(index).jsonl")
                #expect(await store.upsertFile(file))
                #expect(await store.appendTokenSnapshots([Self.snapshot(path: file.path, eventIndex: 0)]))
            }
            _ = await store.fileSizeBytes() // checkpoints WAL into the main file
        }
        return url
    }

    private static func execute(at url: URL, sql: String) throws {
        var database: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE, nil)
        defer { sqlite3_close_v2(database) }
        guard result == SQLITE_OK else { throw CostUsageStore.StoreError.sqlite(result) }
        let exec = sqlite3_exec(database, sql, nil, nil, nil)
        guard exec == SQLITE_OK else { throw CostUsageStore.StoreError.sqlite(exec) }
    }

    private static func file(path: String) -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: path,
            inode: 7,
            mtimeUnixMs: 1000,
            size: 500,
            parsedBytes: 400,
            anchor: nil,
            scanState: CostUsageStoreScanState(
                targetSize: 500,
                isComplete: true,
                resumePayload: nil,
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: nil,
                lastModel: "gpt-5.6-sol",
                lastTurnID: nil,
                fileIdentity: "1:7",
                detailsPayload: Data([1, 2])),
            sessionID: "session-\(path)",
            coverageSinceDay: "2026-08-01",
            coverageUntilDay: "2026-08-01",
            updatedAtUnixMs: 10)
    }

    private static func snapshot(path: String, eventIndex: Int) -> CostUsageStoreTokenSnapshot {
        CostUsageStoreTokenSnapshot(
            path: path,
            eventIndex: eventIndex,
            timestamp: "2026-08-01T12:00:00Z",
            timestampUnixMs: 1_754_046_000_000,
            day: "2026-08-01",
            last: CostUsageStoreTotals(input: 2, cached: 1, output: 3, reasoning: 1),
            total: CostUsageStoreTotals(input: 20, cached: 10, output: 30, reasoning: 5),
            endOffset: 100)
    }
}

private struct FailureFixture: Sendable {
    let root: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreFailureTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    var databaseURL: URL {
        self.root
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent(CostUsageStore.databaseFilename, isDirectory: false)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
