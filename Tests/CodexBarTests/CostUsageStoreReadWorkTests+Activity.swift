import Foundation
import Testing
@testable import CodexBarCore

extension CostUsageStoreReadWorkTests {
    @Test
    func `unchanged activity refreshes reuse validated decoded store state`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        var totals: [[Int?]] = []
        for _ in 0..<3 {
            let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
                now: fixture.now,
                maximumDays: 365,
                scannerOptions: fixture.options))
            totals.append(activity.daily.map(\.totalTokens))
        }

        #expect(totals == Array(repeating: [fixture.rowCount * 13], count: 3))
        let work = recorder.snapshot()
        #expect(work.integrityChecks == 1)
        #expect(work.cacheConversions == 1)
        #expect(work.fileRows == fixture.fileCount)
        #expect(work.readViewConversions == 3)
    }

    @Test
    func `activity read state also serves later status refreshes`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 16, rowsPerFile: 64)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        await fixture.expectStatus(CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus())
        let activity = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        await fixture.expectStatus(CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus())
        await fixture.expectStatus(CostUsageFetcher(scannerOptions: fixture.options).codexScanCatchUpStatus())

        #expect(activity.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        let work = recorder.snapshot()
        #expect(work.integrityChecks == 1)
        #expect(work.cacheConversions == 2)
        #expect(work.fileRows == fixture.fileCount * 2)
        #expect(work.readViewConversions == 4)
    }

    @Test
    func `activity refresh invalidates decoded state after an external store commit`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 8)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let initial = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        var reduced = fixture.canonical
        try reduced.files.removeValue(forKey: #require(reduced.files.keys.min()))
        #expect(!fixture.save(reduced).catchUpRequired)
        recorder.reset()
        let refreshed = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))

        #expect(initial.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        #expect(refreshed.daily.map(\.totalTokens) == [(fixture.rowCount - 8) * 13])
        let work = recorder.snapshot()
        #expect(work.integrityChecks == 0)
        #expect(work.cacheConversions == 1)
        #expect(work.fileRows == fixture.fileCount - 1)
        #expect(work.readViewConversions == 1)
    }

    @Test
    func `activity refresh reopens and validates a replacement database`() async throws {
        let fixture = try ReadWorkFixture(fileCount: 4, rowsPerFile: 8)
        defer { fixture.remove() }
        let recorder = CostUsageStoreReadWorkRecorder(databaseURL: fixture.store.databaseURL)
        CostUsageStore.readWorkRecorderForTesting = recorder
        defer { CostUsageStore.readWorkRecorderForTesting = nil }

        let initial = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        let replacementRoot = fixture.env.root.appendingPathComponent("replacement")
        let replacement = CostUsageStore(cacheRoot: replacementRoot)
        var reduced = fixture.canonical
        try reduced.files.removeValue(forKey: #require(reduced.files.keys.min()))
        #expect(!replacement.syncSaveCodexCache(
            reduced,
            calendar: fixture.calendar,
            requestedScanWindow: (sinceKey: ReadWorkFixture.day, untilKey: ReadWorkFixture.day)).catchUpRequired)
        #expect(await replacement.truncateWALForTesting())
        await replacement.closeConnectionForTesting()
        #expect(await fixture.store.truncateWALForTesting())
        let originalDirectory = fixture.store.databaseURL.deletingLastPathComponent()
        try FileManager.default.moveItem(
            at: originalDirectory,
            to: fixture.env.root.appendingPathComponent("retired-store"))
        try FileManager.default.moveItem(
            at: replacement.databaseURL.deletingLastPathComponent(),
            to: originalDirectory)

        let refreshed = try #require(await CostUsageFetcher.loadCachedCodexTokenActivity(
            now: fixture.now,
            maximumDays: 365,
            scannerOptions: fixture.options))
        #expect(initial.daily.map(\.totalTokens) == [fixture.rowCount * 13])
        #expect(refreshed.daily.map(\.totalTokens) == [(fixture.rowCount - 8) * 13])
        #expect(recorder.snapshot().integrityChecks == 2)
    }

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
