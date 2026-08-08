import Foundation
import Testing
@testable import CodexBarCore

/// Corpus-scale probes for the SQLite store foundation (#2760 phase 1). The shapes mirror
/// the #2637 incident corpora (~1.5k session files, large per-file payloads, 30-day window)
/// so phase 2/3 performance work has failing/passing gates before the JSON path is deleted.
struct CostUsageStoreScaleProofTests {
    private static let windowDays = 30

    @Test
    func `incident shaped corpus stays fast and bounded`() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = Calendar(identifier: .gregorian)
        // Freeze the reference date so a run spanning midnight cannot push age-zero data
        // past the window bounds and make the zero-prune assertion flaky.
        let reference = Date()
        guard let windowSince = Self.dayString(
            daysAgo: Self.windowDays - 1,
            calendar: calendar,
            reference: reference),
            let windowUntil = Self.dayString(daysAgo: 0, calendar: calendar, reference: reference)
        else {
            Issue.record("failed to build window bounds")
            return
        }

        let bulkStarted = ContinuousClock.now
        for fileIndex in 0..<1500 {
            let age = fileIndex % Self.windowDays
            guard let day = Self.dayString(daysAgo: age, calendar: calendar, reference: reference) else {
                Issue.record("failed to build day string")
                return
            }
            let path = "/rollouts/session-\(fileIndex).jsonl"
            #expect(await store.upsertFile(Self.file(path: path, day: day, ordinal: fileIndex)))
            let snapshots = (0..<100).map { eventIndex in
                Self.snapshot(path: path, eventIndex: eventIndex, day: day)
            }
            #expect(await store.appendTokenSnapshots(snapshots))
            // Spread models independently of the day (fileIndex % 30 correlates with % 3).
            let aggregate = Self.aggregate(day: day, model: "model-\((fileIndex / 30) % 3)")
            #expect(await store.replaceFileDayAggregates(
                path: path,
                aggregates: [aggregate]))
            #expect(await store.mergeDayAggregates([aggregate]))
        }
        let bulkElapsed = ContinuousClock.now - bulkStarted

        let bulkFileBytes = await store.fileSizeBytes()

        // A corpus spanning exactly the active window leaves the out-of-window prune no work.
        let pruneStarted = ContinuousClock.now
        let pruned = await store.retainDayWindow(sinceDay: windowSince, untilDay: windowUntil)
        let pruneElapsed = ContinuousClock.now - pruneStarted
        #expect(pruned.deletedFiles == 0)
        #expect(pruned.deletedTokenSnapshots == 0)
        #expect(pruned.deletedDayAggregates == 0)

        let reportStarted = ContinuousClock.now
        let report = await store.readReport(sinceDay: windowSince, untilDay: windowUntil)
        let reportElapsed = ContinuousClock.now - reportStarted
        #expect(report.aggregates.count == Self.windowDays * 3)

        let snapshotStarted = ContinuousClock.now
        let snapshot = await store.readSnapshot()
        let snapshotElapsed = ContinuousClock.now - snapshotStarted
        #expect(snapshot.files.count == 1500)
        #expect(snapshot.tokenSnapshots.count == 150_000)

        print("[scale-proof] bulk load 1.5k files/150k snapshots: \(Self.milliseconds(bulkElapsed)) ms")
        print("[scale-proof] db file after bulk load: \(bulkFileBytes / 1_048_576) MiB")
        print("[scale-proof] no-op out-of-window prune: \(Self.milliseconds(pruneElapsed)) ms")
        print("[scale-proof] readReport(30 days): \(Self.milliseconds(reportElapsed)) ms")
        print("[scale-proof] readSnapshot(150k rows): \(Self.milliseconds(snapshotElapsed)) ms")

        // Generous gates so CI hardware variance does not flake; these catch order-of-magnitude
        // regressions (e.g. accidental full rewrites or missing indexes) rather than jitter.
        #expect(Self.milliseconds(bulkElapsed) < 120_000)
        #expect(Self.milliseconds(pruneElapsed) < 2000)
        #expect(Self.milliseconds(reportElapsed) < 1000)
        #expect(Self.milliseconds(snapshotElapsed) < 10000)
        #expect(bulkFileBytes < 300 * 1_048_576)
    }

    @Test
    func `window prune shrinks corpus and reclaims file bytes`() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        let calendar = Calendar(identifier: .gregorian)
        // Same frozen reference as the incident-shaped test: deterministic day keys.
        let reference = Date()
        guard let sinceDay = Self.dayString(daysAgo: 7, calendar: calendar, reference: reference),
              let untilDay = Self.dayString(daysAgo: 0, calendar: calendar, reference: reference)
        else {
            Issue.record("failed to build window bounds")
            return
        }

        for fileIndex in 0..<500 {
            let age = fileIndex % 30
            guard let day = Self.dayString(daysAgo: age, calendar: calendar, reference: reference) else {
                Issue.record("failed to build day string")
                return
            }
            let path = "/rollouts/window-\(fileIndex).jsonl"
            #expect(await store.upsertFile(Self.file(path: path, day: day, ordinal: fileIndex)))
            let snapshots = (0..<50).map { eventIndex in
                Self.snapshot(path: path, eventIndex: eventIndex, day: day)
            }
            #expect(await store.appendTokenSnapshots(snapshots))
            let aggregate = Self.aggregate(day: day, model: "model-\(fileIndex % 3)")
            #expect(await store.replaceFileDayAggregates(path: path, aggregates: [aggregate]))
            #expect(await store.mergeDayAggregates([aggregate]))
        }
        let beforeBytes = await store.fileSizeBytes()

        let pruneStarted = ContinuousClock.now
        let result = await store.retainDayWindow(sinceDay: sinceDay, untilDay: untilDay)
        let pruneElapsed = ContinuousClock.now - pruneStarted
        let afterBytes = await store.fileSizeBytes()
        let snapshot = await store.readSnapshot()

        // Ages 0...7 survive: 16 full 30-day cycles contribute 128 files and the remaining
        // 20 indices contribute 8 more, so the retained corpus is deterministically 136.
        let survivors = snapshot.files.count
        #expect(survivors == 136)
        #expect(snapshot.files.allSatisfy { file in
            guard let coverage = file.coverageUntilDay else { return false }
            return coverage >= sinceDay && coverage <= untilDay
        })
        #expect(snapshot.dayAggregates.allSatisfy { $0.day >= sinceDay && $0.day <= untilDay })
        #expect(result.deletedFiles == 500 - survivors)
        #expect(result.deletedFiles > 0)
        #expect(afterBytes < beforeBytes)

        print("[scale-proof] window prune 500 -> \(survivors) files: \(Self.milliseconds(pruneElapsed)) ms, ")
        print("[scale-proof] db file \(beforeBytes / 1_048_576) -> \(afterBytes / 1_048_576) MiB")
        #expect(Self.milliseconds(pruneElapsed) < 5000)
    }

    @Test
    func `legacy sized payload round trips without whole artifact blowup`() async throws {
        let fixture = try ScaleFixture()
        defer { fixture.remove() }
        let store = CostUsageStore(cacheRoot: fixture.root)
        // Mirror the ~100 MiB legacy artifact as one worst-case deferred-replay payload.
        let path = "/rollouts/blob.jsonl"
        #expect(await store.upsertFile(Self.file(path: path, day: "2026-08-01", ordinal: 0)))
        let payload = Data(repeating: 0x61, count: 100 * 1_048_576)
        let line = CostUsageStoreBufferedLine(
            path: path,
            kind: .deferredReplay,
            lineIndex: 0,
            ordinal: nil,
            endOffset: Int64(payload.count),
            payload: payload)

        let writeStarted = ContinuousClock.now
        #expect(await store.replaceBufferedLines(path: path, kind: .deferredReplay, lines: [line]))
        let writeElapsed = ContinuousClock.now - writeStarted
        let persistedBytes = await store.fileSizeBytes()

        let readStarted = ContinuousClock.now
        let fetched = await store.fetchBufferedLines(path: path, kind: .deferredReplay)
        let readElapsed = ContinuousClock.now - readStarted
        #expect(fetched == [line])

        print("[scale-proof] 100 MiB blob write: \(Self.milliseconds(writeElapsed)) ms, ")
        print("[scale-proof] db file after 100 MiB blob: \(persistedBytes / 1_048_576) MiB")
        print("[scale-proof] 100 MiB blob read: \(Self.milliseconds(readElapsed)) ms")
        #expect(Self.milliseconds(writeElapsed) < 5000)
        #expect(Self.milliseconds(readElapsed) < 5000)
        // Keep the persisted representation bounded so a second whole-artifact copy cannot
        // hide behind a successful round trip.
        #expect(persistedBytes < 256 * 1_048_576)
    }
}

