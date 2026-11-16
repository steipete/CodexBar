import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCLI
@testable import CodexBarCore
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

struct AntigravityIncrementalScanTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test
    func `generation and step timestamp rows exceeding batch row budget converge across batches`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)

        for index in 0..<3 {
            let stepUUID = "step-\(index)"
            try fixture.database(
                "session-\(index)",
                blobs: [
                    Fixture.blob(seconds: 1_787_832_000),
                    Fixture.blobWithRootEnvelope(stepUUID: stepUUID, seconds: nil),
                ],
                stepBlobs: [
                    Fixture.stepMetadataBlob(stepUUID: "other-\(index)-a", seconds: 1_787_832_000),
                    Fixture.stepMetadataBlob(stepUUID: "other-\(index)-b", seconds: 1_787_832_000),
                    Fixture.stepMetadataBlob(stepUUID: stepUUID, seconds: 1_787_832_000),
                ])
        }

        // Uncached reference scan with generous limits.
        let reference = try fixture.report()
        #expect(reference.coverage == .complete)
        #expect(reference.report.summary?.totalTokens == 6 * 187)
        #expect(reference.statistics.rows == 15)

        // Each DB takes 2 gen + 3 step = 5 rows; a batch budget of 12 finishes 2 DBs and trips on the 3rd.
        var limits = AntigravityLocalReader.Limits()
        limits.rows = 12

        let batch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch1.coverage == .partial)
        #expect(batch1.catchUpPending)
        #expect(batch1.batchMadeProgress)
        #expect(batch1.statistics.files == 3)
        #expect(batch1.report.summary?.totalTokens == 4 * 187)

        let batch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch2.coverage == .complete)
        #expect(!batch2.catchUpPending)
        #expect(batch2.batchMadeProgress)
        #expect(batch2.statistics.files == 1)
        #expect(batch2.statistics.rows == 5)
        #expect(batch2.report.summary?.totalTokens == reference.report.summary?.totalTokens)
        #expect(batch2.report.data.map(\.date) == reference.report.data.map(\.date))
        #expect(batch2.report.data.map(\.totalTokens) == reference.report.data.map(\.totalTokens))

        // Subsequent launch/refresh reuses cached conversations without opening SQLite.
        let batch3 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch3.coverage == .complete)
        #expect(!batch3.catchUpPending)
        #expect(!batch3.batchMadeProgress)
        #expect(batch3.statistics.files == 0)
        #expect(batch3.statistics.sqliteHandlesOpened == 0)
        #expect(batch3.report.summary?.totalTokens == 6 * 187)
    }

    @Test
    func `histories exceeding database cap complete across bounded batches without restarting prefix`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        for index in 0..<5 {
            try fixture.database("conv-\(index)", blobs: [Fixture.blob()])
        }

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 2

        let batch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch1.coverage == .partial)
        #expect(batch1.catchUpPending)
        #expect(batch1.batchMadeProgress)
        #expect(batch1.statistics.files == 2)
        #expect(batch1.report.summary?.totalTokens == 2 * 187)

        let batch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch2.coverage == .partial)
        #expect(batch2.catchUpPending)
        #expect(batch2.batchMadeProgress)
        #expect(batch2.statistics.files == 2)
        #expect(batch2.report.summary?.totalTokens == 4 * 187)

        let batch3 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch3.coverage == .complete)
        #expect(!batch3.catchUpPending)
        #expect(batch3.batchMadeProgress)
        #expect(batch3.statistics.files == 1)
        #expect(batch3.report.summary?.totalTokens == 5 * 187)
    }

    @Test
    func `byte and duration caps persist completed databases and resume`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let blob = Fixture.blob()
        try fixture.database("a", blobs: [blob])
        try fixture.database("b", blobs: [blob])

        var byteLimits = AntigravityLocalReader.Limits()
        byteLimits.bytes = blob.count
        let byteBatch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: byteLimits)
        #expect(byteBatch1.coverage == .partial)
        #expect(byteBatch1.catchUpPending)
        #expect(byteBatch1.batchMadeProgress)
        #expect(byteBatch1.report.summary?.totalTokens == 187)

        let byteBatch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: byteLimits)
        #expect(byteBatch2.coverage == .complete)
        #expect(!byteBatch2.catchUpPending)
        #expect(byteBatch2.statistics.files == 1)
        #expect(byteBatch2.report.summary?.totalTokens == 2 * 187)

        // Duration budget exhaustion preserves completed DBs from the batch.
        var measuredTicks: TimeInterval = 0
        var probeLimits = AntigravityLocalReader.Limits()
        probeLimits.duration = 1000
        let probeCacheRoot = fixture.root.appendingPathComponent("probe-time-cache", isDirectory: true)
        let probeResult = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: probeCacheRoot,
            now: Fixture.now,
            limits: probeLimits,
            clock: {
                defer { measuredTicks += 1 }
                return measuredTicks
            })
        #expect(probeResult.coverage == .complete)
        let timeCacheRoot = fixture.root.appendingPathComponent("time-cache", isDirectory: true)
        var ticks: TimeInterval = 0
        var timeLimits = AntigravityLocalReader.Limits()
        timeLimits.duration = measuredTicks - 5
        let timeBatch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: timeCacheRoot,
            now: Fixture.now,
            limits: timeLimits,
            clock: {
                defer { ticks += 1 }
                return ticks
            })
        #expect(timeBatch1.coverage == .partial)
        #expect(timeBatch1.catchUpPending)
        #expect(timeBatch1.batchMadeProgress)
        #expect(timeBatch1.report.summary?.totalTokens == 187)

        ticks = 0
        let timeBatch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: timeCacheRoot,
            now: Fixture.now,
            limits: timeLimits,
            clock: {
                defer { ticks += 1 }
                return ticks
            })
        #expect(timeBatch2.coverage == .complete)
        #expect(!timeBatch2.catchUpPending)
        #expect(timeBatch2.statistics.files == 1)
        #expect(timeBatch2.report.summary?.totalTokens == 2 * 187)
    }

    @Test
    func `active WAL, growing, replaced, deleted, and version-bumped caches invalidate cleanly`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let db1 = try fixture.database("live")
        let writer = try Fixture.open(db1)
        var writerClosed = false
        defer { if !writerClosed { sqlite3_close(writer) } }
        try Fixture.execute(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try Fixture.insert(writer, row: 0, blob: Fixture.blob())

        let initial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(initial.coverage == .complete)
        #expect(initial.report.summary?.totalTokens == 187)
        #expect(initial.statistics.files == 1)

        // Read-only SHM coordination must not invalidate the cached WAL database when no writer wrote.
        let cachedWAL = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(cachedWAL.coverage == .complete)
        #expect(cachedWAL.statistics.files == 0)
        #expect(cachedWAL.statistics.sqliteHandlesOpened == 0)
        #expect(cachedWAL.report.summary?.totalTokens == 187)

        // Growing the WAL invalidates only the changed database without double-counting prior rows.
        try Fixture.insert(writer, row: 1, blob: Fixture.blob(response: "second-turn"))
        let grown = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(grown.coverage == .complete)
        #expect(grown.statistics.files == 1)
        #expect(grown.report.summary?.totalTokens == 2 * 187)
        _ = sqlite3_close(writer)
        writerClosed = true

        // Replacing the database file at the same path invalidates its cache entry.
        try? FileManager.default.removeItem(atPath: db1.path + "-wal")
        try? FileManager.default.removeItem(atPath: db1.path + "-shm")
        let replacementURL = fixture.root.appendingPathComponent("replacement.db")
        let replacement = try Fixture.open(replacementURL)
        try Fixture.execute(replacement, "CREATE TABLE gen_metadata (idx INTEGER PRIMARY KEY, data BLOB)")
        try Fixture.insert(replacement, row: 0, blob: Fixture.blob(input: 500, output: 100, cacheRead: 0, reasoning: 0))
        sqlite3_close(replacement)
        try FileManager.default.removeItem(at: db1)
        try FileManager.default.moveItem(at: replacementURL, to: db1)

        let replaced = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(replaced.coverage == .complete)
        #expect(replaced.statistics.files == 1)
        #expect(replaced.report.summary?.totalTokens == 600)

        // Tampering the persisted cache version forces a clean re-scan of unchanged files.
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])
        let cacheURL = AntigravityLocalScanCacheIO.cacheFileURL(cacheRoot: cacheRoot, scope: scope)
        var rawCache = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: cacheURL)) as? [String: Any])
        rawCache["version"] = 999
        let tamperedData = try JSONSerialization.data(withJSONObject: rawCache)
        try tamperedData.write(to: cacheURL, options: [.atomic])

        let afterVersionBump = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(afterVersionBump.coverage == .complete)
        #expect(afterVersionBump.statistics.files == 1)
        #expect(afterVersionBump.report.summary?.totalTokens == 600)

        // Deleting a database evicts its cached contribution.
        try fixture.database("second", blobs: [Fixture.blob()])
        let withTwo = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(withTwo.report.summary?.totalTokens == 600 + 187)
        try FileManager.default.removeItem(at: db1)
        let afterDelete = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(afterDelete.coverage == .complete)
        #expect(afterDelete.statistics.files == 0)
        #expect(afterDelete.report.summary?.totalTokens == 187)
    }

    @Test
    func `retained complete snapshot keeps original freshness while partial batches label incomplete`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let t1 = Date(timeIntervalSince1970: 1_787_832_000)
        let t2 = Date(timeIntervalSince1970: 1_787_918_400)

        try fixture.database("initial", blobs: [Fixture.blob(seconds: 1_787_832_000)])
        let complete = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: t1)
        #expect(complete.coverage == .complete)
        #expect(complete.retainedUpdatedAt == nil)
        #expect(complete.report.summary?.totalTokens == 187)

        // Add two new databases and restrict the batch cap to 1 so catch-up spans two passes.
        try fixture.database("new-1", blobs: [Fixture.blob(seconds: 1_787_918_400)])
        try fixture.database("new-2", blobs: [Fixture.blob(seconds: 1_787_918_400)])
        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1

        let catchingUp = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: t2,
            limits: limits)
        #expect(catchingUp.coverage == .partial)
        #expect(catchingUp.catchUpPending)
        #expect(catchingUp.batchMadeProgress)
        #expect(catchingUp.retainedUpdatedAt == t1)
        #expect(catchingUp.report.summary?.totalTokens == 187)

        let finished = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: t2,
            limits: limits)
        #expect(finished.coverage == .complete)
        #expect(!finished.catchUpPending)
        #expect(finished.retainedUpdatedAt == nil)
        #expect(finished.report.summary?.totalTokens == 3 * 187)
    }

    @Test
    func `cross-database deduplication and contradictions work across cached and newly scanned databases`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        try fixture.database(rootIndex: 0, blobs: [Fixture.blob(response: "shared-resp")])
        let first = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(first.coverage == .complete)
        #expect(first.report.summary?.totalTokens == 187)

        // Second database copies the exact same response -> must deduplicate against the cached DB.
        let secondURL = try fixture.database(rootIndex: 1, blobs: [Fixture.blob(response: "shared-resp")])
        let deduped = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(deduped.coverage == .complete)
        #expect(deduped.statistics.files == 1)
        #expect(deduped.report.summary?.totalTokens == 187)

        // Contradictory copy in rootIndex 1 must still be flagged as contradicted & partial.
        try FileManager.default.removeItem(at: secondURL)
        try fixture.database(
            rootIndex: 1,
            blobs: [Fixture.blob(input: 999, response: "shared-resp")])
        let contradicted = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(contradicted.coverage == .partial)
        #expect(contradicted.evidenceIsContradicted)
        #expect(contradicted.retainedUpdatedAt == nil)
    }

    @Test
    func `initial partial batch without prior complete snapshot stays incomplete across UI and CLI`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        try fixture.database("a", blobs: [Fixture.blob(seconds: 1_787_832_000)])
        try fixture.database("b", blobs: [Fixture.blob(seconds: 1_787_745_600)])

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1
        let partial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(partial.coverage == .partial)
        #expect(partial.retainedUpdatedAt == nil)

        let snapshot = CostUsageFetcher.tokenSnapshot(
            from: partial.report,
            now: Fixture.now,
            historyDays: 30,
            calendar: Fixture.calendar,
            historyCoverageIsEstablished: partial.isComplete,
            historyScanIsPartial: !partial.isComplete)
        #expect(!snapshot.historyCoverageIsEstablished)
        #expect(snapshot.historyScanIsPartial)
        #expect(!snapshot.historyIsFullyScanned)
        let cliText = CodexBarCLI.renderCostText(provider: .antigravity, snapshot: snapshot, useColor: false)
        #expect(cliText.contains("Partial local history · recorded token subtotal"))
    }

    @Test
    func `foreign-only databases return unavailable and clear stale retained complete snapshot`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let dbURL = try fixture.database("conv", blobs: [Fixture.blob()])

        let initial = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(initial.coverage == .complete)
        #expect(initial.report.summary?.totalTokens == 187)

        // Replace with a foreign SQLite database (no gen_metadata table).
        try FileManager.default.removeItem(at: dbURL)
        let foreign = try Fixture.open(dbURL)
        try Fixture.execute(foreign, "CREATE TABLE other (id INTEGER PRIMARY KEY)")
        sqlite3_close(foreign)

        let afterForeign = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now)
        #expect(afterForeign.coverage == .unavailable)
        #expect(afterForeign.report.data.isEmpty)
        #expect(afterForeign.retainedUpdatedAt == nil)
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])
        let persisted = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: cacheRoot, scope: scope)
        #expect(persisted.retainedComplete == nil)
    }

    @Test
    @MainActor
    func `usage store catch-up converges across batches without disturbing quota bars`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture)

        let quotaSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 25, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: Fixture.now)
        store._setSnapshotForTesting(quotaSnapshot, provider: .antigravity)

        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 100,
                outputTokens: 37,
                totalTokens: 187,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 374,
            sessionCostUSD: nil,
            last30DaysTokens: 374,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 200,
                outputTokens: 74,
                totalTokens: 374,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)

        var calls = 0
        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            calls += 1
            switch calls {
            case 1:
                // First batch scanned empty recent DBs and still made progress.
                return CostUsageTokenResult(
                    snapshot: CostUsageTokenSnapshot(
                        sessionTokens: nil,
                        sessionCostUSD: nil,
                        last30DaysTokens: nil,
                        last30DaysCostUSD: nil,
                        historyDays: 30,
                        historyCoverageIsEstablished: false,
                        historyScanIsPartial: true,
                        daily: [],
                        updatedAt: Fixture.now),
                    antigravityCatchUpPending: true,
                    antigravityCatchUpMadeProgress: true)
            case 2:
                return CostUsageTokenResult(
                    snapshot: partialSnapshot,
                    antigravityCatchUpPending: true,
                    antigravityCatchUpMadeProgress: true)
            default:
                return CostUsageTokenResult(
                    snapshot: completeSnapshot,
                    antigravityCatchUpPending: false,
                    antigravityCatchUpMadeProgress: true)
            }
        }

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.antigravityCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        #expect(calls == 3)
        #expect(store.tokenSnapshot(for: .antigravity)?.last30DaysTokens == 374)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyIsFullyScanned == true)
        #expect(store.tokenError(for: .antigravity) == nil)
        #expect(store.snapshot(for: .antigravity)?.primary?.usedPercent == 25)
        #expect(store.snapshot(for: .antigravity)?.secondary?.usedPercent == 40)
    }

    @Test
    func `cached root-envelope turns preserve stepUUID without false contradiction`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let dbCached = try fixture.database(
            rootIndex: 0,
            blobs: [
                Fixture.blobWithRootEnvelope(
                    stepUUID: "step-shared",
                    response: "resp-shared",
                    seconds: 1_787_832_000),
            ])
        let dbFresh = try fixture.database(
            rootIndex: 1,
            blobs: [
                Fixture.blobWithRootEnvelope(
                    stepUUID: "step-shared",
                    response: "resp-shared",
                    seconds: 1_787_832_000),
            ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_787_832_100)],
            ofItemAtPath: dbCached.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_787_832_000)],
            ofItemAtPath: dbFresh.path)

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1

        let batch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch1.coverage == .partial)
        #expect(batch1.catchUpPending)
        #expect(batch1.batchMadeProgress)

        let batch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch2.coverage == .complete)
        #expect(!batch2.evidenceIsContradicted)
        #expect(batch2.report.summary?.totalTokens == 187)
    }

    @Test
    func `failed cache persistence clears batchMadeProgress to prevent repeated prefix loops`() throws {
        let fixture = try Fixture()
        try fixture.database("conv-a", blobs: [Fixture.blob()])
        try fixture.database("conv-b", blobs: [Fixture.blob()])

        let blockingFile = fixture.root.appendingPathComponent("not-a-directory")
        try Data("block".utf8).write(to: blockingFile)

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1

        let batch = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: blockingFile,
            now: Fixture.now,
            limits: limits)
        #expect(batch.coverage == .partial)
        #expect(batch.catchUpPending)
        #expect(!batch.batchMadeProgress)
    }

    @Test
    func `active WAL database sorts ahead of stale main databases when batch budget is capped`() throws {
        let fixture = try Fixture()
        let cacheRoot = fixture.root.appendingPathComponent("scan-cache", isDirectory: true)
        let dbStale = try fixture.database(
            "stale-closed",
            blobs: [
                Fixture.blob(
                    input: 10,
                    output: 5,
                    cacheRead: 0,
                    reasoning: 0,
                    seconds: 1_787_832_000),
            ])
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_787_000_000)],
            ofItemAtPath: dbStale.path)

        let dbActiveWAL = try fixture.database("active-wal")
        let writer = try Fixture.open(dbActiveWAL)
        defer { sqlite3_close(writer) }
        try Fixture.execute(writer, "PRAGMA journal_mode=WAL; PRAGMA wal_autocheckpoint=0")
        try Fixture.insert(
            writer,
            row: 0,
            blob: Fixture.blob(
                input: 300,
                output: 100,
                cacheRead: 0,
                reasoning: 0,
                seconds: 1_787_832_000))
        // Main DB stays older than `dbStale`, while `-wal` carries the most recent activity.
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_786_000_000)],
            ofItemAtPath: dbActiveWAL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_787_832_500)],
            ofItemAtPath: dbActiveWAL.path + "-wal")

        var limits = AntigravityLocalReader.Limits()
        limits.databases = 1

        let batch1 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch1.coverage == .partial)
        #expect(batch1.catchUpPending)
        #expect(batch1.report.summary?.totalTokens == 400)

        let batch2 = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            scanCacheRoot: cacheRoot,
            now: Fixture.now,
            limits: limits)
        #expect(batch2.coverage == .complete)
        #expect(!batch2.catchUpPending)
        #expect(batch2.report.summary?.totalTokens == 415)
    }
}

