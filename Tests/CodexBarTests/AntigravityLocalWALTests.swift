import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityLocalWALTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test
    func `schema validation and payload selection retain one snapshot during a writer schema change`() throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let url = try fixture.database()
        let writer = try Fixture.open(url)
        defer { sqlite3_close(writer) }
        try Fixture.execute(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try Fixture.insert(writer, row: 0, blob: Fixture.blob())
        var changed = false
        var budget: AntigravityLocalReader.Budget?
        defer { budget = nil }
        budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
            if !changed, budget?.statistics.schemaColumns == 2 {
                changed = true
                try Fixture.execute(writer, """
                ALTER TABLE gen_metadata RENAME TO backing;
                CREATE VIEW gen_metadata AS SELECT idx, data FROM backing;
                """)
            }
        })
        let source = try AntigravityLocalReader.readDatabases([url], budget: #require(budget))
        #expect(changed)
        #expect(source.isComplete)
        #expect(source.events.count == 1)
        #expect(try fixture.report().coverage == .partial)
        #expect(try Self.checkpoint(writer) == 0)
    }

    @Test
    func `read-only live WAL preserves database data while permitting normal SHM coordination`() throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let url = try fixture.database()
        let writer = try Fixture.open(url)
        defer { sqlite3_close(writer) }
        try Fixture.execute(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try Fixture.insert(writer, row: 0, blob: Fixture.blob())
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let shm = URL(fileURLWithPath: url.path + "-shm")
        let beforeDB = try Data(contentsOf: url)
        let beforeWAL = try Data(contentsOf: wal)
        let beforeSHM = try Data(contentsOf: shm)

        #expect(try fixture.report().report.summary?.totalTokens == 198)

        #expect(try Data(contentsOf: url) == beforeDB)
        #expect(try Data(contentsOf: wal) == beforeWAL)
        let afterSHM = try Data(contentsOf: shm)
        #expect(afterSHM.count == beforeSHM.count)
        // The WAL-index header remains stable without a writer. Read marks elsewhere may change.
        #expect(afterSHM.prefix(96) == beforeSHM.prefix(96))
        #expect(try Self.checkpoint(writer) == 0)
    }

    @Test
    func `single SQL snapshot excludes coordinated later writes and releases handles on cancellation`() throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let url = try fixture.database()
        let writer = try Fixture.open(url)
        var writerClosed = false
        defer { if !writerClosed { sqlite3_close(writer) } }
        try Fixture.execute(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try Fixture.insert(writer, row: 0, blob: Fixture.blob())
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let before = try Data(contentsOf: wal)
        var inserted = false
        var budget: AntigravityLocalReader.Budget?
        budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
            if !inserted, budget?.statistics.rows == 1 {
                inserted = true
                try Fixture.insert(writer, row: 1, blob: Fixture.blob(response: "later"))
            }
        })
        let source = try AntigravityLocalReader.readDatabases([url], budget: #require(budget))
        #expect(budget?.statistics.sqliteHandlesOpened == 1)
        #expect(budget?.statistics.sqliteHandlesClosed == 1)
        budget = nil
        #expect(inserted)
        #expect(source.isComplete)
        #expect(source.events.count == 1)
        #expect(try Data(contentsOf: wal) != before) // Attributed to the coordinated writer, not the reader.
        #expect(try fixture.report().report.summary?.totalTokens == 396)

        var cancelBudget: AntigravityLocalReader.Budget?
        cancelBudget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
            if cancelBudget?.statistics.rows == 1 { throw CancellationError() }
        })
        #expect(throws: CancellationError.self) {
            try AntigravityLocalReader.readDatabases([url], budget: #require(cancelBudget))
        }
        #expect(cancelBudget?.statistics.sqliteHandlesOpened == 1)
        #expect(cancelBudget?.statistics.sqliteHandlesClosed == 1)
        cancelBudget = nil
        #expect(try Self.checkpoint(writer) == 0) // No reader transaction/statement holds a WAL lock.
        // Sidecar removal is a writer cleanup action, not a promise made by read-only access.
        try Fixture.execute(writer, "PRAGMA journal_mode=DELETE")
        let closed = sqlite3_close(writer)
        writerClosed = closed == SQLITE_OK
        #expect(closed == SQLITE_OK)
        #expect(!FileManager.default.fileExists(atPath: wal.path))
        let shmRetained = FileManager.default.fileExists(atPath: url.path + "-shm")
        print("Synthetic WAL cleanup: reader and writer closed; SHM retained: \(shmRetained)")
    }

    @Test
    func `initially absent WAL sidecars and failed opens leave no reader handles`() throws {
        let fixture = try Fixture()
        defer { withExtendedLifetime(fixture) {} }
        let url = try fixture.database(blobs: [Fixture.blob()])
        try Self.prepareWAL(url)
        let before = try Data(contentsOf: url)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
        let controlFixture = try Fixture()
        defer { withExtendedLifetime(controlFixture) {} }
        let controlURL = try controlFixture.database(blobs: [Fixture.blob()])
        try Self.prepareWAL(controlURL)
        #expect(!FileManager.default.fileExists(atPath: controlURL.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: controlURL.path + "-shm"))
        let control = Self.readOnlyQueryStatus(controlURL)
        #expect(control == SQLITE_ROW || control == SQLITE_CANTOPEN)
        // The raw SQLite control never opens the production target or prepares its sidecars.
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        #expect(!FileManager.default.fileExists(atPath: url.path + "-shm"))
        let report = try fixture.report()
        #expect(report.coverage == (control == SQLITE_ROW ? .complete : .partial))
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
        #expect(try Data(contentsOf: url) == before)
        // Some SQLite builds decline read-only WAL access without sidecars; that must stay unavailable.
        // This control uses the platform SQLite contract independently of the production reader.
        let reopened = try Fixture.open(url)
        var reopenedClosed = false
        defer { if !reopenedClosed { sqlite3_close(reopened) } }
        #expect(try Self.checkpoint(reopened) == 0)
        try Fixture.execute(reopened, "PRAGMA journal_mode=DELETE")
        let closedAgain = sqlite3_close(reopened)
        reopenedClosed = closedAgain == SQLITE_OK
        #expect(closedAgain == SQLITE_OK)
        #expect(!FileManager.default.fileExists(atPath: url.path + "-wal"))
        let shmRetained = FileManager.default.fileExists(atPath: url.path + "-shm")
        print(
            "Synthetic WAL without sidecars: control \(control); SHM retained after cleanup: \(shmRetained)")
        let missing = fixture.root.appendingPathComponent("missing/absent.db")
        for _ in 0..<20 {
            let budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {})
            let result = try AntigravityLocalReader.readDatabases([missing], budget: budget)
            #expect(!result.isComplete)
            #expect(budget.statistics.sqliteHandlesOpened == budget.statistics.sqliteHandlesClosed)
        }
        #expect(!FileManager.default.fileExists(atPath: missing.path))
    }

    private static func prepareWAL(_ url: URL) throws {
        let writer = try Fixture.open(url)
        defer { sqlite3_close(writer) }
        try Fixture.execute(writer, "PRAGMA journal_mode=WAL")
    }

    private static func readOnlyQueryStatus(_ url: URL) -> Int32 {
        var database: OpaquePointer?
        let opened = sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READONLY, nil)
        defer { sqlite3_close(database) }
        guard opened == SQLITE_OK else { return opened }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        let prepared = sqlite3_prepare_v2(database, "SELECT idx, data FROM gen_metadata", -1, &statement, nil)
        guard prepared == SQLITE_OK else { return prepared }
        return sqlite3_step(statement)
    }

    private static func checkpoint(_ database: OpaquePointer) throws -> Int32 {
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        guard sqlite3_prepare_v2(database, "PRAGMA wal_checkpoint(TRUNCATE)", -1, &statement, nil) == SQLITE_OK,
              sqlite3_step(statement) == SQLITE_ROW else { throw AntigravityLocalReader.ScanFailure.invalid }
        return sqlite3_column_int(statement, 0)
    }
}
