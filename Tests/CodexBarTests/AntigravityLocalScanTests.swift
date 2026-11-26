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

    @Test(arguments: [1999, 2000, 2001])
    func `database cap distinguishes below exactly and above limit`(count: Int) throws {
        let fixture = try Fixture()
        let seed = try fixture.database("session-0")
        // The cap counts distinct files; copy the closed empty database instead of committing 2000 schemas.
        for index in 1..<count {
            try FileManager.default.copyItem(
                at: seed,
                to: seed.deletingLastPathComponent().appendingPathComponent("session-\(index).db"))
        }
        var limits = AntigravityLocalReader.Limits()
        #expect(limits.databases == 2000)
        limits.duration = 60
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == (count <= 2000 ? .complete : .partial))
        #expect(report.statistics.files == min(count, 2000))
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.files)
        #expect(report.statistics.sqliteHandlesClosed == report.statistics.sqliteHandlesOpened)
    }

    @Test
    func `exceeding the database cap retains the newest databases as partial history`() throws {
        let fixture = try Fixture()
        let first = try fixture.database("first", blobs: [Fixture.blob(input: 100)])
        try FileManager.default.setAttributes(
            [.modificationDate: Fixture.now.addingTimeInterval(-3600)],
            ofItemAtPath: first.path)
        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1
        let exact = try fixture.report(limits: limits)
        #expect(exact.coverage == .complete)
        #expect(exact.report.summary?.totalTokens == 187)

        let second = try fixture.database("second", blobs: [Fixture.blob(input: 110)])
        try FileManager.default.setAttributes([.modificationDate: Fixture.now], ofItemAtPath: second.path)
        let exceeded = try fixture.report(limits: limits)
        #expect(exceeded.coverage == .partial)
        #expect(exceeded.report.summary?.totalTokens == 197)
        #expect(exceeded.statistics.files == 1)
        #expect(exceeded.statistics.sqliteHandlesOpened == 1)
        #expect(exceeded.statistics.sqliteHandlesClosed == 1)
    }

    @Test
    func `history beyond the former row cap produces a complete report`() async throws {
        let fixture = try Fixture()
        let blob = Fixture.blob().map { String(format: "%02x", $0) }.joined()
        for file in 0..<6 {
            let database = try Fixture.open(fixture.database("session-\(file)"))
            defer { sqlite3_close(database) }
            try Fixture.execute(database, """
            WITH RECURSIVE rows(idx) AS (
                SELECT 1
                UNION ALL SELECT idx + 1 FROM rows WHERE idx < 10000
            )
            INSERT INTO gen_metadata (idx, data)
            SELECT idx, X'\(blob)' FROM rows
            """)
        }

        let report = try fixture.report()
        #expect(report.coverage == .complete)
        #expect(report.statistics.rows == 60000)
        #expect(report.report.summary?.totalTokens == 60000 * 187)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 60000 * 187)
    }

    @Test
    func `expanded payload and time allowances still stop at their boundaries`() throws {
        var elapsed = 0.0
        let limits = AntigravityLocalReader.Limits()
        let budget = AntigravityLocalReader.Budget(limits: limits, clock: { elapsed }, cancellation: {})
        try budget.chargeBytes(256 * 1024 * 1024)
        elapsed = 10
        try budget.check()
        try budget.chargeBytes(limits.bytes - budget.statistics.attemptedBytes)
        #expect(throws: AntigravityLocalReader.ScanFailure.self) { try budget.chargeBytes(1) }
        elapsed = limits.duration
        #expect(throws: AntigravityLocalReader.ScanFailure.self) { try budget.check() }
    }

    @Test
    func `the schema byte allowance applies to each database rather than the whole history`() throws {
        let fixture = try Fixture()
        try fixture.database("session-1", blobs: [Fixture.blob()])
        let initial = try fixture.report(clock: { 0 })
        #expect(initial.coverage == .complete)
        #expect(initial.report.summary?.totalTokens == 187)

        // Many small schemas together exceed one database's allowance without truncating the scan.
        try fixture.database("session-2", blobs: [Fixture.blob()])
        try fixture.database("session-3", blobs: [Fixture.blob()])
        var limits = AntigravityLocalReader.Limits()
        limits.schemaBytes = initial.statistics.schemaBytes
        let report = try fixture.report(limits: limits, clock: { 0 })
        #expect(report.coverage == .complete)
        #expect(report.report.summary?.totalTokens == 561)
        #expect(report.statistics.files == 3)
        #expect(report.statistics.schemaBytes > limits.schemaBytes)
    }

    @Test(arguments: ["session-0", "session-2", "session-4"])
    func `an oversized schema withholds only its own database and keeps the other rows as partial history`(
        oversizedSession: String) throws
    {
        let fixture = try Fixture()
        try fixture.database("session-1", blobs: [Fixture.blob()])
        let initial = try fixture.report(clock: { 0 })
        #expect(initial.coverage == .complete)

        // Catalogue entries before gen_metadata are inspected, so this schema is larger than session-1's.
        let url = try fixture.database(oversizedSession)
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        try Fixture.execute(database, """
        DROP TABLE gen_metadata;
        CREATE TABLE an_unrelated_table_with_a_long_name (value);
        CREATE TABLE gen_metadata (idx INTEGER, data BLOB);
        """)
        try Fixture.insert(database, row: 0, blob: Fixture.blob())
        try fixture.database("session-3", blobs: [Fixture.blob()])
        var limits = AntigravityLocalReader.Limits()
        limits.schemaBytes = initial.statistics.schemaBytes
        let partial = try fixture.report(limits: limits, clock: { 0 })
        #expect(partial.coverage == .partial)
        #expect(partial.report.summary?.totalTokens == 374)
        #expect(partial.statistics.files == 3)
        #expect(partial.statistics.rows == 2)
        #expect(partial.statistics.sqliteHandlesOpened == partial.statistics.sqliteHandlesClosed)
    }

    @Test
    func `generation and step table inspection share one database schema allowance`() throws {
        let fixture = try Fixture()
        let stepUUID = "schema-budget-step"
        try fixture.database(
            blobs: [Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)],
            stepBlobs: [Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_832_000)])
        let complete = try fixture.report(clock: { 0 })
        #expect(complete.coverage == .complete)
        #expect(complete.report.summary?.totalTokens == 187)

        var limits = AntigravityLocalReader.Limits()
        limits.schemaBytes = complete.statistics.schemaBytes - 1
        let partial = try fixture.report(limits: limits, clock: { 0 })
        #expect(partial.coverage == .partial)
        #expect(partial.report.data.isEmpty)
        #expect(partial.statistics.rows == 1)
        #expect(partial.statistics.schemaBytes > limits.schemaBytes)
        #expect(partial.statistics.sqliteHandlesOpened == partial.statistics.sqliteHandlesClosed)
    }

    @Test
    func `hard row exhaustion across databases retains completed newest databases as partial`() throws {
        let fixture = try Fixture()
        let first = try fixture.database("first", blobs: [Fixture.blob(input: 100)])
        try FileManager.default.setAttributes(
            [.modificationDate: Fixture.now.addingTimeInterval(-3600)],
            ofItemAtPath: first.path)
        let second = try fixture.database("second", blobs: [Fixture.blob(input: 110)])
        try FileManager.default.setAttributes([.modificationDate: Fixture.now], ofItemAtPath: second.path)
        var limits = AntigravityLocalReader.Limits()
        limits.rows = 1
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.report.summary?.totalTokens == 197)
        #expect(report.statistics.files == 2)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
    }

    @Test
    func `hard byte exhaustion across databases retains completed newest databases as partial`() throws {
        let fixture = try Fixture()
        let olderBlob = Fixture.blob(input: 100)
        let newerBlob = Fixture.blob(input: 110)
        #expect(olderBlob.count == newerBlob.count)
        let first = try fixture.database("first", blobs: [olderBlob])
        try FileManager.default.setAttributes(
            [.modificationDate: Fixture.now.addingTimeInterval(-3600)],
            ofItemAtPath: first.path)
        let second = try fixture.database("second", blobs: [newerBlob])
        try FileManager.default.setAttributes([.modificationDate: Fixture.now], ofItemAtPath: second.path)
        var limits = AntigravityLocalReader.Limits()
        limits.bytes = newerBlob.count
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.report.summary?.totalTokens == 197)
        #expect(report.statistics.files == 2)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
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

        limits = AntigravityLocalReader.Limits()
        limits.databaseBytes = genBlob.count + stepBlob.count - 1
        let databaseByteBound = try fixture.report(limits: limits)
        #expect(databaseByteBound.coverage == .partial)
        #expect(databaseByteBound.statistics.attemptedBytes == genBlob.count + stepBlob.count)
    }

    @Test
    func `step scan truncation cannot publish already recovered timestamps as complete`() throws {
        let fixture = try Fixture()
        let stepUUID = "bounded-step-uuid"
        let genBlob = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)
        let matchingStep = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_832_000)
        let trailingStep = Fixture.stepMetadataBlob(stepUUID: "unrelated-step", seconds: 1_787_832_000)
        try fixture.database(blobs: [genBlob], stepBlobs: [matchingStep, trailingStep])
        var limits = AntigravityLocalReader.Limits()
        limits.databaseBytes = genBlob.count + matchingStep.count

        let report = try fixture.report(limits: limits)

        #expect(report.coverage == .partial)
        #expect(report.statistics.rows == 3)
        #expect(report.statistics.attemptedBytes == genBlob.count + matchingStep.count + trailingStep.count)
    }

    @Test
    func `secondary byte exhaustion cannot publish primary rows as partial history`() throws {
        let fixture = try Fixture()
        let stepUUID = "bounded-secondary-history"
        let primary = Fixture.blob()
        let pending = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)
        let step = Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_832_000)
        try fixture.database(blobs: [primary, pending], stepBlobs: [step])
        #expect(try fixture.report().coverage == .complete)

        var limits = AntigravityLocalReader.Limits()
        limits.databaseBytes = primary.count + pending.count
        let report = try fixture.report(limits: limits)
        #expect(report.coverage == .partial)
        #expect(report.report.data.isEmpty)
        #expect(report.report.summary == nil)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)
    }

    @Test
    func `step lookup reaches beyond the primary row cap within the shared budget`() throws {
        let fixture = try Fixture()
        let stepUUID = "sparse-step-uuid"
        let genBlob = Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil)
        let url = try fixture.database(blobs: [genBlob], stepBlobs: [])
        let database = try Fixture.open(url)
        defer { sqlite3_close(database) }
        let unrelatedCount = 10001
        let unrelated = Fixture.stepMetadataBlob(stepUUID: "unrelated-step", seconds: 1_787_832_000)
        try Fixture.execute(database, "BEGIN")
        do {
            for index in 0..<unrelatedCount {
                try Fixture.insertStep(database, row: Int64(index), blob: unrelated)
            }
            try Fixture.insertStep(
                database,
                row: Int64(unrelatedCount),
                blob: Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_832_000))
            try Fixture.insertStep(database, row: Int64(unrelatedCount + 1), blob: unrelated)
            try Fixture.execute(database, "COMMIT")
        } catch {
            try? Fixture.execute(database, "ROLLBACK")
            throw error
        }
        var limits = AntigravityLocalReader.Limits()
        limits.duration = 30

        let report = try fixture.report(limits: limits)

        #expect(report.coverage == .complete)
        #expect(report.report.data.first?.date == "2026-08-27")
        #expect(report.statistics.rows == unrelatedCount + 3)
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

    @Test
    func `dayRange pre-filtering skips stale databases and keeps boundary databases`() throws {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let oldDB = try fixture.database("old-session", blobs: [Fixture.blob(input: 100)])
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-1)],
            ofItemAtPath: oldDB.path)
        let boundaryDB = try fixture.database("boundary-session", blobs: [Fixture.blob(input: 110)])
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate],
            ofItemAtPath: boundaryDB.path)

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .complete)
        #expect(report.statistics.files == 1)
        #expect(report.statistics.sqliteHandlesOpened == 1)
        #expect(report.statistics.sqliteHandlesClosed == 1)
        #expect(report.report.summary?.totalTokens == 197)
    }

    @Test
    func `dayRange pre-filtering rescues stale database with active WAL sidecar including symlinks`() throws {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let staleDate = sinceDate.addingTimeInterval(-86400)
        let activeWalDate = sinceDate.addingTimeInterval(3600)

        let directDB = try fixture.database("wal-active", blobs: [Fixture.blob(input: 100)])
        let directWriter = try Fixture.open(directDB)
        defer { sqlite3_close(directWriter) }
        try Fixture.execute(directWriter, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try Fixture.insert(directWriter, row: 1, blob: Fixture.blob(input: 110))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: directDB.path)
        try FileManager.default.setAttributes(
            [.modificationDate: activeWalDate],
            ofItemAtPath: directDB.path + "-wal")

        let targetDir = fixture.root.appendingPathComponent("real-targets", isDirectory: true)
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)
        let targetDB = targetDir.appendingPathComponent("target-wal.db")
        let targetWriter = try Fixture.open(targetDB)
        defer { sqlite3_close(targetWriter) }
        try Fixture.execute(targetWriter, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
        try Fixture.insert(targetWriter, row: 0, blob: Fixture.blob(input: 100))
        try Fixture.execute(targetWriter, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0;")
        try Fixture.insert(targetWriter, row: 1, blob: Fixture.blob(input: 105))
        try FileManager.default.setAttributes([.modificationDate: staleDate], ofItemAtPath: targetDB.path)
        try FileManager.default.setAttributes(
            [.modificationDate: activeWalDate],
            ofItemAtPath: targetDB.path + "-wal")

        let symlinkURL = fixture.context.databaseRoots[0].appendingPathComponent("symlinked-wal.db")
        try FileManager.default.createSymbolicLink(at: symlinkURL, withDestinationURL: targetDB)

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .complete)
        #expect(report.statistics.files == 2)
        #expect(report.report.summary?.totalTokens == (187 + 197) + (187 + 192))
    }

    @Test
    func `dayRange fails open on invalid sinceKey and retains databases newer than untilKey`() async throws {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let staleDB = try fixture.database("stale-session", blobs: [Fixture.blob(input: 100)])
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-86400)],
            ofItemAtPath: staleDB.path)

        let afterUntilDate = try #require(CostUsageLocalDay.date(fromKey: "2026-09-15", calendar: Fixture.calendar))
        let activeDB = try fixture.database(
            "active-after-until",
            blobs: [Fixture.blob(input: 110, seconds: 1_787_832_000)])
        try FileManager.default.setAttributes([.modificationDate: afterUntilDate], ofItemAtPath: activeDB.path)

        let failOpenReport = try fixture.report(dayRange: ("not-a-date", "2026-08-27"))
        #expect(failOpenReport.coverage == .complete)
        #expect(failOpenReport.statistics.files == 2)
        #expect(failOpenReport.report.summary?.totalTokens == 187 + 197)

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .complete)
        #expect(report.statistics.files == 1)
        #expect(report.report.summary?.totalTokens == 197)

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 197)
    }

    @Test
    func `all databases skipped by dayRange returns confirmed empty without tokscale fallback`() async throws {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let oldDB = try fixture.database("old-session", blobs: [Fixture.blob(seconds: 1_700_000_000)])
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-86400)],
            ofItemAtPath: oldDB.path)
        try fixture.jsonl([Fixture.cacheUsage])

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .complete)
        #expect(report.report.data.isEmpty)
        #expect(report.report.summary == nil)
        #expect(report.statistics.files == 0)

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.daily.isEmpty)

        // Even with a recent foreign conversation_summaries.db alongside skipped DBs, confirmed empty holds.
        let summaryDir = fixture.context.databaseRoots[1]
        try FileManager.default.createDirectory(at: summaryDir, withIntermediateDirectories: true)
        let summaryDB = summaryDir.appendingPathComponent("conversation_summaries.db")
        let summaryHandle = try Fixture.open(summaryDB)
        defer { sqlite3_close(summaryHandle) }
        try Fixture.execute(summaryHandle, "CREATE TABLE conversation_summaries (id TEXT PRIMARY KEY)")
        try FileManager.default.setAttributes([.modificationDate: Fixture.now], ofItemAtPath: summaryDB.path)

        let withSummaryReport = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(withSummaryReport.coverage == .complete)
        #expect(withSummaryReport.report.data.isEmpty)
        #expect(withSummaryReport.report.summary == nil)
        #expect(withSummaryReport.statistics.foreignDatabases == 1)

        let withSummarySnapshot = try await fixture.snapshot()
        #expect(withSummarySnapshot.historyCoverageIsEstablished)
        #expect(withSummarySnapshot.last30DaysTokens == 0)
        #expect(withSummarySnapshot.daily.isEmpty)
    }

    @Test
    func `graceful capping at databases rows and bytes preserves newest daily history`() throws {
        let fixture = try Fixture()
        let oldestBlob = Fixture.blob(input: 100)
        let middleBlob = Fixture.blob(input: 110)
        let newestBlob = Fixture.blob(input: 120)
        #expect(oldestBlob.count == middleBlob.count)
        #expect(middleBlob.count == newestBlob.count)

        let oldest = try fixture.database("oldest", blobs: [oldestBlob])
        let middle = try fixture.database("middle", blobs: [middleBlob])
        let newest = try fixture.database("newest", blobs: [newestBlob])
        let t0 = Fixture.now.addingTimeInterval(-120)
        try FileManager.default.setAttributes([.modificationDate: t0], ofItemAtPath: oldest.path)
        try FileManager.default.setAttributes([.modificationDate: t0.addingTimeInterval(60)], ofItemAtPath: middle.path)
        try FileManager.default.setAttributes(
            [.modificationDate: t0.addingTimeInterval(120)],
            ofItemAtPath: newest.path)

        var dbLimits = AntigravityLocalReader.Limits()
        dbLimits.databases = 2
        let dbReport = try fixture.report(limits: dbLimits)
        #expect(dbReport.coverage == .partial)
        #expect(!dbReport.isComplete)
        #expect(dbReport.statistics.files == 2)
        #expect(dbReport.report.summary?.totalTokens == 197 + 207)

        var rowLimits = AntigravityLocalReader.Limits()
        rowLimits.rows = 2
        let rowReport = try fixture.report(limits: rowLimits)
        #expect(rowReport.coverage == .partial)
        #expect(rowReport.report.summary?.totalTokens == 197 + 207)
        #expect(rowReport.statistics.sqliteHandlesOpened == rowReport.statistics.sqliteHandlesClosed)

        var byteLimits = AntigravityLocalReader.Limits()
        byteLimits.bytes = newestBlob.count + middleBlob.count
        let byteReport = try fixture.report(limits: byteLimits)
        #expect(byteReport.coverage == .partial)
        #expect(byteReport.report.summary?.totalTokens == 197 + 207)
        #expect(byteReport.statistics.sqliteHandlesOpened == byteReport.statistics.sqliteHandlesClosed)
    }
}

