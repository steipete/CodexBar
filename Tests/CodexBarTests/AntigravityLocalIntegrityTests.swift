import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityLocalIntegrityTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test(arguments: [false, true], [false, true])
    func `duplicate responses retain contradictory copied row evidence in either source order`(
        reversed: Bool, contradictory: Bool) async throws
    {
        for sqlite in [true, false] {
            let fixture = try Fixture()
            var responses = [["r", "r"], ["r", contradictory ? "s" : "r"]]
            if reversed { responses.reverse() }
            for (index, ids) in responses.enumerated() {
                if sqlite {
                    try fixture.database(rootIndex: index, blobs: ids.map { Fixture.blob(response: $0) })
                } else {
                    try fixture.jsonl(ids.map { id in
                        #"{"type":"usage","sessionId":"copied","responseId":"\#(id)","#
                            + #""input":10,"output":2,"timestamp":1787832000000}"#
                    }, session: index == 0 ? "a" : "z")
                }
            }
            let report = try fixture.report()
            #expect(report.coverage == (contradictory ? .partial : .complete))
            let snapshot = try await fixture.snapshot()
            #expect(snapshot.historyCoverageIsEstablished == !contradictory)
            if contradictory {
                #expect(snapshot.daily.isEmpty)
                #expect(snapshot.last30DaysTokens == nil)
            } else {
                #expect(snapshot.last30DaysTokens == (sqlite ? 198 : 12))
                #expect(snapshot.daily.first?.requestCount == 1)
            }
        }
    }

    @Test(arguments: [
        "view",
        "expression",
        "ordered",
        "grouped",
        "generated-data",
        "generated-idx",
        "stored",
        "virtual",
    ])
    func `computed SQLite layouts are rejected before any payload row is selected`(layout: String) async throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [Fixture.blob(), Fixture.blob()])
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "ALTER TABLE gen_metadata RENAME TO backing")
        let sql = switch layout {
        case "view": "CREATE VIEW gen_metadata AS SELECT idx, data FROM backing"
        case "expression":
            // Every evaluation has the same safe size and valid bytes; never reproduce an unsafe read.
            "CREATE VIEW gen_metadata AS SELECT idx, substr(data, 1, length(data)) AS data FROM backing"
        case "ordered": "CREATE VIEW gen_metadata AS SELECT idx, data FROM backing ORDER BY data"
        case "grouped": "CREATE VIEW gen_metadata AS SELECT idx, data FROM backing GROUP BY idx, data"
        case "generated-data", "stored":
            """
            CREATE TABLE gen_metadata (idx INTEGER, payload BLOB, data BLOB AS (payload) \(layout == "stored" ?
                "STORED" : "VIRTUAL"));
            INSERT INTO gen_metadata (idx, payload) SELECT idx, data FROM backing;
            """
        case "generated-idx":
            """
            CREATE TABLE gen_metadata (original INTEGER, idx INTEGER AS (original), data BLOB);
            INSERT INTO gen_metadata (original, data) SELECT idx, data FROM backing;
            """
        default:
            "CREATE VIRTUAL TABLE gen_metadata USING fts5(idx, data); INSERT INTO gen_metadata VALUES (0, 'invalid')"
        }
        try Fixture.execute(database, sql)
        try fixture.jsonl([Fixture.cacheUsage]) // Unsupported SQLite cannot authorize replacement by this cache.
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.attemptedBytes == 0)
        #expect(report.statistics.materializedPayloadBytes == 0)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
    }

    @Test(arguments: [
        "view",
        "virtual",
        "generated-data",
    ])
    func `computed trajectory metadata tables are rejected before querying payloads`(layout: String) async throws {
        let fixture = try Fixture()
        let url = try fixture.database(
            blobs: [Fixture.modernBlob()],
            createdSeconds: UInt64(Fixture.now.timeIntervalSince1970))
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "ALTER TABLE trajectory_metadata_blob RENAME TO backing_metadata")
        let sql = switch layout {
        case "view":
            "CREATE VIEW trajectory_metadata_blob AS SELECT id, data FROM backing_metadata"
        case "generated-data":
            """
            CREATE TABLE trajectory_metadata_blob (id TEXT PRIMARY KEY, payload BLOB, data BLOB AS (payload) VIRTUAL);
            INSERT INTO trajectory_metadata_blob (id, payload) SELECT id, data FROM backing_metadata;
            """
        default:
            "CREATE VIRTUAL TABLE trajectory_metadata_blob USING fts5(id, data); " +
                "INSERT INTO trajectory_metadata_blob VALUES ('main', 'invalid')"
        }
        try Fixture.execute(database, sql)
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.attemptedBytes == 0)
        #expect(report.statistics.materializedPayloadBytes == 0)
    }

    @Test(arguments: ["ordinary", "extra-column", "without-rowid"])
    func `stored ordinary SQLite tables remain supported`(layout: String) throws {
        let fixture = try Fixture()
        let url = try fixture.database()
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "DROP TABLE gen_metadata")
        let definition = layout == "extra-column" ? "idx INTEGER, data BLOB, size INTEGER" :
            "idx INTEGER PRIMARY KEY, data BLOB"
        try Fixture.execute(
            database,
            "CREATE TABLE gen_metadata (\(definition)) \(layout == "without-rowid" ? "WITHOUT ROWID" : "")")
        try Fixture.insert(database, row: 0, blob: Fixture.blob())
        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 198)
        #expect(report.statistics.rows == 1)
    }

    @Test
    func `copy guard derives length from the selected BLOB and rejects inconsistent declarations`() throws {
        let fixture = try Fixture()
        let database = try Fixture.open(fixture.database())
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        defer { sqlite3_finalize(statement) }
        try #require(sqlite3_prepare_v2(database, "SELECT 0, 50000, x'0102'", -1, &statement, nil) == SQLITE_OK)
        let prepared = try #require(statement)
        try #require(sqlite3_step(prepared) == SQLITE_ROW)
        let payload = AntigravityLocalReader.SQLitePayload(statement: prepared)
        #expect(payload.byteCount == 2)
        // Only the repaired guard sees this mismatch; no pre-repair out-of-bounds read is executed.
        #expect(payload.copy(declaredCount: Int(sqlite3_column_int64(prepared, 1)), limit: 65536) == nil)
        #expect(payload.copy(declaredCount: 1, limit: 65536) == nil)
        #expect(payload.copy(declaredCount: 2, limit: 1) == nil)
        #expect(payload.copy(declaredCount: 2, limit: 2) == [1, 2])
    }

    @Test
    func `schema entry column and cumulative byte limits reject before payload reads`() throws {
        let fixture = try Fixture()
        let url = try fixture.database()
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, """
        DROP TABLE gen_metadata;
        CREATE TABLE first (value);
        CREATE TABLE second (value);
        CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
        """)
        try Fixture.insert(database, row: 0, blob: Fixture.blob())
        var limits = AntigravityLocalReader.Limits()
        limits.schemaEntries = 1
        let entries = try fixture.report(limits: limits)
        #expect(entries.coverage == .partial)
        #expect(entries.statistics.schemaEntries == 2)
        #expect(entries.statistics.rows == 0)
        limits.schemaEntries = 128
        limits.schemaColumns = 1
        let columns = try fixture.report(limits: limits)
        #expect(columns.coverage == .partial)
        #expect(columns.statistics.schemaColumns == 2)
        #expect(columns.statistics.rows == 0)
        limits.schemaColumns = 64
        let complete = try fixture.report(limits: limits)
        #expect(complete.coverage == .complete)
        limits.schemaBytes = complete.statistics.schemaBytes
        try fixture.database("session-b", blobs: [Fixture.blob()])
        let cumulative = try fixture.report(limits: limits)
        #expect(cumulative.coverage == .partial)
        #expect(cumulative.statistics.files == 2)
        #expect(cumulative.statistics.rows == 1)
        #expect(cumulative.statistics.schemaBytes > limits.schemaBytes)
        #expect(cumulative.statistics.sqliteHandlesOpened == cumulative.statistics.sqliteHandlesClosed)
    }

    @Test(arguments: [false, true])
    func `schema inspection honors cancellation and a pinned deadline before payload selection`(deadline: Bool) throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [Fixture.blob()])
        let expected = NSError(domain: NSPOSIXErrorDomain, code: 4321)
        var now: TimeInterval = 0
        var budget: AntigravityLocalReader.Budget?
        defer { budget = nil }
        budget = AntigravityLocalReader.Budget(limits: .init(), clock: { now }, cancellation: {
            if budget?.statistics.schemaColumns == 1 {
                if deadline { now = 5 } else { throw expected }
            }
        })
        do {
            _ = try AntigravityLocalReader.readDatabases([url], budget: #require(budget))
            Issue.record("Expected schema inspection to stop")
        } catch AntigravityLocalReader.ScanFailure.exhausted {
            #expect(deadline)
        } catch {
            #expect(!deadline)
            #expect((error as NSError) === expected)
        }
        #expect(budget?.statistics.schemaColumns == 1)
        #expect(budget?.statistics.rows == 0)
        #expect(budget?.statistics.sqliteHandlesOpened == budget?.statistics.sqliteHandlesClosed)
    }
}
