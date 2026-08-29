import Foundation
import Testing
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityLocalScanTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test(arguments: [499, 500, 501])
    func `database cap distinguishes below exactly and above limit`(count: Int) throws {
        let fixture = try Fixture()
        let seed = try fixture.database("session-0")
        // The cap counts distinct files; copy the closed empty database instead of committing 500 schemas.
        for index in 1..<count {
            try FileManager.default.copyItem(
                at: seed,
                to: seed.deletingLastPathComponent().appendingPathComponent("session-\(index).db"))
        }
        var limits = AntigravityLocalReader.Limits()
        limits.duration = 60
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == (count <= 500 ? .complete : .partial))
        #expect(report.statistics.files == min(count, 500))
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.sqliteHandlesOpened == min(count, 500))
        #expect(report.statistics.sqliteHandlesClosed == report.statistics.sqliteHandlesOpened)
    }

    @Test
    func `discovery stops before collecting every irrelevant filename`() throws {
        let fixture = try Fixture()
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for index in 0..<20 {
            try Data().write(to: root.appendingPathComponent("ignored-\(index).txt"))
        }
        var limits = AntigravityLocalReader.Limits()
        limits.directoryEntries = 3
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.statistics.directoryEntries == 4)
        #expect(report.statistics.files == 0)
    }

    @Test
    func `NULL and empty SQL rows count toward truncation and cumulative row limits`() throws {
        let fixture = try Fixture()
        let url = try fixture.database()
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "INSERT INTO gen_metadata VALUES (0, NULL), (1, x''), (2, NULL), (3, NULL)")
        var limits = AntigravityLocalReader.Limits()
        limits.rowsPerDatabase = 2
        let perDatabase = try fixture.report(limits: limits)
        #expect(perDatabase.coverage == .partial)
        #expect(perDatabase.statistics.rows == 3)
        limits.rowsPerDatabase = 100
        limits.rows = 1
        let cumulative = try fixture.report(limits: limits)
        #expect(cumulative.coverage == .partial)
        #expect(cumulative.statistics.rows == 2)
    }

    @Test
    func `rejected oversized SQL rows exhaust attempted bytes before another row`() throws {
        let fixture = try Fixture()
        let url = try fixture.database()
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, """
        INSERT INTO gen_metadata VALUES (0, zeroblob(40)), (1, zeroblob(40)),
            (2, zeroblob(40)), (3, zeroblob(40))
        """)
        var limits = AntigravityLocalReader.Limits()
        limits.blobBytes = 10
        limits.bytes = 70
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.statistics.rows == 2)
        #expect(report.statistics.attemptedBytes == 80)
        #expect(report.statistics.materializedPayloadBytes == 0)
        limits.bytes = 1000
        limits.databaseBytes = 70
        let perDatabase = try fixture.report(limits: limits)
        #expect(perDatabase.statistics.rows == 2)
        #expect(perDatabase.coverage == .partial)
        #expect(perDatabase.statistics.materializedPayloadBytes == 0)
        limits.blobBytes = 100
        let projected = try fixture.report(limits: limits)
        #expect(projected.statistics.attemptedBytes == 80)
        #expect(projected.statistics.materializedPayloadBytes == 40)
    }

    @Test
    func `byte budget is cumulative across separate databases`() throws {
        let fixture = try Fixture()
        let blob = Fixture.blob()
        try fixture.database("a", blobs: [blob])
        try fixture.database("b", blobs: [blob])
        var limits = AntigravityLocalReader.Limits()
        limits.bytes = blob.count
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.statistics.files == 2)
        #expect(report.statistics.rows == 2)
        #expect(report.statistics.attemptedBytes == blob.count * 2)
        #expect(report.statistics.materializedPayloadBytes == blob.count)
    }

    @Test
    func `expression view is rejected before evaluating its intermediate value`() throws {
        let fixture = try Fixture()
        let url = try fixture.database()
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, """
        DROP TABLE gen_metadata;
        CREATE VIEW gen_metadata AS SELECT 0 AS idx, zeroblob(2048) AS data;
        """)
        var limits = AntigravityLocalReader.Limits()
        limits.blobBytes = 10
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.materializedPayloadBytes == 0)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
    }

    @Test
    func `row truncation sentinel does not materialize a rejected payload`() throws {
        let fixture = try Fixture()
        let blob = Fixture.blob()
        try fixture.database(blobs: [blob, blob])
        var limits = AntigravityLocalReader.Limits()
        limits.rowsPerDatabase = 1
        let perDatabase = try fixture.report(limits: limits)
        #expect(perDatabase.coverage == .partial)
        #expect(perDatabase.statistics.rows == 2)
        #expect(perDatabase.statistics.materializedPayloadBytes == blob.count)
        limits.rowsPerDatabase = 10
        limits.rows = 1
        let cumulative = try fixture.report(limits: limits)
        #expect(cumulative.coverage == .partial)
        #expect(cumulative.statistics.rows == 2)
        #expect(cumulative.statistics.materializedPayloadBytes == blob.count)
    }

    @Test
    func `optional steps scan does not exhaust embedded timestamp usage rows`() throws {
        let fixture = try Fixture()
        let blob = Fixture.blobWithRootEnvelope(seconds: 1_787_832_000)
        let url = try fixture.database(blobs: [blob], stepBlobs: [])
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "INSERT INTO steps VALUES (0, zeroblob(40)), (1, zeroblob(40))")
        var limits = AntigravityLocalReader.Limits()
        limits.rowsPerDatabase = 1

        let report = try fixture.report(limits: limits)

        #expect(report.coverage == .complete)
        #expect(report.statistics.rows == 1)
        #expect(report.statistics.attemptedBytes == blob.count)
    }

    @Test
    func `optional steps scan charges its rows and bytes against the shared job budget`() throws {
        let fixture = try Fixture()
        let stepUUID = "budgeted-step-uuid"
        let genBlob = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)
        let stepBlob = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_832_000)
        try fixture.database(blobs: [genBlob], stepBlobs: [stepBlob])

        #expect(try fixture.report().coverage == .complete)

        var limits = AntigravityLocalReader.Limits()
        limits.rows = 1
        let rowBound = try fixture.report(limits: limits)
        #expect(rowBound.coverage == .partial)
        #expect(rowBound.statistics.rows == 2)

        limits = AntigravityLocalReader.Limits()
        limits.bytes = genBlob.count
        let byteBound = try fixture.report(limits: limits)
        #expect(byteBound.coverage == .partial)
        #expect(byteBound.statistics.attemptedBytes == genBlob.count + stepBlob.count)
    }

    @Test
    func `recursive aggregate view is rejected without executing its payload query`() throws {
        let fixture = try Fixture()
        let url = try fixture.database()
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, """
        DROP TABLE gen_metadata;
        CREATE VIEW gen_metadata AS
        WITH RECURSIVE rows(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM rows WHERE x<4999)
        SELECT sum(x) AS idx, NULL AS data FROM rows;
        """)
        let result = try fixture.report()
        #expect(result.coverage == .partial)
        #expect(result.statistics.rows == 0)
        #expect(result.statistics.materializedPayloadBytes == 0)
        try Fixture.execute(database, "BEGIN EXCLUSIVE; ROLLBACK")
    }

    @Test
    func `JSONL byte and line limits apply before whole file allocation`() async throws {
        let fixture = try Fixture()
        let url = try fixture.jsonl([Fixture.cacheUsage])
        let file = try FileHandle(forWritingTo: url)
        try file.truncate(atOffset: 129 * 1024 * 1024)
        try file.close()
        let report = try fixture.report()
        #expect(report.coverage == .partial)
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.attemptedBytes == 129 * 1024 * 1024)
        #expect(try await !fixture.snapshot().historyCoverageIsEstablished)
        try Fixture.cacheUsage.write(to: url, atomically: true, encoding: .utf8)
        var limits = AntigravityLocalReader.Limits()
        limits.blobBytes = 10
        #expect(try fixture.report(limits: limits).coverage == .partial)
        try fixture.jsonl([Fixture.cacheUsage, Fixture.cacheUsage])
        limits.blobBytes = 1000
        limits.rows = 1
        #expect(try fixture.report(limits: limits).statistics.rows == 2)
    }

    @Test
    func `pinned monotonic clock bounds the whole discovery and parsing job`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob()])
        var tick: TimeInterval = 0
        var limits = AntigravityLocalReader.Limits()
        limits.duration = 3
        let report = try fixture.report(limits: limits, clock: {
            defer { tick += 1 }
            return tick
        })
        #expect(report.coverage == .partial)
        #expect(tick == 4)
        tick = 0
        limits.duration = 20
        let parsing = try fixture.report(limits: limits, clock: {
            defer { tick += 1 }
            return tick
        })
        #expect(parsing.coverage == .partial)
        #expect(parsing.statistics.rows == 1)
        #expect(parsing.statistics.sqliteHandlesOpened == parsing.statistics.sqliteHandlesClosed)
    }

    @Test
    func `cancellation reaches discovery SQL protobuf and JSONL loops`() throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [Fixture.blob(), Fixture.blob()])
        #expect(throws: CancellationError.self) {
            try fixture.report(checkCancellation: { throw CancellationError() })
        }
        var calls = 0
        var budget: AntigravityLocalReader.Budget?
        defer { budget = nil }
        budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
            if budget?.statistics.rows == 1 {
                calls += 1
                if calls == 2 { throw CancellationError() }
            }
        })
        #expect(throws: CancellationError.self) {
            try AntigravityLocalReader.readDatabases([url], budget: #require(budget))
        }
        #expect(budget?.statistics.rows == 1)
        #expect(calls == 2)
        var fields = 0
        #expect(throws: CancellationError.self) {
            try AntigravityProtoReader.parseTurn(Fixture.blob()) {
                fields += 1
                if fields == 6 { throw CancellationError() }
            }
        }
        let cache = try fixture.jsonl([Fixture.cacheUsage])
        var jsonCalls = 0
        let jsonBudget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
            jsonCalls += 1
            if jsonCalls == 6 { throw CancellationError() }
        })
        #expect(throws: CancellationError.self) {
            try AntigravityLocalReader.readJSONL([cache], budget: jsonBudget)
        }
    }

    @Test
    func `executor cancellation drains a running single database reader`() async throws {
        let fixture = try Fixture()
        let url = try fixture.database(blobs: [Fixture.blob()])
        let gate = ScanCancellationGate()
        let task = Task {
            try await CostUsageScanExecutor.run { check in
                var budget: AntigravityLocalReader.Budget?
                defer { budget = nil }
                budget = AntigravityLocalReader.Budget(limits: .init(), cancellation: {
                    if budget?.statistics.rows == 1 { gate.enter() }
                    try check()
                })
                return try AntigravityLocalReader.readDatabases([url], budget: #require(budget)).isComplete
            }
        }
        await gate.waitUntilInside()
        task.cancel()
        gate.release()
        do {
            _ = try await task.value
            Issue.record("Expected cancellation")
        } catch is CancellationError {}
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, "BEGIN EXCLUSIVE; ROLLBACK")
        #expect(try await fixture.snapshot().historyCoverageIsEstablished)
    }

    @Test
    func `real fetcher cancellation is bridged to the scan executor`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob()])
        let gate = ScanCancellationGate()
        let blocker = Task {
            try await CostUsageScanExecutor.run { _ in gate.enter() }
        }
        await gate.waitUntilInside()
        let fetch = Task { try await fixture.snapshot() }
        fetch.cancel()
        gate.release()
        try await blocker.value
        do {
            _ = try await fetch.value
            Issue.record("Expected cancelled production fetch")
        } catch is CancellationError {}
    }
}

private final class ScanCancellationGate: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseSignal = DispatchSemaphore(value: 0)
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?

    func enter() {
        self.lock.lock()
        let first = !self.entered
        self.entered = true
        let waiter = self.waiter
        self.waiter = nil
        self.lock.unlock()
        waiter?.resume()
        if first { _ = self.releaseSignal.wait(timeout: .now() + 5) }
    }

    func waitUntilInside() async {
        await withCheckedContinuation { continuation in
            self.lock.lock()
            let entered = self.entered
            if !entered { self.waiter = continuation }
            self.lock.unlock()
            if entered { continuation.resume() }
        }
    }

    func release() {
        self.releaseSignal.signal()
    }
}
