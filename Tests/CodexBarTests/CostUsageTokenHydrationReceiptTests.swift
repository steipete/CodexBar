import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test(arguments: ["external", "same-store", "superseded", "consumed", "released"])
    func `token hydration rejects invalidated receipts`(_ change: String) async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let hydrator = CostUsageScanner.CodexScanHistoryHydrator(load: loaded)
        var cache = loaded.cache
        switch change {
        case "external":
            let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
            try writer.execute("DELETE FROM token_snapshots")
        case "same-store":
            #expect(try await fixture.store.replaceTokenSnapshots(
                path: #require(cache.files.keys.first), snapshots: []))
        case "superseded":
            let newer = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
            defer { newer.release() }
            #expect(hydrator.hydrate(for: cache.files.keys.map { URL(fileURLWithPath: $0) }, cache: &cache).isEmpty)
        case "consumed":
            #expect(!fixture.save(cache, load: loaded).catchUpRequired)
        default:
            loaded.release()
        }
        let files = cache.files.keys.map { URL(fileURLWithPath: $0) }
        #expect(hydrator.hydrate(for: files, cache: &cache).isEmpty)
        #expect(hydrator.unloadedTokenPaths == loaded.unloadedTokenSnapshotPaths)
        #expect(cache == loaded.cache)
        #expect(await fixture.store.rebuildCount == 0)
    }

    @Test
    func `external commit during token hydration discards the whole batch`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let writer = try BaselineSQLiteConnection(url: fixture.store.databaseURL)
        var checkpointHooks = CostUsageStoreTestHooks.current
        checkpointHooks.codexTokenHydrationCheckpoint = (fixture.store.databaseURL, {
            try writer.execute("DELETE FROM token_snapshots")
        })
        try await CostUsageStoreTestHooks.$current.withValue(checkpointHooks) {
            let result = fixture.store.syncLoadCodexTokenSnapshotsIfAvailable(
                paths: loaded.unloadedTokenSnapshotPaths, receipt: loaded.receipt)
            #expect(result == nil)
            #expect(fixture.save(loaded.cache, load: loaded).catchUpRequired)
            #expect(await fixture.store.rebuildCount == 0)
        }
    }

    @Test
    func `token hydration leaves an incompatible replacement untouched`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let loaded = fixture.store.syncLoadCodexScan(calendar: fixture.calendar)
        defer { loaded.release() }
        let replacement = CostUsageStore(
            cacheRoot: fixture.env.root.appendingPathComponent("replacement"), schemaVersion: 123)
        _ = await replacement.readSnapshot()
        #expect(await replacement.truncateWALForTesting())
        await replacement.closeConnectionForTesting()
        #expect(await fixture.store.truncateWALForTesting())
        let oldDirectory = fixture.store.databaseURL.deletingLastPathComponent()
        try FileManager.default.moveItem(at: oldDirectory, to: fixture.env.root.appendingPathComponent("retired-store"))
        try FileManager.default.moveItem(at: replacement.databaseURL.deletingLastPathComponent(), to: oldDirectory)
        let before = try Data(contentsOf: fixture.store.databaseURL)
        let result = fixture.store.syncLoadCodexTokenSnapshotsIfAvailable(
            paths: loaded.unloadedTokenSnapshotPaths, receipt: loaded.receipt)
        #expect(result == nil)
        #expect(try Data(contentsOf: fixture.store.databaseURL) == before)
        #expect(await fixture.store.rebuildCount == 0)
    }
}

extension CostUsageStoreReadWorkTests {
    @Test
    func `history read failures retain unloaded markers and persisted rows`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let before = await fixture.store.readSnapshot()
        let loaded = CostUsageStoreAccess.load(
            cacheRoot: fixture.env.cacheRoot,
            calendar: fixture.calendar)
        let selectedPath = try #require(loaded.cache.files.keys.min())
        let databaseURL = fixture.store.databaseURL
        var checkpointHooks = CostUsageStoreTestHooks.current
        checkpointHooks.codexTokenSnapshotReadFailure = { $0 == databaseURL && $1 == selectedPath }
        try await CostUsageStoreTestHooks.$current.withValue(checkpointHooks) {
            let history = CostUsageScanner.CodexScanHistoryHydrator(load: loaded)
            var cache = loaded.cache
            let hydrated = history.hydrate(
                for: [URL(fileURLWithPath: selectedPath)],
                cache: &cache)
            #expect(hydrated.isEmpty)
            #expect(history.unloadedTokenPaths.contains(selectedPath))
            #expect(cache.files[selectedPath]?.codexTokenSnapshots == nil)

            cache.lastScanUnixMs += 1000
            let result = try CostUsageStoreAccess.save(
                store: loaded.store,
                cache: cache,
                calendar: fixture.calendar,
                requestedScanWindow: (
                    sinceKey: #require(cache.scanSinceKey),
                    untilKey: #require(cache.scanUntilKey)),
                unloadedTokenSnapshotPaths: history.unloadedTokenPaths,
                skipIdenticalContent: true)
            #expect(!result.catchUpRequired)

            var clearedHooks = CostUsageStoreTestHooks.current
            clearedHooks.codexTokenSnapshotReadFailure = nil
            try await CostUsageStoreTestHooks.$current.withValue(clearedHooks) {
                let after = await fixture.store.readSnapshot()
                #expect(after.tokenSnapshots == before.tokenSnapshots)
                #expect(after.usageRows == before.usageRows)
            }
        }
    }

