import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [false, true])
    func `lean cache preserves full cache fields without token histories`(incomplete: Bool) throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: incomplete)
        defer { fixture.remove() }
        let full = CostUsageStoreAccess.read(cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar)
        #expect(full == fixture.canonical)
        #expect(full.files.values.allSatisfy { $0.codexTokenSnapshots?.count == 4 })
        #expect(full.files.values.allSatisfy { $0.codexTokenCheckpoints != nil })

        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let lean = CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        let work = recorder.snapshot()
        #expect(lean == Self.cacheWithoutTokenHistories(full))
        #expect(lean.files.values.allSatisfy { $0.codexTokenSnapshots == nil })
        #expect(lean.files.values.allSatisfy { $0.codexTokenCheckpoints == nil })
        #expect(lean.codexScanCatchUpPending == incomplete)
        #expect(work.fullSnapshotReads == 0)
        #expect(work.scannerSnapshotReads == 1)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.fileRows == fixture.fileCount)
        #expect(work.usageRows == fixture.rowCount)
        #expect(work.usageRowDecodeAttempts == fixture.rowCount)
        #expect(work.usagePayloadBytes > 0)
        #expect(work.accumulatorRows == fixture.fileCount)
        #expect(work.bufferedLines == (incomplete ? 1 : 0))
        #expect(work.cacheConversions == 1)
    }

    @Test
    func `lean cache rejects a different timezone`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var otherCalendar = fixture.calendar
        otherCalendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))

        #expect(CostUsageStoreAccess.read(
            cacheRoot: fixture.env.cacheRoot,
            calendar: otherCalendar) == CostUsageCache())
        #expect(CostUsageStoreAccess.readWithoutTokenSnapshots(
            cacheRoot: fixture.env.cacheRoot,
            calendar: otherCalendar) == CostUsageCache())
    }

    @Test
    func `lean cache reconciles completed catch up without changing persistence`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var metadata = await fixture.store.fetchMetadata()
        metadata.catchUpPending = true
        metadata.completedFiles = 0
        metadata.processedBytes = 0
        #expect(await fixture.store.setMetadata(metadata))

        let full = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
        let lean = fixture.store.syncLoadCodexCache(calendar: fixture.calendar, loadTokenSnapshots: false)
        #expect(full == fixture.canonical)
        #expect(lean == Self.cacheWithoutTokenHistories(full))
        #expect(lean.codexScanCatchUpPending == false)
        #expect(lean.codexScanCompletedFiles == fixture.fileCount)
        #expect(lean.codexScanProcessedBytes == fixture.canonical.codexScanTotalBytes)
        #expect(await fixture.store.fetchMetadata() == metadata)
    }

    @Test
    func `lean cache keeps its readable snapshot during an external commit`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        CostUsageStore.codexCacheReadCheckpointForTesting = (fixture.store.databaseURL, {
            try writer.execute("UPDATE files SET parsed_bytes = 999999")
        })
        defer { CostUsageStore.codexCacheReadCheckpointForTesting = nil }

        let lean = fixture.store.syncLoadCodexCache(calendar: fixture.calendar, loadTokenSnapshots: false)
        CostUsageStore.codexCacheReadCheckpointForTesting = nil

        #expect(lean == Self.cacheWithoutTokenHistories(fixture.canonical))
        #expect(lean.files.count == fixture.fileCount)
        #expect(lean.files.values.allSatisfy { $0.parsedBytes != 999_999 })
        let current = await fixture.store.readSnapshot()
        #expect(current.files.count == fixture.fileCount)
        #expect(current.files.allSatisfy { $0.parsedBytes == 999_999 })
        #expect(await fixture.store.retainedCodexBaselineCountForTesting == 0)
        #expect(await fixture.store.rebuildCount == 0)
    }

    private static func cacheWithoutTokenHistories(_ cache: CostUsageCache) -> CostUsageCache {
        var cache = cache
        cache.files = cache.files.mapValues { usage in
            var usage = usage
            usage.codexTokenSnapshots = nil
            usage.codexTokenCheckpoints = nil
            return usage
        }
        return cache
    }
}
