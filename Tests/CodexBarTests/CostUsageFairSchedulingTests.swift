import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageFairSchedulingTests {
    @Test(arguments: [false, true])
    func `waiting partial files advance under continual fresh work`(timed: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let slice: Int64 = 1024
        var options = Self.options(env: env, slice: slice, budget: slice * 3)
        let waiting = try (0..<3).map { index in
            try Self.write(
                env: env,
                day: day,
                name: "old-\(index)",
                rows: index == 0 ? 20 : 80,
                mtime: day.addingTimeInterval(Double(index)))
        }
        _ = Self.scan(day: day, pass: 0, options: options)
        let seeded = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for url in waiting {
            #expect((seeded.files[url.path]?.parsedBytes ?? 0) > 0)
            #expect(seeded.files[url.path]?.codexScanComplete == false)
        }
        options.maxCodexScanBytesPerRefresh = slice
        options.maxCodexScanDurationPerRefresh = timed ? 60 : nil
        for pass in 1...4 {
            let handle = try FileHandle(forWritingTo: waiting[0])
            try handle.seekToEnd()
            try handle
                .write(contentsOf: Data(Self.rows(env: env, day: day, indices: (80 * pass)..<(80 * pass + 8)).utf8))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: day.addingTimeInterval(Double(pass * 10))],
                ofItemAtPath: waiting[0].path)
            let fresh = try Self.write(
                env: env,
                day: day,
                name: "fresh-\(pass)",
                rows: 40,
                mtime: day.addingTimeInterval(Double(pass * 10 + 1)))
            #expect(CostUsageScanner.codexFileMetadata(fileURL: fresh).size > slice)
            let before = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            _ = Self.scan(day: day, pass: pass, options: options)
            let after = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            let advanced = after.files.reduce(Int64(0)) { total, pair in
                total + max(0, (pair.value.parsedBytes ?? 0) - (before.files[pair.key]?.parsedBytes ?? 0))
            }
            #expect(advanced <= slice, "pending and fresh work must share the original ceiling")
        }
        let final = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for url in waiting {
            #expect((final.files[url.path]?.parsedBytes ?? 0) > (seeded.files[url.path]?.parsedBytes ?? 0))
        }
    }

    private static func options(env: CostUsageTestEnvironment, slice: Int64, budget: Int64) -> CostUsageScanner
    .Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: slice,
            maxCodexScanBytesPerRefresh: budget)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    @Test(arguments: [false, true])
    func `rotation reaches beyond the selected prefix and drains to exact inventory`(timed: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let slice: Int64 = 512
        let count = CostUsageScanner.codexCatchUpScanCandidateLimit + 2
        let waiting = try (0..<count).map { index in
            try Self.write(
                env: env,
                day: day,
                name: String(format: "old-%04d", index),
                rows: 5,
                mtime: day.addingTimeInterval(Double(index)))
        }
        var options = Self.options(env: env, slice: slice, budget: slice * Int64(count))
        _ = Self.scan(day: day, pass: 0, options: options)
        var seeded = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
        let paths = waiting.map(\.path)
        #expect(seeded.files.count == count)
        #expect(seeded.files.values.allSatisfy { $0.codexScanComplete == false })
        seeded.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(seeded.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: paths,
            currentWindowNextDayKeyByRoot: [:],
            currentWindowDirectoryOffsetByRoot: [:],
            completedCurrentWindowRootPaths: roots,
            currentWindowFlatDirectoryOffsetByRoot: [:],
            completedCurrentWindowFlatRootPaths: roots)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: seeded)
        options.maxCodexScanDurationPerRefresh = timed ? 60 : nil
        options.maxCodexScanBytesPerRefresh = slice * 512
        var freshPaths: [String] = []
        for pass in 1...2 {
            let fresh = try (0..<260).map { index in
                try Self.write(
                    env: env,
                    day: day,
                    name: "fresh-\(pass)-\(index)",
                    rows: 5,
                    mtime: day.addingTimeInterval(Double(1000 + pass * 260 + index)))
            }
            freshPaths.append(contentsOf: fresh.map(\.path))
            let freshBytes = fresh.reduce(Int64(0)) { $0 + CostUsageScanner.codexFileMetadata(fileURL: $1).size }
            #expect(freshBytes > options.maxCodexScanBytesPerRefresh)
            let handle = try FileHandle(forWritingTo: waiting[0])
            try handle.seekToEnd()
            try handle
                .write(contentsOf: Data(Self.rows(env: env, day: day, indices: (10 * pass)..<(10 * pass + 5)).utf8))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: day.addingTimeInterval(Double(900 + pass))],
                ofItemAtPath: waiting[0].path)
            let recorder = CostUsageScanner.CodexScanWorkRecorder()
            let budget = CostUsageScanner.CodexScanBudget(
                maxFileBytes: slice,
                maxBytesPerRefresh: options.maxCodexScanBytesPerRefresh,
                maxDuration: timed ? 60 : nil)
            options.codexScanBudgetForTesting = budget
            options.codexScanWorkRecorderForTesting = recorder
            _ = Self.scan(day: day, pass: pass, options: options)
            let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            #expect(budget.bytesConsumed <= options.maxCodexScanBytesPerRefresh)
            #expect(recorder.snapshot().codexCandidateSelectionVisits <= 512)
            #expect(recorder.snapshot().codexFileScanAttempts <= 512)
            if pass == 1 {
                #expect(Array(cache.codexActiveLookbackState?.pendingFilePaths.prefix(2) ?? []) ==
                    Array(paths.suffix(2)))
                #expect(cache.files[paths[count - 1]]?.parsedBytes == seeded.files[paths[count - 1]]?.parsedBytes)
            } else {
                for path in paths {
                    #expect((cache.files[path]?.parsedBytes ?? 0) > (seeded.files[path]?.parsedBytes ?? 0))
                }
            }
        }
        // Stop writing and let persisted passes finish, including the final inventory proof.
        options.codexScanBudgetForTesting = nil
        var report: CostUsageDailyReport?
        var drained = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for pass in 3...30 {
            report = Self.scan(day: day, pass: pass, options: options)
            drained = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
            if drained.codexScanCatchUpPending == false { break }
        }
        #expect(drained.codexScanCatchUpPending == false)
        #expect(drained.codexActiveLookbackState == nil)
        #expect(Set(drained.codexScanInventoryPaths ?? []) == Set(paths + freshPaths))
        #expect(drained.files.values.allSatisfy { $0.codexScanComplete == true })
        var unbounded = Self.options(env: env, slice: 0, budget: 0)
        unbounded.cacheRoot = env.root.appendingPathComponent("independent-cache")
        unbounded.forceRescan = true
        let expected = Self.scan(day: day, pass: 2000, options: unbounded)
        #expect(report?.summary?.totalTokens == expected.summary?.totalTokens)
        #expect(report?.summary?.totalInputTokens == expected.summary?.totalInputTokens)
        #expect(report?.summary?.totalOutputTokens == expected.summary?.totalOutputTokens)
        #expect(report?.summary?.cacheReadTokens == expected.summary?.cacheReadTokens)
        #expect(abs((report?.summary?.totalCostUSD ?? 0) - (expected.summary?.totalCostUSD ?? 0)) < 0.000_000_001)
        print("[fair-scheduling-proof] timed=\(timed) waiting=\(count) inventory=\(drained.files.count) "
            + "tokens=\(expected.summary?.totalTokens ?? 0) cost=\(expected.summary?.totalCostUSD ?? 0) "
            + "all waiters advanced; bounded drain matches independent unbounded scan")
    }

    @Test(arguments: [false, true])
    func `outer admission stops pending scans when the controlled deadline expires`(afterWork: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let waiting = try (0..<3).map { index in
            try Self.write(
                env: env,
                day: day,
                name: "old-\(index)",
                rows: 40,
                mtime: day.addingTimeInterval(Double(index)))
        }
        var options = Self.options(env: env, slice: 1024, budget: 3072)
        _ = Self.scan(day: day, pass: 0, options: options)
        let before = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        let clock = FairSchedulingClock()
        let budget = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 1024,
            maxBytesPerRefresh: 3072,
            maxDuration: 2,
            now: { recorder.snapshot().usageRowsProcessed > 0 ? clock.expired : clock.now() })
        if !afterWork { clock.expire() }
        options.codexScanBudgetForTesting = budget
        options.codexScanWorkRecorderForTesting = recorder
        _ = Self.scan(day: day, pass: 1, options: options)
        let after = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexFileScanAttempts == (afterWork ? 1 : 0))
        #expect(budget.bytesConsumed == (afterWork ? 1024 : 0))
        #expect(budget.deferredByTimeBudgetFileCount == 1)
        let advanced = waiting.filter { after.files[$0.path]?.parsedBytes != before.files[$0.path]?.parsedBytes }
        #expect(advanced.count == (afterWork ? 1 : 0))
        #expect(after.codexScanCatchUpPending == true)
    }

    @Test(arguments: [false, true])
    func `deduplicating the selected prefix does not admit its unmaterialized tail`(timed: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let waiting = try ["first", "tail"].map {
            try Self.write(env: env, day: day, name: $0, rows: 40, mtime: day)
        }
        var options = Self.options(env: env, slice: 512, budget: 1024)
        _ = Self.scan(day: day, pass: 0, options: options)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
        cache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(cache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: Array(repeating: waiting[0].path, count: 512) + [waiting[1].path],
            completedCurrentWindowRootPaths: roots,
            completedCurrentWindowFlatRootPaths: roots)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        let budget = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 512, maxBytesPerRefresh: 1024, maxDuration: timed ? 60 : nil)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanBudgetForTesting = budget
        options.codexScanWorkRecorderForTesting = recorder
        _ = Self.scan(day: day, pass: 1, options: options)
        let after = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexCandidateSelectionVisits == 1)
        #expect(budget.bytesConsumed == 512)
        #expect(after.files[waiting[1].path]?.parsedBytes == cache.files[waiting[1].path]?.parsedBytes)
        #expect(after.codexActiveLookbackState?.pendingFilePaths == [waiting[1].path, waiting[0].path])
    }

    @Test
    func `production SQLite adoption preserves real partial rows resume state and scoped report`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        _ = try Self.write(env: env, day: day, name: "partial", rows: 40, mtime: day)
        var unbounded = Self.options(env: env, slice: 0, budget: 0)
        unbounded.cacheRoot = env.root.appendingPathComponent("complete-cache")
        let report = Self.scan(day: day, pass: 0, options: unbounded)
        let complete = CostUsageStoreAccess.read(cacheRoot: unbounded.cacheRoot)
        let options = Self.options(env: env, slice: 1024, budget: 1024)
        _ = Self.scan(day: day, pass: 0, options: options)
        var partial = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day, calendar: options.calendar)
        partial.codexPreviousReport = CostUsageCodexPreviousReport(
            report: report, cache: complete, reportSinceKey: range.sinceKey, reportUntilKey: range.untilKey)
        #expect(partial.files.values.first?.codexScanComplete == false)
        #expect(partial.files.values.first?.codexRows?.isEmpty == false)
        #expect(partial.files.values.first?.codexJSONLResumeState != nil)
        let upgradedRoot = env.root.appendingPathComponent("upgraded-cache")
        let hash = "c6c46a376ba16304"
        let predecessor = CostUsageStore(
            cacheRoot: upgradedRoot,
            schemaVersion: CostUsageStore.combinedSchemaVersion(
                base: CostUsageStore.baseSchemaVersion, parserHash: hash),
            parserHash: hash)
        _ = predecessor.syncSaveCodexCache(
            partial,
            calendar: options.calendar,
            requestedScanWindow: (range.scanSinceKey, range.scanUntilKey),
            reportWindow: (range.sinceKey, range.untilKey))
        let before = await predecessor.readSnapshot()
        let current = CostUsageStore(cacheRoot: upgradedRoot)
        #expect(await current.readSnapshot() == before)
        #expect(await current.rebuildCount == 0)
        let adopted = current.syncLoadCodexCache(calendar: options.calendar)
        #expect(adopted.files.mapValues(\.parsedBytes) == partial.files.mapValues(\.parsedBytes))
        #expect(adopted.files.mapValues(\.codexJSONLResumeState) == partial.files.mapValues(\.codexJSONLResumeState))
        #expect(adopted.codexPreviousReport == partial.codexPreviousReport)
        #expect(adopted.codexPreviousReport?.report.data == report.data)
    }

    private static func scan(day: Date, pass: Int, options: CostUsageScanner.Options) -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(Double(pass)),
            options: options)
    }

    @Test
    func `byte limited backlog leaves capacity for an append to a known completed file`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let live = try Self.write(env: env, day: day, name: "live", rows: 1, mtime: day.addingTimeInterval(100))
        _ = try Self.write(env: env, day: day, name: "partial", rows: 40, mtime: day)
        var options = Self.options(env: env, slice: 1024, budget: 2048)
        _ = Self.scan(day: day, pass: 0, options: options)
        _ = Self.scan(day: day, pass: 1, options: options)
        let before = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(before.files[live.path]?.codexScanComplete == true)
        #expect(before.codexActiveLookbackState?.pendingFilePaths.isEmpty == false)
        let handle = try FileHandle(forWritingTo: live)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(Self.rows(env: env, day: day, indices: [2]).utf8))
        try handle.close()
        try FileManager.default.setAttributes([.modificationDate: day.addingTimeInterval(200)], ofItemAtPath: live.path)
        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 1024, maxBytesPerRefresh: 2048)
        options.codexScanBudgetForTesting = budget
        _ = Self.scan(day: day, pass: 2, options: options)
        let after = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(after.files[live.path]?.lastCountedTotals?.input == 200)
        #expect(after.files[live.path]?.codexScanComplete == true)
        #expect(budget.bytesConsumed > 1024)
        #expect(budget.bytesConsumed <= 2048)
    }

    @Test(arguments: [false, true])
    func `fresh work receives capacity after every pending file has a turn`(timed: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let waiting = try (0..<3).map { index in
            try Self.write(
                env: env,
                day: day,
                name: "old-\(index)",
                rows: 40,
                mtime: day.addingTimeInterval(Double(index)))
        }
        var options = Self.options(env: env, slice: 1024, budget: 3072)
        _ = Self.scan(day: day, pass: 0, options: options)
        let before = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let fresh = try Self.write(
            env: env,
            day: day,
            name: "fresh",
            rows: 80,
            mtime: day.addingTimeInterval(100))
        #expect(CostUsageScanner.codexFileMetadata(fileURL: fresh).size > 4096)
        let budget = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 1024,
            maxBytesPerRefresh: 4096,
            maxDuration: timed ? 60 : nil)
        options.codexScanBudgetForTesting = budget
        _ = Self.scan(day: day, pass: 1, options: options)
        let after = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        for url in waiting {
            #expect((after.files[url.path]?.parsedBytes ?? 0) == (before.files[url.path]?.parsedBytes ?? 0) + 1024)
        }
        #expect(after.files[fresh.path]?.parsedBytes == 1024)
        #expect(budget.bytesConsumed == 4096)
    }

    @Test
    func `both discovery windows append without sorting existing waiters`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let oldDay = try #require(Calendar.current.date(byAdding: .day, value: -3, to: day))
        let waiting = try ["z-waiting", "m-waiting"].map {
            try Self.write(env: env, day: day, name: $0, rows: 40, mtime: day)
        }
        var options = Self.options(env: env, slice: 1024, budget: 2048)
        _ = Self.scan(day: day, pass: 0, options: options)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }.sorted()
        cache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(cache.scanSinceKey), rootPaths: roots, pendingFilePaths: waiting.map(\.path))
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: cache)
        let current = try Self.write(env: env, day: day, name: "a-current", rows: 2, mtime: day)
        let lookback = try Self.write(env: env, day: oldDay, name: "a-lookback", rows: 2, mtime: day)
        let clock = FairSchedulingClock()
        options.codexScanBudgetForTesting = CostUsageScanner.CodexScanBudget(
            maxFileBytes: 1024, maxBytesPerRefresh: 2048, maxDuration: 2, now: { clock.now() })
        clock.expire()
        _ = Self.scan(day: day, pass: 1, options: options)
        let queued = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).codexActiveLookbackState)
        #expect(Array(queued.pendingFilePaths.prefix(2)) == waiting.map(\.path))
        #expect(queued.pendingFilePaths.contains(current.path))
        #expect(queued.pendingFilePaths.contains(lookback.path))
    }

    private static func write(
        env: CostUsageTestEnvironment,
        day: Date,
        name: String,
        rows: Int,
        mtime: Date) throws -> URL
    {
        let header = #"{"type":"session_meta","payload":{"id":"\#(name)"}}"# + "\n"
        let url = try env.writeCodexSessionFile(
            day: day,
            filename: name + ".jsonl",
            contents: header + Self.rows(env: env, day: day, indices: 1...rows))
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
        return url
    }

    private static func rows(env: CostUsageTestEnvironment, day: Date, indices: some Sequence<Int>) -> String {
        let iso = env.isoString(for: day)
        return indices.map { index in
            // swiftlint:disable:next line_length
            #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(index * 100),"cached_input_tokens":0,"output_tokens":\#(index * 10)},"model":"gpt-5.2-codex"}}}"#
        }.joined(separator: "\n") + "\n"
    }
}

private final class FairSchedulingClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock.now
    private var isExpired = false
    var expired: ContinuousClock.Instant {
        self.origin.advanced(by: .seconds(3))
    }

    func now() -> ContinuousClock.Instant {
        self.lock.withLock { self.isExpired ? self.expired : self.origin }
    }

    func expire() {
        self.lock.withLock { self.isExpired = true }
    }
}