extension AntigravityIncrementalScanTests {
    @Test
    @MainActor
    func `clearCostUsageCache drains in-flight antigravity catch-up before deleting cache`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture)
        let cacheDir = UsageStore.costUsageCacheDirectory(fileManager: IsolatedCacheFileManager(root: fixture.root))

        var pass2StartedContinuation: AsyncStream<Void>.Continuation?
        let pass2Started = AsyncStream<Void> { continuation in
            pass2StartedContinuation = continuation
        }
        var calls = 0
        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: Fixture.now)

        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                return CostUsageTokenResult(
                    snapshot: partialSnapshot,
                    antigravityCatchUpPending: true,
                    antigravityCatchUpMadeProgress: true)
            }
            pass2StartedContinuation?.finish()
            try? await Task.sleep(for: .milliseconds(50))
            let recreatedDir = cacheDir.appendingPathComponent("antigravity-local-v1", isDirectory: true)
            try FileManager.default.createDirectory(at: recreatedDir, withIntermediateDirectories: true)
            try Data("{\"version\":2}".utf8).write(to: recreatedDir.appendingPathComponent("cache.json"))
            return CostUsageTokenResult(
                snapshot: partialSnapshot,
                antigravityCatchUpPending: false,
                antigravityCatchUpMadeProgress: true)
        }

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        for await _ in pass2Started {}

        let root = fixture.root
        let error = await store.clearCostUsageCache(fileManagerFactory: { IsolatedCacheFileManager(root: root) })
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        #expect(error == nil)
        #expect(store.antigravityCostCatchUpTask == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
    }

    @Test
    @MainActor
    func `antigravity catch-up honors low power mode and thermal throttling between passes`() async throws {
        let fixture = try Fixture()
        let lowPowerStore = try self.makeIsolatedStore(fixture: fixture, lowPowerPreference: .on)
        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: Fixture.now)

        var lowPowerDelays: [TimeInterval] = []
        lowPowerStore._test_antigravityCostCatchUpSleepOverride = { delay in
            lowPowerDelays.append(delay)
            throw CancellationError()
        }
        lowPowerStore._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            CostUsageTokenResult(
                snapshot: partialSnapshot,
                antigravityCatchUpPending: true,
                antigravityCatchUpMadeProgress: true)
        }

        await lowPowerStore.refreshTokenUsageNow(for: .antigravity, force: true)
        await lowPowerStore.antigravityCostCatchUpTask?.value
        lowPowerStore._test_tokenUsageResultLoaderOverride = nil
        #expect(lowPowerDelays == [BackgroundWorkPowerPolicy.lowPowerMinimumInterval])

        let thermalStore = try self.makeIsolatedStore(fixture: fixture, lowPowerPreference: .off)
        var thermalState: ProcessInfo.ThermalState = .serious
        thermalStore._test_antigravityCostCatchUpResourceStateOverride = { (.ac, false, thermalState) }
        var thermalDelays: [TimeInterval] = []
        thermalStore._test_antigravityCostCatchUpSleepOverride = { delay in
            thermalDelays.append(delay)
            thermalState = .nominal
        }
        var calls = 0
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 374,
            sessionCostUSD: nil,
            last30DaysTokens: 374,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 200,
                outputTokens: 74,
                totalTokens: 374,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)
        thermalStore._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                return CostUsageTokenResult(
                    snapshot: partialSnapshot,
                    antigravityCatchUpPending: true,
                    antigravityCatchUpMadeProgress: true)
            }
            return CostUsageTokenResult(
                snapshot: completeSnapshot,
                antigravityCatchUpPending: false,
                antigravityCatchUpMadeProgress: true)
        }

        await thermalStore.refreshTokenUsageNow(for: .antigravity, force: true)
        await thermalStore.antigravityCostCatchUpTask?.value
        await thermalStore.widgetSnapshotPersistTask?.value
        thermalStore._test_tokenUsageResultLoaderOverride = nil

        #expect(thermalDelays == [CodexCostCatchUpPolicy.constrainedRetryDelay])
        #expect(calls == 2)
        #expect(thermalStore.tokenSnapshot(for: .antigravity)?.last30DaysTokens == 374)
    }

    @Test
    @MainActor
    func `production usage store converges 550 databases across batches without loader overrides`() async throws {
        let fixture = try Fixture()
        let recentSeconds = UInt64(max(1, Int64(Date().timeIntervalSince1970) - 3600))
        for index in 0..<550 {
            try fixture.database(
                String(format: "session-%03d", index),
                blobs: [Fixture.blob(model: "claude-sonnet-4-6", seconds: recentSeconds)])
        }

        let store = try self.makeIsolatedStore(fixture: fixture)
        await store.refreshTokenUsageNow(for: .antigravity, force: true)

        #expect(store.tokenSnapshot(for: .antigravity)?.last30DaysTokens == 500 * 187)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyCoverageIsEstablished == false)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyIsFullyScanned == false)
        #expect(store.antigravityCostCatchUpTask != nil)

        // Wait for automatic background catch-up without triggering another manual refresh.
        await store.antigravityCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(store.antigravityCostCatchUpTask == nil)
        #expect(store.tokenSnapshot(for: .antigravity)?.last30DaysTokens == 550 * 187)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyCoverageIsEstablished == true)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyIsFullyScanned == true)
        #expect(store.tokenError(for: .antigravity) == nil)

        let scanCacheRoot = AntigravityLocalScanCacheIO.resolvedCacheRoot(
            explicitCacheRoot: nil,
            environment: fixture.environment)
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])
        let cacheURL = AntigravityLocalScanCacheIO.cacheFileURL(cacheRoot: scanCacheRoot, scope: scope)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        let persisted = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: scanCacheRoot, scope: scope)
        #expect(persisted.indexedKeys.count == 550)
        #expect(persisted.retainedComplete?.report.summary?.totalTokens == 550 * 187)
    }

    @Test
    @MainActor
    func `upgrading from pre-cache config and v1 scan cache migrates cleanly to v2`() async throws {
        let fixture = try Fixture()
        let recentSeconds = UInt64(max(1, Int64(Date().timeIntervalSince1970) - 3600))
        try fixture.database(
            rootIndex: 0,
            blobs: [
                Fixture.blobWithRootEnvelope(
                    stepUUID: "step-upgrade",
                    model: "claude-sonnet-4-6",
                    response: "resp-upgrade",
                    seconds: recentSeconds),
            ])
        try fixture.database(
            rootIndex: 1,
            blobs: [
                Fixture.blobWithRootEnvelope(
                    stepUUID: "step-upgrade",
                    model: "claude-sonnet-4-6",
                    response: "resp-upgrade",
                    seconds: recentSeconds),
            ])
        try fixture.database(
            "session-second",
            blobs: [Fixture.blob(model: "claude-sonnet-4-6", seconds: recentSeconds)])

        let scanCacheRoot = AntigravityLocalScanCacheIO.resolvedCacheRoot(
            explicitCacheRoot: nil,
            environment: fixture.environment)
        let scope = CostUsageFetcher.antigravityHistoryScope(
            environment: fixture.environment,
            additionalProfileHomes: [])
        let v2URL = AntigravityLocalScanCacheIO.cacheFileURL(cacheRoot: scanCacheRoot, scope: scope)
        let costUsageDir = v2URL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: costUsageDir, withIntermediateDirectories: true)

        // Preserve sibling caches and tolerate legacy v1 artifacts from earlier builds.
        let siblingSentinel = costUsageDir.appendingPathComponent("sibling-cache.json")
        try Data("{\"preserved\":true}".utf8).write(to: siblingSentinel)
        let legacyV1URL = costUsageDir.appendingPathComponent(
            v2URL.lastPathComponent.replacingOccurrences(of: "antigravity-scan-v2-", with: "antigravity-scan-v1-"))
        try Data("{\"version\":1,\"scope\":\"legacy\"}".utf8).write(to: legacyV1URL)

        let configURL = fixture.root.appendingPathComponent("config.json")
        let initialConfig = CodexBarConfig(providers: [
            ProviderConfig(id: .antigravity, enabled: true),
        ])
        try CodexBarConfigStore(fileURL: configURL).save(initialConfig)

        let store = try self.makeIsolatedStore(fixture: fixture)
        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.antigravityCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value

        #expect(store.tokenSnapshot(for: .antigravity)?.last30DaysTokens == 2 * 187)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyCoverageIsEstablished == true)
        #expect(store.tokenSnapshot(for: .antigravity)?.historyIsFullyScanned == true)
        #expect(store.tokenError(for: .antigravity) == nil)
        #expect(FileManager.default.fileExists(atPath: siblingSentinel.path))
        #expect(try Data(contentsOf: siblingSentinel) == Data("{\"preserved\":true}".utf8))
        #expect(FileManager.default.fileExists(atPath: v2URL.path))

        let upgradedIndex = AntigravityLocalScanCacheIO.loadIndex(cacheRoot: scanCacheRoot, scope: scope)
        let upgradedEvents = upgradedIndex.indexedKeys.compactMap {
            AntigravityLocalScanCacheIO.loadFragment(cacheRoot: scanCacheRoot, scope: scope, key: $0)
        }.flatMap(\.events)
        #expect(upgradedEvents.contains { $0.stepUUID == "step-upgrade" })
        #expect(upgradedIndex.retainedComplete?.report.summary?.totalTokens == 2 * 187)

        let loadedConfig = try CodexBarConfigStore(fileURL: configURL).load()
        #expect(loadedConfig?.providerConfig(for: .antigravity)?.enabled == true)
    }

    @Test
    @MainActor
    func `clearCostUsageCache drains in-flight regular Antigravity refresh before deleting cache`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture)
        let cacheDir = UsageStore.costUsageCacheDirectory(fileManager: IsolatedCacheFileManager(root: fixture.root))

        var refreshStartedContinuation: AsyncStream<Void>.Continuation?
        let refreshStarted = AsyncStream<Void> { continuation in
            refreshStartedContinuation = continuation
        }
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 374,
            sessionCostUSD: nil,
            last30DaysTokens: 374,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 200,
                outputTokens: 74,
                totalTokens: 374,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)

        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            refreshStartedContinuation?.finish()
            try? await Task.sleep(for: .milliseconds(50))
            let recreatedDir = cacheDir.appendingPathComponent("antigravity-local-v2", isDirectory: true)
            try FileManager.default.createDirectory(at: recreatedDir, withIntermediateDirectories: true)
            try Data("{\"version\":2}".utf8).write(to: recreatedDir.appendingPathComponent("cache.json"))
            return CostUsageTokenResult(
                snapshot: completeSnapshot,
                antigravityCatchUpPending: false,
                antigravityCatchUpMadeProgress: true)
        }

        let refreshTask = Task {
            await store.refreshTokenUsageNow(for: .antigravity, force: true)
        }
        for await _ in refreshStarted {}

        let root = fixture.root
        let error = await store.clearCostUsageCache(fileManagerFactory: { IsolatedCacheFileManager(root: root) })
        await refreshTask.value
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
        #expect(store.tokenSnapshot(for: .antigravity) == nil)
    }

    @Test
    @MainActor
    func `extended thermal pauses do not exhaust the 64-pass Antigravity catch-up budget`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture, lowPowerPreference: .off)
        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: Fixture.now)
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 374,
            sessionCostUSD: nil,
            last30DaysTokens: 374,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 200,
                outputTokens: 74,
                totalTokens: 374,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)

        var thermalState: ProcessInfo.ThermalState = .serious
        var pauseCount = 0
        store._test_antigravityCostCatchUpResourceStateOverride = { (.ac, false, thermalState) }
        store._test_antigravityCostCatchUpSleepOverride = { _ in
            pauseCount += 1
            if pauseCount >= 70 {
                thermalState = .nominal
            }
        }
        var calls = 0
        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                return CostUsageTokenResult(
                    snapshot: partialSnapshot,
                    antigravityCatchUpPending: true,
                    antigravityCatchUpMadeProgress: true)
            }
            return CostUsageTokenResult(
                snapshot: completeSnapshot,
                antigravityCatchUpPending: false,
                antigravityCatchUpMadeProgress: true)
        }

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.antigravityCostCatchUpTask?.value
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        #expect(pauseCount == 70)
        #expect(calls == 2)
        #expect(store.tokenSnapshot(for: .antigravity)?.last30DaysTokens == 374)
    }

    @Test
    @MainActor
    func `clearCostUsageCache drains in-flight Spend Dashboard refresh before deleting cache`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture)
        let cacheDir = UsageStore.costUsageCacheDirectory(fileManager: IsolatedCacheFileManager(root: fixture.root))

        var refreshStartedContinuation: AsyncStream<Void>.Continuation?
        let refreshStarted = AsyncStream<Void> { continuation in
            refreshStartedContinuation = continuation
        }
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 374,
            sessionCostUSD: nil,
            last30DaysTokens: 374,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 200,
                outputTokens: 74,
                totalTokens: 374,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)

        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            refreshStartedContinuation?.finish()
            try? await Task.sleep(for: .milliseconds(50))
            let recreatedDir = cacheDir.appendingPathComponent("antigravity-local-v2", isDirectory: true)
            try FileManager.default.createDirectory(at: recreatedDir, withIntermediateDirectories: true)
            try Data("{\"version\":2}".utf8).write(to: recreatedDir.appendingPathComponent("cache.json"))
            return CostUsageTokenResult(
                snapshot: completeSnapshot,
                antigravityCatchUpPending: false,
                antigravityCatchUpMadeProgress: true)
        }

        let dashboardTask = Task {
            await store.refreshSpendDashboardTokenUsageNow(for: .antigravity, force: true)
        }
        for await _ in refreshStarted {}

        let root = fixture.root
        let error = await store.clearCostUsageCache(fileManagerFactory: { IsolatedCacheFileManager(root: root) })
        await dashboardTask.value
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        #expect(error == nil)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
        #expect(store.spendDashboardTokenSnapshotPublicationForCurrentConfig(for: .antigravity) == nil)
    }

    @Test
    @MainActor
    func `refreshes started while clearCostUsageCache is deleting are blocked until deletion completes`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture)
        let cacheDir = UsageStore.costUsageCacheDirectory(fileManager: IsolatedCacheFileManager(root: fixture.root))
        try FileManager.default.createDirectory(at: cacheDir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: cacheDir.appendingPathComponent("seed.json"))

        let removeStarted = AsyncStream<Void>.makeStream()
        let allowRemoveFinish = DispatchSemaphore(value: 0)
        var loaderCalls = 0
        let completeSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: true,
            historyScanIsPartial: false,
            daily: [.init(
                date: "2026-08-27",
                inputTokens: 100,
                outputTokens: 37,
                totalTokens: 187,
                costUSD: nil,
                modelsUsed: nil,
                modelBreakdowns: nil)],
            updatedAt: Fixture.now)

        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            loaderCalls += 1
            return CostUsageTokenResult(snapshot: completeSnapshot)
        }

        let root = fixture.root
        let clearTask = Task {
            await store.clearCostUsageCache {
                IsolatedCacheFileManager(root: root) {
                    removeStarted.continuation.yield()
                    removeStarted.continuation.finish()
                    allowRemoveFinish.wait()
                }
            }
        }

        for await _ in removeStarted.stream {}
        #expect(store.isClearingCostUsageCache)

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.refreshSpendDashboardTokenUsageNow(for: .antigravity, force: true)
        #expect(loaderCalls == 0)

        allowRemoveFinish.signal()
        let error = await clearTask.value
        #expect(error == nil)
        #expect(!store.isClearingCostUsageCache)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil
        #expect(loaderCalls == 1)
    }

    @Test
    @MainActor
    func `antigravity catch-up measures executor activeDuration without serial-queue wait time`() async throws {
        let fixture = try Fixture()
        let recentSeconds = UInt64(max(1, Int64(Date().timeIntervalSince1970) - 3600))
        try fixture.database(
            "queued-session",
            blobs: [Fixture.blob(model: "claude-sonnet-4-6", seconds: recentSeconds)])

        // Occupy the global serial executor first so Antigravity waits in queue for >= 0.45s.
        let blockerStarted = AsyncStream<Void>.makeStream()
        let blockerRelease = DispatchSemaphore(value: 0)
        let blockerTask = Task.detached {
            try await CostUsageScanExecutor.run { _ in
                blockerStarted.continuation.yield()
                blockerStarted.continuation.finish()
                _ = blockerRelease.wait(timeout: .now() + 0.45)
            }
        }
        for await _ in blockerStarted.stream {}

        let wallStarted = Date()
        let fetcherResult = try await CostUsageFetcher().loadTokenResult(
            provider: .antigravity,
            environment: fixture.environment,
            now: Date(),
            forceRefresh: true,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            bypassScannerDebounce: true,
            calendar: Fixture.calendar)
        let wallElapsed = Date().timeIntervalSince(wallStarted)
        blockerRelease.signal()
        try await blockerTask.value

        let measuredActive = try #require(fetcherResult.antigravityScanActiveDuration)
        #expect(wallElapsed >= 0.20)
        #expect(measuredActive < 0.15)

        // Verify UsageStore duty-cycle decision consumes executor activeDuration rather than wall clock.
        let store = try self.makeIsolatedStore(fixture: fixture, lowPowerPreference: .off)
        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: Fixture.now)
        var recordedDelays: [TimeInterval] = []
        store._test_antigravityCostCatchUpSleepOverride = { delay in
            recordedDelays.append(delay)
            if delay > 0 {
                throw CancellationError()
            }
        }
        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            CostUsageTokenResult(
                snapshot: partialSnapshot,
                antigravityCatchUpPending: true,
                antigravityCatchUpMadeProgress: true,
                antigravityScanActiveDuration: 2.5)
        }

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        await store.antigravityCostCatchUpTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        let throttledDelay = try #require(recordedDelays.first)
        #expect(throttledDelay > 2000)
    }

    @Test
    @MainActor
    func `clearCostUsageCache drains canceled-but-still-writing catch-up tasks`() async throws {
        let fixture = try Fixture()
        let store = try self.makeIsolatedStore(fixture: fixture)
        let cacheDir = UsageStore.costUsageCacheDirectory(fileManager: IsolatedCacheFileManager(root: fixture.root))

        let oldPassStarted = AsyncStream<Void>.makeStream()
        let allowOldPassExit = AsyncStream<Void>.makeStream()
        let partialSnapshot = CostUsageTokenSnapshot(
            sessionTokens: 187,
            sessionCostUSD: nil,
            last30DaysTokens: 187,
            last30DaysCostUSD: nil,
            historyDays: 30,
            historyCoverageIsEstablished: false,
            historyScanIsPartial: true,
            daily: [],
            updatedAt: Fixture.now)

        var calls = 0
        store._test_tokenUsageResultLoaderOverride = { _, _, _, _, _, _ in
            calls += 1
            if calls == 1 {
                return CostUsageTokenResult(
                    snapshot: partialSnapshot,
                    antigravityCatchUpPending: true,
                    antigravityCatchUpMadeProgress: true)
            }
            oldPassStarted.continuation.yield()
            oldPassStarted.continuation.finish()
            for await _ in allowOldPassExit.stream {}
            let recreatedDir = cacheDir.appendingPathComponent("antigravity-local-v2", isDirectory: true)
            try FileManager.default.createDirectory(at: recreatedDir, withIntermediateDirectories: true)
            try Data("{\"version\":2}".utf8).write(to: recreatedDir.appendingPathComponent("cache.json"))
            return CostUsageTokenResult(
                snapshot: partialSnapshot,
                antigravityCatchUpPending: false,
                antigravityCatchUpMadeProgress: true)
        }

        await store.refreshTokenUsageNow(for: .antigravity, force: true)
        for await _ in oldPassStarted.stream {}

        // Cancel the running catch-up before clearCostUsageCache runs (clearing antigravityCostCatchUpTask),
        // simulating a scope change while the old pass is still writing.
        store.cancelAntigravityCostCatchUp()
        #expect(store.antigravityCostCatchUpTask == nil)
        #expect(!store.antigravityCostCatchUpTasksInFlight.isEmpty)

        let root = fixture.root
        let clearTask = Task {
            await store.clearCostUsageCache { IsolatedCacheFileManager(root: root) }
        }
        await Task.yield()
        allowOldPassExit.continuation.yield()
        allowOldPassExit.continuation.finish()

        let error = await clearTask.value
        await store.widgetSnapshotPersistTask?.value
        store._test_tokenUsageResultLoaderOverride = nil

        #expect(error == nil)
        #expect(store.antigravityCostCatchUpTasksInFlight.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: cacheDir.path))
    }

    @MainActor
    private func makeIsolatedStore(
        fixture: Fixture,
        lowPowerPreference: LowPowerModePreference = .off) throws -> UsageStore
    {
        let suite = "AntigravityIncrementalScanTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.set(true, forKey: "providerDetectionCompleted")
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: CodexBarConfigStore(fileURL: fixture.root.appendingPathComponent("config.json")),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore(),
            antigravityOAuthCredentialsStore: .init(fileURL: fixture.root.appendingPathComponent("no-creds.json")),
            performInitialProviderDetection: false)
        settings._test_managedCodexAccountStoreURL = fixture.root.appendingPathComponent("accounts.json")
        settings._test_codexReconciliationEnvironment = fixture.environment
        settings.costUsageEnabled = true
        settings.refreshFrequency = .manual
        settings.backgroundWorkLowPowerModePreference = lowPowerPreference
        for provider in UsageProvider.allCases {
            let metadata = try #require(ProviderRegistry.shared.metadata[provider])
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .antigravity)
        }
        let store = UsageStore(
            fetcher: UsageFetcher(environment: fixture.environment),
            browserDetection: BrowserDetection(homeDirectory: fixture.root.path, cacheTTL: 0),
            settings: settings,
            historicalUsageHistoryStore: HistoricalUsageHistoryStore(
                fileURL: fixture.root.appendingPathComponent("historical.json")),
            planUtilizationHistoryStore: PlanUtilizationHistoryStore(
                directoryURL: fixture.root.appendingPathComponent("plans")),
            startupBehavior: .testing,
            environmentBase: fixture.environment,
            widgetSnapshotURL: fixture.root.appendingPathComponent("widget.json"))
        store._test_widgetSnapshotSaveOverride = { _ in }
        store._test_antigravityCostCatchUpResourceStateOverride = { (.ac, false, .nominal) }
        return store
    }
}

private final class IsolatedCacheFileManager: FileManager, @unchecked Sendable {
    private let root: URL
    private var onBeforeRemoveItem: (@Sendable () -> Void)?

    init(root: URL, onBeforeRemoveItem: (@Sendable () -> Void)? = nil) {
        self.root = root
        self.onBeforeRemoveItem = onBeforeRemoveItem
        super.init()
    }

    override func urls(for directory: SearchPathDirectory, in domainMask: SearchPathDomainMask) -> [URL] {
        if directory == .cachesDirectory {
            return [self.root.appendingPathComponent("Caches", isDirectory: true)]
        }
        return super.urls(for: directory, in: domainMask)
    }

    override func removeItem(at URL: URL) throws {
        let hook = self.onBeforeRemoveItem
        self.onBeforeRemoveItem = nil
        hook?()
        try super.removeItem(at: URL)
    }
}