// MARK: - Helpers

extension CostUsageStoreScaleProofTests {
    private static func dayString(
        daysAgo: Int,
        calendar: Calendar,
        reference: Date) -> String?
    {
        guard let date = calendar.date(byAdding: .day, value: -daysAgo, to: reference) else { return nil }
        return self.dayString(for: date, calendar: calendar)
    }

    private static func dayString(for date: Date, calendar: Calendar) -> String {
        let components = calendar.dateComponents([.year, .month, .day], from: date)
        let year = components.year ?? 0
        let month = components.month ?? 0
        let day = components.day ?? 0
        return String(format: "%04d-%02d-%02d", year, month, day)
    }

    private static func milliseconds(_ duration: Duration) -> Int64 {
        let components = duration.components
        return components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000
    }

    private static func file(path: String, day: String, ordinal: Int) -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: path,
            inode: Int64(ordinal),
            mtimeUnixMs: 1000 + Int64(ordinal),
            size: 5000 + Int64(ordinal),
            parsedBytes: 4000,
            anchor: CostUsageStoreValidationAnchor(indexedBytes: 4000, windowStart: 144, sha256: "abc123"),
            scanState: CostUsageStoreScanState(
                targetSize: 5000,
                isComplete: true,
                resumePayload: nil,
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: 100,
                lastModel: "gpt-5.6-sol",
                lastTurnID: "turn-\(ordinal)"),
            sessionID: "session-\(path)",
            coverageSinceDay: day,
            coverageUntilDay: day,
            updatedAtUnixMs: 1000 + Int64(ordinal))
    }

    private static func snapshot(path: String, eventIndex: Int, day: String) -> CostUsageStoreTokenSnapshot {
        CostUsageStoreTokenSnapshot(
            path: path,
            eventIndex: eventIndex,
            timestamp: "\(day)T12:00:00Z",
            timestampUnixMs: 1_754_046_000_000 + Int64(eventIndex),
            day: day,
            last: CostUsageStoreTotals(input: 2, cached: 1, output: 3, reasoning: 1),
            total: CostUsageStoreTotals(input: 20, cached: 10, output: 30, reasoning: 5),
            endOffset: 100 + Int64(eventIndex))
    }

    private static func aggregate(day: String, model: String) -> CostUsageStoreDayAggregate {
        CostUsageStoreDayAggregate(
            day: day,
            model: model,
            inputTokens: 10,
            cachedTokens: 2,
            outputTokens: 3,
            reasoningTokens: 1,
            requestCount: 1,
            knownCostNanos: 1000,
            unpricedTokens: 4,
            standardCostNanos: 600,
            priorityCostNanos: 400,
            standardTokens: 9,
            priorityTokens: 6)
    }
}

private struct ScaleFixture: Sendable {
    let root: URL

    init() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBar-CostUsageStoreScaleProof-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    func remove() {
        try? FileManager.default.removeItem(at: self.root)
    }
}