    @Test
    func `scanner preserves failed history reads and retries changed files`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 1, rowsPerFile: 4)
        defer { fixture.remove() }
        let selectedPath = try #require(fixture.canonical.files.keys.min())
        let originalUsage = try #require(fixture.canonical.files[selectedPath])
        let before = await fixture.store.readSnapshot()
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: selectedPath))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("{}\n".utf8))
        try handle.close()
        let changedMetadata = CostUsageScanner.codexFileMetadata(fileURL: URL(fileURLWithPath: selectedPath))
        #expect(changedMetadata.size > originalUsage.size)

        let databaseURL = fixture.store.databaseURL
        var checkpointHooks = CostUsageStoreTestHooks.current
        checkpointHooks.codexTokenSnapshotReadFailure = {
            $0 == databaseURL && $1 == selectedPath
        }
        try await CostUsageStoreTestHooks.$current.withValue(checkpointHooks) {
            var options = fixture.options
            options.refreshMinIntervalSeconds = 0

            let report = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: fixture.now,
                until: fixture.now,
                now: fixture.now.addingTimeInterval(1),
                options: options)
            var clearedHooks = CostUsageStoreTestHooks.current
            clearedHooks.codexTokenSnapshotReadFailure = nil
            try await CostUsageStoreTestHooks.$current.withValue(clearedHooks) {
                #expect(report.summary?.totalTokens == fixture.rowCount * 13)
                let deferred = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
                #expect(deferred.files[selectedPath]?.size == originalUsage.size)
                #expect(deferred.files[selectedPath]?.mtimeUnixMs == originalUsage.mtimeUnixMs)
                #expect(deferred == fixture.canonical)
                let after = await fixture.store.readSnapshot()
                #expect(after.tokenSnapshots == before.tokenSnapshots)
                #expect(after.usageRows == before.usageRows)

                let retry = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: fixture.now,
                    until: fixture.now,
                    now: fixture.now.addingTimeInterval(2),
                    options: options)
                #expect(retry.summary?.totalTokens == report.summary?.totalTokens)
                let resumed = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
                #expect(resumed.files[selectedPath]?.size == changedMetadata.size)
                #expect(resumed.codexScanCatchUpPending != true)
            }
        }
    }

    @Test
    func `alias migration defers on history failure then retries losslessly`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        let oldPath = try #require(fixture.canonical.files.keys.min())
        let newURL = fixture.env.codexSessionsRoot.appendingPathComponent("renamed-after-failure.jsonl")
        let before = await fixture.store.readSnapshot()
        try FileManager.default.moveItem(at: URL(fileURLWithPath: oldPath), to: newURL)

        let databaseURL = fixture.store.databaseURL
        var checkpointHooks = CostUsageStoreTestHooks.current
        checkpointHooks.codexTokenSnapshotReadFailure = {
            $0 == databaseURL && $1 == oldPath
        }
        try await CostUsageStoreTestHooks.$current.withValue(checkpointHooks) {
            var options = fixture.options
            options.refreshMinIntervalSeconds = 0

            let deferredReport = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: fixture.now,
                until: fixture.now,
                now: fixture.now.addingTimeInterval(1),
                options: options)
            var clearedHooks = CostUsageStoreTestHooks.current
            clearedHooks.codexTokenSnapshotReadFailure = nil
            try await CostUsageStoreTestHooks.$current.withValue(clearedHooks) {
                #expect(deferredReport.summary?.totalTokens == fixture.rowCount * 13)
                let deferred = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
                #expect(deferred.files[oldPath] != nil)
                #expect(deferred.files[newURL.path] == nil)
                let afterFailure = await fixture.store.readSnapshot()
                #expect(afterFailure.tokenSnapshots == before.tokenSnapshots)
                #expect(afterFailure.usageRows == before.usageRows)

                let retriedReport = CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: fixture.now,
                    until: fixture.now,
                    now: fixture.now.addingTimeInterval(2),
                    options: options)
                #expect(retriedReport.summary?.totalTokens == fixture.rowCount * 13)
                let migrated = fixture.store.syncLoadCodexCache(calendar: fixture.calendar)
                #expect(migrated.files[oldPath] == nil)
                #expect(migrated.files[newURL.path]?.codexTokenSnapshots?.count == 4)
                #expect(migrated.files[newURL.path]?.codexRows?.count == 4)
            }
        }
    }
}