extension AntigravityLocalScanTests {
    @Test(arguments: ["conversation_summaries", "other-foreign"])
    func `rolling window scan with only an old foreign database preserves unavailable without tokscale fallback`(
        name: String) async throws
    {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let foreignDB = root.appendingPathComponent("\(name).db")
        let handle = try Fixture.open(foreignDB)
        defer { sqlite3_close(handle) }
        try Fixture.execute(handle, "CREATE TABLE conversation_summaries (id TEXT PRIMARY KEY)")
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-86400)],
            ofItemAtPath: foreignDB.path)
        try fixture.jsonl([Fixture.cacheUsage])

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .unavailable)
        #expect(!report.isAvailable)
        #expect(report.report.data.isEmpty)
        #expect(report.report.summary == nil)
        #expect(report.statistics.files == 0)
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.foreignDatabases == 1)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)

        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.last30DaysTokens == nil)
    }

    @Test
    func `rolling window scan with recent and old foreign databases preserves unavailable`() async throws {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let recentForeign = root.appendingPathComponent("conversation_summaries.db")
        let recentHandle = try Fixture.open(recentForeign)
        defer { sqlite3_close(recentHandle) }
        try Fixture.execute(recentHandle, "CREATE TABLE conversation_summaries (id TEXT PRIMARY KEY)")
        try FileManager.default.setAttributes([.modificationDate: Fixture.now], ofItemAtPath: recentForeign.path)

        let oldForeign = root.appendingPathComponent("other-foreign.db")
        let oldHandle = try Fixture.open(oldForeign)
        defer { sqlite3_close(oldHandle) }
        try Fixture.execute(oldHandle, "CREATE TABLE unrelated (id TEXT PRIMARY KEY)")
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-86400)],
            ofItemAtPath: oldForeign.path)

        try fixture.jsonl([Fixture.cacheUsage])

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .unavailable)
        #expect(!report.isAvailable)
        #expect(report.statistics.foreignDatabases == 2)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)

        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.last30DaysTokens == nil)
    }

    @Test
    func `rolling window scan with old foreign and history databases verifies history and stays complete`()
        async throws
    {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let oldForeign = root.appendingPathComponent("conversation_summaries.db")
        let foreignHandle = try Fixture.open(oldForeign)
        defer { sqlite3_close(foreignHandle) }
        try Fixture.execute(foreignHandle, "CREATE TABLE conversation_summaries (id TEXT PRIMARY KEY)")
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-3600)],
            ofItemAtPath: oldForeign.path)

        let oldHistory = try fixture.database("old-history", blobs: [Fixture.blob(seconds: 1_700_000_000)])
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-86400)],
            ofItemAtPath: oldHistory.path)
        try fixture.jsonl([Fixture.cacheUsage])

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .complete)
        #expect(report.report.data.isEmpty)
        #expect(report.report.summary == nil)
        #expect(report.statistics.files == 0)
        #expect(report.statistics.rows == 0)
        #expect(report.statistics.foreignDatabases == 1)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 0)
        #expect(snapshot.daily.isEmpty)
    }

    @Test
    func `rolling window scan with only an old drifted database stays partial without fallback`() async throws {
        let fixture = try Fixture()
        let sinceDate = try #require(CostUsageLocalDay.date(fromKey: "2026-07-29", calendar: Fixture.calendar))
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let driftedDB = root.appendingPathComponent("drifted.db")
        let handle = try Fixture.open(driftedDB)
        defer { sqlite3_close(handle) }
        try Fixture.execute(handle, "CREATE TABLE gen_metadata (idx INTEGER, wrong TEXT)")
        try FileManager.default.setAttributes(
            [.modificationDate: sinceDate.addingTimeInterval(-86400)],
            ofItemAtPath: driftedDB.path)
        try fixture.jsonl([Fixture.cacheUsage])

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .partial)
        #expect(!report.isAvailable)
        #expect(report.report.data.isEmpty)
        #expect(report.statistics.foreignDatabases == 0)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)

        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.last30DaysTokens == nil)
    }

    @Test(arguments: [true, false])
    func `rolling window scan with old drifted and supported databases stays partial regardless of order`(
        driftedIsNewer: Bool) async throws
    {
        let fixture = try Fixture()
        let july28 = try #require(CostUsageLocalDay.date(fromKey: "2026-07-28", calendar: Fixture.calendar))
        let july27 = try #require(CostUsageLocalDay.date(fromKey: "2026-07-27", calendar: Fixture.calendar))
        let root = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

        let driftedDB = root.appendingPathComponent("drifted.db")
        let handle = try Fixture.open(driftedDB)
        defer { sqlite3_close(handle) }
        try Fixture.execute(handle, "CREATE TABLE gen_metadata (idx INTEGER, wrong TEXT)")
        try FileManager.default.setAttributes(
            [.modificationDate: driftedIsNewer ? july28 : july27],
            ofItemAtPath: driftedDB.path)

        let supportedDB = try fixture.database("history", blobs: [Fixture.blob(seconds: 1_700_000_000)])
        try FileManager.default.setAttributes(
            [.modificationDate: driftedIsNewer ? july27 : july28],
            ofItemAtPath: supportedDB.path)
        try fixture.jsonl([Fixture.cacheUsage])

        let report = try fixture.report(dayRange: ("2026-07-29", "2026-08-27"))
        #expect(report.coverage == .partial)
        #expect(!report.isAvailable)
        #expect(report.report.data.isEmpty)
        #expect(report.statistics.foreignDatabases == 0)
        #expect(report.statistics.sqliteHandlesOpened == report.statistics.sqliteHandlesClosed)

        let snapshot = try await fixture.snapshot()
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.daily.isEmpty)
        #expect(snapshot.last30DaysTokens == nil)
    }

    @Test
    func `directoryEntries cap overflow retains prior databases and avoids tokscale fallback when empty`() throws {
        let fixture = try Fixture()
        let root0 = fixture.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: root0, withIntermediateDirectories: true)
        try fixture.database("db-1", rootIndex: 0, blobs: [Fixture.blob(input: 100)])
        try fixture.database("db-2", rootIndex: 0, blobs: [Fixture.blob(input: 110)])
        try "extra".write(to: root0.appendingPathComponent("note-1.txt"), atomically: true, encoding: .utf8)
        try "extra".write(to: root0.appendingPathComponent("note-2.txt"), atomically: true, encoding: .utf8)

        var capLimits = AntigravityLocalReader.Limits()
        capLimits.directoryEntries = 3
        let budget = AntigravityLocalReader.Budget(limits: capLimits, cancellation: {})
        let discovery = try AntigravityLocalReader.discover(
            roots: fixture.context.databaseRoots,
            extension: "db",
            budget: budget)
        #expect(!discovery.isComplete)
        #expect(!discovery.paths.isEmpty)

        let partialReport = try fixture.report(limits: capLimits)
        #expect(partialReport.coverage == .partial)
        #expect(!partialReport.report.data.isEmpty)

        let emptyOverflow = try Fixture()
        let emptyRoot = emptyOverflow.context.databaseRoots[0]
        try FileManager.default.createDirectory(at: emptyRoot, withIntermediateDirectories: true)
        for index in 0..<4 {
            try "txt".write(
                to: emptyRoot.appendingPathComponent("non-db-\(index).txt"),
                atomically: true,
                encoding: .utf8)
        }
        try emptyOverflow.jsonl([Fixture.cacheUsage])
        let emptyPartial = try emptyOverflow.report(limits: capLimits)
        #expect(emptyPartial.coverage == .partial)
        #expect(emptyPartial.report.data.isEmpty)
        #expect(emptyPartial.report.summary == nil)
    }

    @Test
    func `duration exhaustion in multi-file JSONL retains partial history`() throws {
        let jsonlFixture = try Fixture()
        let j1 = try jsonlFixture.jsonl([Fixture.cacheUsage], session: "j1")
        let j2Line = #"{"type":"usage","sessionId":"j2-session","input":200,"output":40,"#
            + #""cacheRead":0,"cacheWrite":0,"reasoning":0,"timestamp":1787832100000,"responseId":null}"#
        let j2 = try jsonlFixture.jsonl([j2Line], session: "j2")
        try FileManager.default.setAttributes([.modificationDate: Fixture.now], ofItemAtPath: j1.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Fixture.now.addingTimeInterval(-60)],
            ofItemAtPath: j2.path)

        var jsonlWarmTicks = 0
        let firstOnlyBudget = AntigravityLocalReader.Budget(
            limits: .init(),
            clock: {
                defer { jsonlWarmTicks += 1 }
                return 0
            },
            cancellation: {})
        _ = try AntigravityLocalReader.readJSONL([j1], budget: firstOnlyBudget)

        var jsonlTick = 0
        var jsonlLimits = AntigravityLocalReader.Limits()
        jsonlLimits.duration = 5
        let jsonlBudget = AntigravityLocalReader.Budget(
            limits: jsonlLimits,
            clock: {
                defer { jsonlTick += 1 }
                return jsonlTick > jsonlWarmTicks ? 10.0 : 0.0
            },
            cancellation: {})
        let jsonlPartial = try AntigravityLocalReader.readJSONL([j1, j2], budget: jsonlBudget)
        #expect(!jsonlPartial.isComplete)
        #expect(jsonlPartial.containsHistorySource)
        #expect(jsonlPartial.events.map(\.session) == ["cache-session"])
    }

    @Test
    func `equal mtime across multi-root discovery breaks ties by path and marks partial`() throws {
        let fixture = try Fixture()
        let sharedTime = Fixture.now
        let root0DB = try fixture.database("root0-session", rootIndex: 0, blobs: [Fixture.blob(input: 100)])
        let root2DB = try fixture.database("root2-session", rootIndex: 2, blobs: [Fixture.blob(input: 200)])
        try FileManager.default.setAttributes([.modificationDate: sharedTime], ofItemAtPath: root0DB.path)
        try FileManager.default.setAttributes([.modificationDate: sharedTime], ofItemAtPath: root2DB.path)

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1
        let discovery = try AntigravityLocalReader.discover(
            roots: fixture.context.databaseRoots,
            extension: "db",
            budget: AntigravityLocalReader.Budget(limits: limits, cancellation: {}))
        let expectedWinner = try #require([root0DB, root2DB]
            .map { $0.standardizedFileURL.resolvingSymlinksInPath() }
            .min { $0.path < $1.path })
        #expect(!discovery.isComplete)
        #expect(discovery.paths.map { $0.standardizedFileURL.resolvingSymlinksInPath() } == [expectedWinner])

        let partial = try fixture.report(limits: limits)
        let tokenSnapshot = CostUsageFetcher.tokenSnapshot(
            from: partial.report,
            now: Fixture.now,
            historyDays: 30,
            useCurrentLocalDayForSession: true,
            calendar: Fixture.calendar,
            historyCoverageIsEstablished: partial.isComplete,
            historyScanIsPartial: !partial.isComplete)
        #expect(partial.coverage == .partial)
        #expect(tokenSnapshot.historyScanIsPartial)
        #expect(!tokenSnapshot.historyCoverageIsEstablished)
        #expect(!tokenSnapshot.daily.isEmpty)
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
