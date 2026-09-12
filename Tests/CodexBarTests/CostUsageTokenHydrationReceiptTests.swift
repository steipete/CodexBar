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
        CostUsageStore.codexTokenHydrationCheckpointForTesting = (fixture.store.databaseURL, {
            try writer.execute("DELETE FROM token_snapshots")
        })
        defer { CostUsageStore.codexTokenHydrationCheckpointForTesting = nil }
        let result = fixture.store.syncLoadCodexTokenSnapshotsIfAvailable(
            paths: loaded.unloadedTokenSnapshotPaths, receipt: loaded.receipt)
        #expect(result == nil)
        #expect(fixture.save(loaded.cache, load: loaded).catchUpRequired)
        #expect(await fixture.store.rebuildCount == 0)
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
