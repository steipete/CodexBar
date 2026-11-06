import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageStoreCheckpointTests {
    @Test
    func `unchanged refreshes persist freshness without forced checkpoints`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        _ = await fixture.store.fileSizeBytes()
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        for _ in 0..<3 {
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            var refreshed = loaded.cache
            refreshed.lastScanUnixMs += 1_200_000
            let incoming = refreshed
            let before = await fixture.store.persistenceWriteMetricsForTesting()
            let (saved, work) = try await fixture.store.measureSQLWork { store in
                store.saveCodexCache(
                    incoming,
                    calendar: fixture.calendar,
                    requestedScanWindow: (sinceKey: fixture.range.scanSinceKey, untilKey: fixture.range.scanUntilKey),
                    skipIdenticalContent: true,
                    receipt: loaded.receipt)
            }
            let after = await fixture.store.persistenceWriteMetricsForTesting()
            #expect(!saved.catchUpRequired)
            #expect(work.checkpoints == 0)
            #expect(after.rows - before.rows == 1)
            let reader = CostUsageStore(cacheRoot: fixture.env.cacheRoot, home: fixture.env.codexStoreHome)
            #expect(reader.syncLoadCodexCache(calendar: fixture.calendar).lastScanUnixMs == incoming.lastScanUnixMs)
            let report = fixture.fullReport(reader.syncLoadCodexCache(calendar: fixture.calendar))
            let reportBytes = try encoder.encode(report)
            let expectedBytes = try encoder.encode(fixture.fullReport(fixture.canonical))
            #expect(reportBytes == expectedBytes)
        }
    }

    @Test
    func `an active WAL reader does not force a checkpoint for unchanged freshness`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        // The held read snapshot never blocks: this writer's SQLite busy timeout is zero.
        let writer = CostUsageStore(
            cacheRoot: fixture.env.cacheRoot,
            home: fixture.env.codexStoreHome,
            busyTimeoutMilliseconds: 0)
        let reader = try BaselineSQLiteConnection(url: writer.databaseURL)
        try reader.execute("BEGIN; SELECT payload FROM scan_metadata")
        defer { try? reader.execute("ROLLBACK") }
        let loaded = writer.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var refreshed = loaded.cache
        refreshed.lastScanUnixMs += 1_200_000
        let incoming = refreshed
        let (saved, work) = try await writer.measureSQLWork { store in
            store.saveCodexCache(
                incoming,
                calendar: fixture.calendar,
                requestedScanWindow: (sinceKey: fixture.range.scanSinceKey, untilKey: fixture.range.scanUntilKey),
                skipIdenticalContent: true,
                receipt: loaded.receipt)
        }
        #expect(!saved.catchUpRequired)
        #expect(work.checkpoints == 0)
        #expect(await fixture.store.fetchMetadata().lastScanUnixMs == incoming.lastScanUnixMs)
    }

    @Test
    func `protected WAL pages still count against byte budgets`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        #expect(await fixture.store.setWALAutoCheckpointForTesting(0))
        let previousBytes = await fixture.store.fileSizeBytes()
        let path = try #require(fixture.canonical.files.keys.min())
        let originalRows = await fixture.store.fetchUsageRows(path: path)
        let original = try #require(originalRows.first)
        var row = try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: original.payload)
        row.turnID = String(repeating: "synthetic", count: 32 * 1024)
        let payload = try JSONEncoder().encode(row)
        #expect(await fixture.store.appendUsageRows([
            CostUsageStoreUsageRow(path: path, rowIndex: original.rowIndex, payload: payload),
        ]))
        let databaseAttributes = try FileManager.default.attributesOfItem(atPath: fixture.store.databaseURL.path)
        let walAttributes = try FileManager.default.attributesOfItem(atPath: fixture.store.databaseURL.path + "-wal")
        let databaseBytes = try #require(databaseAttributes[.size] as? NSNumber)
        let walBytes = try #require(walAttributes[.size] as? NSNumber)
        #expect(databaseBytes.int64Value == previousBytes)
        #expect(walBytes.int64Value > 256 * 1024)

        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        var refreshed = loaded.cache
        refreshed.lastScanUnixMs += 1_200_000
        let incoming = refreshed
        let (result, work) = try await fixture.store.measureSQLWork { store in
            store.saveCodexCache(
                incoming,
                calendar: fixture.calendar,
                requestedScanWindow: (sinceKey: fixture.range.scanSinceKey, untilKey: fixture.range.scanUntilKey),
                fileBudgetBytes: previousBytes,
                skipIdenticalContent: true,
                receipt: loaded.receipt)
        }
        #expect(!result.catchUpRequired)
        #expect(result.deletedRows == 0)
        #expect(result.rowCount == 2)
        #expect(result.fileBytes > previousBytes)
        #expect(work.checkpoints == 0)
        let retainedRows = await fixture.store.fetchUsageRows(path: path)
        #expect(retainedRows.first(where: { $0.rowIndex == original.rowIndex })?.payload == payload)
    }

    @Test
    func `a pinned reader keeps physical database bytes in the budget after vacuum`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = CostUsageStore(
            cacheRoot: fixture.env.cacheRoot,
            home: fixture.env.codexStoreHome,
            busyTimeoutMilliseconds: 0)
        #expect(await writer.setWALAutoCheckpointForTesting(0))
        let path = try #require(fixture.canonical.files.keys.min())
        let originalRows = await writer.fetchUsageRows(path: path)
        let original = try #require(originalRows.first)
        var row = try JSONDecoder().decode(CostUsageScanner.CodexUsageRow.self, from: original.payload)
        row.turnID = String(repeating: "synthetic", count: 32 * 1024)
        let payload = try JSONEncoder().encode(row)
        #expect(await writer.appendUsageRows([
            CostUsageStoreUsageRow(path: path, rowIndex: original.rowIndex, payload: payload),
        ]))
        let beforeBytes = await writer.fileSizeBytes()
        let limit = beforeBytes / 2
        let reader = try BaselineSQLiteConnection(url: writer.databaseURL)
        try reader.execute("BEGIN; SELECT sum(length(payload)) FROM usage_rows")
        defer { try? reader.execute("ROLLBACK") }
        #expect(await writer.replaceUsageRows(path: path, rows: []))

        let (result, work) = try await writer.measureSQLWork { store in
            store.enforceBudgets(
                maxRows: .max,
                maxFileBytes: limit,
                requestedSinceDay: fixture.range.scanSinceKey,
                requestedUntilDay: fixture.range.scanUntilKey,
                calendar: fixture.calendar)
        }
        let attributes = try FileManager.default.attributesOfItem(atPath: writer.databaseURL.path)
        let diskBytes = try #require(attributes[.size] as? NSNumber)
        let liveBytes = await writer.withDatabase(default: Int64.max) { database in
            try CostUsageStore.scalarInt(database, "PRAGMA page_count")
                * CostUsageStore.scalarInt(database, "PRAGMA page_size")
        }
        #expect(work.checkpoints > 0)
        #expect(liveBytes < limit)
        #expect(diskBytes.int64Value == beforeBytes)
        #expect(result.fileBytes == diskBytes.int64Value)
        #expect(result.fileBytes > limit)
        #expect(result.deletedRows == 0)
        #expect(!result.catchUpRequired)
        try reader.execute("ROLLBACK")
        #expect(await writer.fileSizeBytes() < beforeBytes)
    }
}
