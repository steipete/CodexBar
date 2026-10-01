import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test(arguments: [2, 16])
    func `repeated scan load on an unchanged store reuses the decoded baseline`(fileCount: Int) async throws {
        let fixture = try ReadWorkFixture(fileCount: fileCount, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var recordingHooks = CostUsageStoreTestHooks.current
        recordingHooks.readWorkRecorder = recorder
        try await CostUsageStoreTestHooks.$current.withValue(recordingHooks) {
            let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            first.release()
            let firstWork = recorder.snapshot()
            let stamp = await fixture.store.currentDatabaseStamp()
            recorder.reset()
            let second = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { second.release() }
            let work = recorder.snapshot()
            #expect(await fixture.store.currentDatabaseStamp() == stamp)
            #expect(second.cache == first.cache)
            #expect(second.unloadedTokenSnapshotPaths == first.unloadedTokenSnapshotPaths)
            #expect(firstWork.usageRowDecodeAttempts == fixture.rowCount)
            #expect(work.scannerSnapshotReads == 0)
            #expect(work.usageRowDecodeAttempts == 0)
            #expect(!fixture.save(second.cache, load: second).catchUpRequired)
            print("[repeated-scan-load] rows=\(fixture.rowCount) first_decodes=\(firstWork.usageRowDecodeAttempts) " +
                "warm_snapshots=\(work.scannerSnapshotReads) warm_decodes=\(work.usageRowDecodeAttempts)")
        }
    }
}

extension CostUsageStoreReadWorkTests {
    @Test
    func `scanner access retains its store independently of report reads`() throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var recordingHooks = CostUsageStoreTestHooks.current
        recordingHooks.readWorkRecorder = recorder
        try CostUsageStoreTestHooks.$current.withValue(recordingHooks) {
            let first = CostUsageStoreAccess.load(cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar)
            first.release()
            _ = CostUsageStoreAccess.readView(
                cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar, purpose: .report)
            recorder.reset()
            let second = CostUsageStoreAccess.load(cacheRoot: fixture.env.cacheRoot, calendar: fixture.calendar)
            defer { second.release() }
            #expect(first.store === second.store)
            #expect(second.cache == first.cache)
            #expect(recorder.snapshot().usageRowDecodeAttempts == 0)
            #expect(recorder.snapshot().scannerSnapshotReads == 0)
            #expect(recorder.snapshot().integrityChecks == 0)
            #expect(!CostUsageStoreAccess.save(
                store: second.store,
                cache: second.cache,
                calendar: fixture.calendar,
                requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day),
                unloadedTokenSnapshotPaths: second.unloadedTokenSnapshotPaths,
                skipIdenticalContent: true,
                receipt: second.receipt).catchUpRequired)
        }
    }

    @Test(arguments: ["external", "local", "schema", "reopen", "failure"])
    func `warm scan reloads after database invalidation`(mutation: String) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        first.release()
        switch mutation {
        case "external":
            let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
            try writer.execute("UPDATE files SET parsed_bytes = 777")
        case "local":
            var metadata = await fixture.store.fetchMetadata()
            metadata.pricingKey = "changed-pricing"
            #expect(await fixture.store.setMetadata(metadata))
        case "schema":
            let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
            try writer.execute("CREATE TABLE warm_scan_probe (id INTEGER)")
        case "failure":
            await fixture.store.recoverConnectionAfterFailure()
        default:
            await fixture.store.closeConnectionForTesting()
        }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var recordingHooks = CostUsageStoreTestHooks.current
        recordingHooks.readWorkRecorder = recorder
        try await CostUsageStoreTestHooks.$current.withValue(recordingHooks) {
            let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { loaded.release() }
            #expect(recorder.snapshot().usageRowDecodeAttempts == fixture.rowCount)
            #expect(recorder.snapshot().scannerSnapshotReads == 1)
            let fresh = CostUsageStore(cacheRoot: fixture.env.cacheRoot).syncLoadCodexScan(calendar: fixture.calendar)
            defer { fresh.release() }
            #expect(loaded.cache == fresh.cache)
            #expect(loaded.unloadedTokenSnapshotPaths == fresh.unloadedTokenSnapshotPaths)
        }
    }

    @Test
    func `warm scan still checks timezone and transcript identity`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var metadata = await fixture.store.fetchMetadata()
        metadata.catchUpPending = true
        #expect(await fixture.store.setMetadata(metadata))
        let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        first.release()
        #expect(first.cache.codexScanCatchUpPending != true)
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        var recordingHooks = CostUsageStoreTestHooks.current
        recordingHooks.readWorkRecorder = recorder
        try await CostUsageStoreTestHooks.$current.withValue(recordingHooks) {
            var otherCalendar = fixture.calendar
            otherCalendar.timeZone = try #require(TimeZone(identifier: "Europe/Rome"))
            let mismatched = fixture.store.syncLoadCodexScan(calendar: otherCalendar)
            mismatched.release()
            #expect(mismatched.cache.files.isEmpty)
            let path = try #require(fixture.canonical.files.keys.min())
            try Data("changed transcript\n".utf8).write(to: URL(fileURLWithPath: path), options: .atomic)
            let changed = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { changed.release() }
            #expect(changed.cache.codexScanCatchUpPending == true)
            #expect(recorder.snapshot().usageRowDecodeAttempts == 0)
        }
    }
}

extension CostUsageStoreReadWorkTests {
    @Test
    func `warm scan reopens compatible metadata without losing history`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let first = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        first.release()
        let predecessorHash = "4a593b5d59c7bcf3"
        let predecessorVersion = CostUsageStore.combinedSchemaVersion(
            base: CostUsageStore.baseSchemaVersion, parserHash: predecessorHash)
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        try writer.execute("BEGIN IMMEDIATE")
        try writer.execute("UPDATE meta SET value = '\(predecessorHash)' WHERE key = 'parser_hash'")
        try writer.execute("PRAGMA user_version = \(predecessorVersion)")
        try writer.execute("COMMIT")
        let incompatible = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        incompatible.release()
        #expect(incompatible.cache.files.isEmpty)
        let recovered = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { recovered.release() }
        #expect(recovered.cache == first.cache)
        #expect(await fixture.store.rebuildCount == 0)
    }
}
