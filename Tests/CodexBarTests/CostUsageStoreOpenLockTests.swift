import Foundation
import Testing
@testable import CodexBarCore

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

extension CostUsageStoreTests {
    @Test(.timeLimit(.minutes(1)))
    func `current store opens read only while another process holds the write lock`() async throws {
        let fixture = try OpenLockStoreFixture()
        defer { fixture.remove() }
        let seed = CostUsageStore(cacheRoot: fixture.root)
        let file = Self.file(path: "/rollouts/current-lock.jsonl")
        #expect(await seed.upsertFile(file))

        let holder = try OpenLockSQLiteConnection(url: seed.databaseURL)
        try holder.execute("BEGIN IMMEDIATE")
        try holder.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('holder', '1')")

        let reader = CostUsageStore(cacheRoot: fixture.root)
        #expect(await reader.fetchFile(path: file.path) == file)
        #expect(await reader.rebuildCount == 0)

        try holder.execute("COMMIT")
        #expect(await reader.fetchFile(path: file.path) == file)
        #expect(await reader.rebuildCount == 0)
    }

    @Test(.timeLimit(.minutes(1)))
    func `locked compatible predecessor is preserved and adopts after retry`() async throws {
        let fixture = try OpenLockStoreFixture()
        defer { fixture.remove() }
        let predecessorHash = "43609cc56f76a003"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion,
            parserHash: predecessorHash)
        let predecessor = CostUsageStore(
            cacheRoot: fixture.root,
            schemaVersion: predecessorVersion,
            parserHash: predecessorHash)
        let file = Self.file(path: "/rollouts/predecessor-lock.jsonl")
        #expect(await predecessor.upsertFile(file))

        let holder = try OpenLockSQLiteConnection(url: predecessor.databaseURL)
        try holder.execute("BEGIN IMMEDIATE")
        try holder.execute("INSERT OR REPLACE INTO meta(key, value) VALUES ('holder', '1')")

        let current = CostUsageStore(cacheRoot: fixture.root)
        #expect(await current.fetchFile(path: file.path) == nil)
        #expect(await current.rebuildCount == 0)
        #expect(FileManager.default.fileExists(atPath: current.databaseURL.path))

        try holder.execute("COMMIT")
        #expect(await current.fetchFile(path: file.path) == file)
        #expect(await current.rebuildCount == 0)
    }

    private static func file(path: String) -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: path,
            inode: 42,
            mtimeUnixMs: 1000,
            size: 500,
            parsedBytes: 400,
            anchor: CostUsageStoreValidationAnchor(indexedBytes: 400, windowStart: 144, sha256: "abc123"),
            scanState: CostUsageStoreScanState(
                targetSize: 500,
                isComplete: true,
                resumePayload: Data([1, 2, 3]),
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: 7,
                lastModel: "gpt-5.6-sol",
                lastTurnID: "turn-1",
                fileIdentity: "1:42",
                detailsPayload: Data([4, 5, 6])),
            sessionID: "session-\(path)",
            coverageSinceDay: "2026-08-01",
            coverageUntilDay: "2026-08-01",
            updatedAtUnixMs: 10)
    }
}

private struct OpenLockStoreFixture {
    let root: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreOpenLockTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}

private final class OpenLockSQLiteConnection {
    enum TestError: Error {
        case sqlite(Int32)
    }

    private var database: OpaquePointer?

    init(url: URL) throws {
        let result = sqlite3_open_v2(url.path, &self.database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        guard result == SQLITE_OK else { throw TestError.sqlite(result) }
    }

    deinit {
        if let database {
            sqlite3_close_v2(database)
        }
    }

    func execute(_ sql: String) throws {
        let result = sqlite3_exec(self.database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw TestError.sqlite(result) }
    }
}
