import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `cached token activity skips event payloads while preserving totals`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        #expect(activity.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        #expect(activity.coverageSinceKey == fixture.canonical.scanSinceKey)
        #expect(activity.coverageUntilKey == fixture.canonical.scanUntilKey)
        let work = recorder.snapshot()
        #expect(work.usageRows == 0)
        #expect(work.usagePayloadBytes == 0)
        #expect(work.usageRowDecodeAttempts == 0)
        #expect(work.tokenSnapshotRows == 0)
        #expect(work.fullSnapshotReads == 0)
    }

    @Test
    func `cached token activity preserves scope timezone and incomplete guards`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var otherScope = fixture.options
        otherScope.codexSessionsRoot = fixture.env.root.appendingPathComponent("other-account/sessions")
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: otherScope) == nil)
        var otherCalendar = fixture.options
        otherCalendar.calendar.timeZone = try #require(TimeZone(secondsFromGMT: 3600))
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: otherCalendar) == nil)

        let path = try #require(fixture.canonical.files.keys.min())
        let malformed = CostUsageStoreBufferedLine(
            path: path, kind: .unresolvedFork, lineIndex: 0, payload: Data("invalid replay JSON".utf8))
        #expect(await fixture.store.replaceBufferedLines(path: path, kind: .unresolvedFork, lines: [malformed]))
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: fixture.options) == nil)
        #expect(recorder.snapshot().retryPresenceRows == 1)
        #expect(recorder.snapshot().bufferedPayloadBytes == 0)
        #expect(recorder.snapshot().usageRows == 0)
    }

    @Test
    func `cached token activity excludes foreign file aggregates`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4)
        defer { fixture.remove() }
        var cache = fixture.canonical
        let path = try #require(cache.files.keys.min())
        cache.files[fixture.env.root.appendingPathComponent("other-account/foreign.jsonl").path] = cache.files[path]
        #expect(!fixture.save(cache).catchUpRequired)
        let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: fixture.options))
        #expect(activity.daily.map(\.totalTokens) == [fixture.rowCount * 13])
    }

    @Test
    func `cached token activity rejects unfinished file scan`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 2, rowsPerFile: 4, incomplete: true)
        defer { fixture.remove() }
        #expect(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now, scannerOptions: fixture.options) == nil)
    }
}
