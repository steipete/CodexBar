import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCodexRefreshLockTests {
    @Test
    func `same cache root contends until the lease is released`() throws {
        let cacheRoot = self.makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }

        let first = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
        guard case let .acquired(firstLease) = first else {
            Issue.record("Expected the first refresh lease to be acquired")
            return
        }

        let overlapping = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
        guard case .contended = overlapping else {
            Issue.record("Expected the overlapping refresh to observe contention")
            firstLease.release()
            return
        }

        let lockURL = CostUsageCodexRefreshLock.lockFileURL(cacheRoot: cacheRoot)
        #expect(lockURL.lastPathComponent == "codex-refresh.lock")
        #expect(lockURL.deletingLastPathComponent() == cacheRoot)
        #expect(FileManager.default.fileExists(atPath: lockURL.path))

        firstLease.release()
        firstLease.release()

        let afterRelease = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
        guard case let .acquired(secondLease) = afterRelease else {
            Issue.record("Expected acquisition to recover after release")
            return
        }
        secondLease.release()
    }

    @Test
    func `cache clear cannot unlink around an active refresh lease`() throws {
        let cacheRoot = self.makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: cacheRoot) }
        let artifact = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
        try FileManager.default.createDirectory(
            at: artifact.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("published".utf8).write(to: artifact)

        let acquisition = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
        guard case let .acquired(lease) = acquisition else {
            Issue.record("Expected the test to own the refresh lease")
            return
        }

        #expect(try CostUsageFetcher.clearCostUsageCache(cacheRoot: cacheRoot) == .deferredByConcurrentWriter)
        #expect(FileManager.default.fileExists(atPath: artifact.path))
        #expect(FileManager.default.fileExists(
            atPath: CostUsageCodexRefreshLock.lockFileURL(cacheRoot: cacheRoot).path))

        lease.release()
        #expect(try CostUsageFetcher.clearCostUsageCache(cacheRoot: cacheRoot) == .cleared)
        #expect(!FileManager.default.fileExists(atPath: artifact.deletingLastPathComponent().path))
        #expect(FileManager.default.fileExists(
            atPath: CostUsageCodexRefreshLock.lockFileURL(cacheRoot: cacheRoot).path))
        #expect(FileManager.default.fileExists(
            atPath: CostUsageCodexRefreshLock.clearBarrierFileURL(cacheRoot: cacheRoot).path))

        let rebuilt = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: cacheRoot)
        guard case let .acquired(rebuiltLease) = rebuilt else {
            Issue.record("Expected refresh acquisition after cache clear")
            return
        }
        rebuiltLease.release()
    }

    @Test
    func `different cache roots have independent lock domains`() throws {
        let firstRoot = self.makeCacheRoot()
        let secondRoot = self.makeCacheRoot()
        defer {
            try? FileManager.default.removeItem(at: firstRoot)
            try? FileManager.default.removeItem(at: secondRoot)
        }

        let first = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: firstRoot)
        guard case let .acquired(firstLease) = first else {
            Issue.record("Expected the first cache root lease to be acquired")
            return
        }
        defer { firstLease.release() }

        let second = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: secondRoot)
        guard case let .acquired(secondLease) = second else {
            Issue.record("A different cache root must not share the first lock domain")
            return
        }
        secondLease.release()
    }

    @Test
    func `global clear waits for a nested account refresh without unlinking its lock`() async throws {
        let globalRoot = self.makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: globalRoot) }
        let accountRoot = globalRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("redacted-account", isDirectory: true)
        let accountArtifact = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: accountRoot)
        try FileManager.default.createDirectory(
            at: accountArtifact.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try Data("published".utf8).write(to: accountArtifact)

        #expect(
            CostUsageCodexRefreshLock.clearBarrierFileURL(
                cacheRoot: accountRoot,
                lockDomainRoot: globalRoot)
                == CostUsageCodexRefreshLock.clearBarrierFileURL(
                    cacheRoot: globalRoot,
                    lockDomainRoot: globalRoot))
        #expect(
            CostUsageCodexRefreshLock.lockFileURL(cacheRoot: accountRoot)
                != CostUsageCodexRefreshLock.lockFileURL(cacheRoot: globalRoot))

        let acquisition = try CostUsageCodexRefreshLock.tryAcquire(
            cacheRoot: accountRoot,
            lockDomainRoot: globalRoot)
        guard case let .acquired(accountLease) = acquisition else {
            Issue.record("Expected the nested account refresh lease")
            return
        }

        let siblingRoot = globalRoot
            .appendingPathComponent("cost-usage", isDirectory: true)
            .appendingPathComponent("accounts", isDirectory: true)
            .appendingPathComponent("redacted-sibling", isDirectory: true)
        let siblingAcquisition = try CostUsageCodexRefreshLock.tryAcquire(
            cacheRoot: siblingRoot,
            lockDomainRoot: globalRoot)
        guard case let .acquired(siblingLease) = siblingAcquisition else {
            accountLease.release()
            Issue.record("Expected sibling accounts to share the barrier concurrently")
            return
        }
        siblingLease.release()

        #expect(try CostUsageFetcher.clearCostUsageCache(cacheRoot: globalRoot) == .deferredByConcurrentWriter)
        #expect(FileManager.default.fileExists(atPath: accountArtifact.path))
        #expect(FileManager.default.fileExists(
            atPath: CostUsageCodexRefreshLock.lockFileURL(cacheRoot: accountRoot).path))

        accountLease.release()
        #expect(try CostUsageFetcher.clearCostUsageCache(cacheRoot: globalRoot) == .cleared)
        #expect(!FileManager.default.fileExists(atPath: accountArtifact.path))
        #expect(FileManager.default.fileExists(
            atPath: CostUsageCodexRefreshLock.clearBarrierFileURL(
                cacheRoot: globalRoot,
                lockDomainRoot: globalRoot).path))

        let clearAcquisition = try CostUsageCodexRefreshLock.tryAcquireForClear(
            cacheRoot: globalRoot,
            lockDomainRoot: globalRoot)
        guard case let .acquired(clearLease) = clearAcquisition else {
            Issue.record("Expected the test to own the global clear barrier")
            return
        }
        let codexHome = globalRoot.appendingPathComponent("redacted-home", isDirectory: true)
        try FileManager.default.createDirectory(
            at: codexHome.appendingPathComponent("sessions", isDirectory: true),
            withIntermediateDirectories: true)
        let statusDuringClear = await CostUsageFetcher(
            cacheRoot: accountRoot,
            codexRefreshLockRoot: globalRoot)
            .codexScanCatchUpStatus(codexHomePath: codexHome.path)
        #expect(statusDuringClear.pending == true)
        #expect(statusDuringClear.deferredByConcurrentWriter == true)
        #expect(!FileManager.default.fileExists(atPath: accountRoot.path))
        clearLease.release()

        let rebuilt = try CostUsageCodexRefreshLock.tryAcquire(
            cacheRoot: accountRoot,
            lockDomainRoot: globalRoot)
        guard case let .acquired(rebuiltLease) = rebuilt else {
            Issue.record("Expected nested account refresh acquisition after global clear")
            return
        }
        rebuiltLease.release()
    }

    @Test
    func `unusable cache root throws instead of granting an unsafe lease`() throws {
        let parent = self.makeCacheRoot()
        defer { try? FileManager.default.removeItem(at: parent) }
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let fileRoot = parent.appendingPathComponent("not-a-directory", isDirectory: false)
        try Data("occupied".utf8).write(to: fileRoot)

        do {
            _ = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: fileRoot)
            Issue.record("Expected an unusable cache root to reject lock acquisition")
        } catch {
            // Expected: callers must fall back to a read-only result, never scan unlocked.
        }
    }

    @Test
    func `contended scanner stays read only then advances after release`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "refresh-lock.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": ["session_id": "refresh-lock-session"],
                ],
                [
                    "type": "turn_context",
                    "timestamp": timestamp,
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(1)), input: 100),
            ]))
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let publishedBeforeAppend = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let publishedEntry = try #require(
            publishedBeforeAppend.files.first { $0.value.sessionId == "refresh-lock-session" })
        let path = publishedEntry.key
        let usageBeforeAppend = publishedEntry.value
        #expect(usageBeforeAppend.codexTokenSidecarState?.eventCount == 1)

        let suffix = try env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 200),
        ])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
        let artifactsBeforeContention = try Self.cacheArtifactSnapshots(cacheRoot: env.cacheRoot)

        let acquisition = try CostUsageCodexRefreshLock.tryAcquire(cacheRoot: env.cacheRoot)
        guard case let .acquired(lease) = acquisition else {
            Issue.record("Expected the test to own the refresh lease")
            return
        }
        defer { lease.release() }
        var headParseCount = 0
        let contended = try CostUsageScanner.withCodexSessionHeadParseObserverForTesting {
            headParseCount += 1
        } operation: {
            try CostUsageScanner.loadCodexDailyReportCancellable(
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options,
                checkCancellation: nil)
        }
        let publishedDuringContention = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(contended.disposition == .deferredByConcurrentWriter)
        #expect(headParseCount == 0)
        #expect(try Self.cacheArtifactSnapshots(cacheRoot: env.cacheRoot) == artifactsBeforeContention)
        #expect(publishedDuringContention.files[path]?.parsedBytes == usageBeforeAppend.parsedBytes)
        #expect(publishedDuringContention.files[path]?.days == usageBeforeAppend.days)
        let fetcher = CostUsageFetcher(scannerOptions: options)
        let contendedSnapshot = try await fetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: day.addingTimeInterval(2),
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            bypassScannerDebounce: true)
        #expect(contendedSnapshot.historyCoverageIsEstablished == false)
        #expect(try Self.cacheArtifactSnapshots(cacheRoot: env.cacheRoot) == artifactsBeforeContention)
        lease.release()

        let owned = try CostUsageScanner.loadCodexDailyReportCancellable(
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options,
            checkCancellation: nil)
        let advanced = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let advancedUsage = try #require(advanced.files[path])
        let advancedReference = try #require(CostUsageScanner.codexTokenIndexReference(
            fileURL: fileURL,
            fileId: advancedUsage.codexScanFileId,
            anchor: advancedUsage.codexTokenIndexAnchor,
            state: advancedUsage.codexTokenSidecarState,
            isComplete: advancedUsage.codexScanComplete == true))
        #expect(owned.disposition == .ownedRefresh)
        #expect(advancedUsage.parsedBytes == CostUsageScanner.codexFileMetadata(fileURL: fileURL).size)
        #expect(advancedUsage.codexTokenSidecarState?.eventCount == 2)
        #expect(CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot).contains(advancedReference))

        let resumedSnapshot = try await fetcher.loadTokenSnapshot(
            provider: .codex,
            environment: [:],
            now: day.addingTimeInterval(3),
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            bypassScannerDebounce: true)
        #expect(resumedSnapshot.historyCoverageIsEstablished == true)
        #expect((resumedSnapshot.last30DaysTokens ?? 0) > (contendedSnapshot.last30DaysTokens ?? 0))

        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("refresh-lock-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: controlOptions)
        #expect(owned.report.data == control.data)
        #expect(owned.report.summary == control.summary)
    }

    private func makeCacheRoot() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexBarRefreshLockTests-\(UUID().uuidString)", isDirectory: true)
    }

    private struct CacheArtifactSnapshot: Equatable {
        let data: Data
        let modificationDate: Date?
    }

    private static func cacheArtifactSnapshots(cacheRoot: URL) throws -> [String: CacheArtifactSnapshot] {
        let directory = CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot)
            .deletingLastPathComponent()
        let candidateNames = [
            CostUsageCacheIO.cacheFileURL(provider: .codex, cacheRoot: cacheRoot).lastPathComponent,
            "codex-token-index-v2.sqlite",
            "codex-token-index-v2.sqlite-wal",
            "codex-token-index-v2.sqlite-shm",
        ]
        var snapshots: [String: CacheArtifactSnapshot] = [:]
        for name in candidateNames {
            let url = directory.appendingPathComponent(name, isDirectory: false)
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            snapshots[name] = try CacheArtifactSnapshot(
                data: Data(contentsOf: url),
                modificationDate: attributes[.modificationDate] as? Date)
        }
        return snapshots
    }

    private static func tokenCount(timestamp: String, input: Int) -> [String: Any] {
        [
            "type": "event_msg",
            "timestamp": timestamp,
            "payload": [
                "type": "token_count",
                "info": [
                    "model": "openai/gpt-5.4",
                    "total_token_usage": [
                        "input_tokens": input,
                        "cached_input_tokens": input / 10,
                        "output_tokens": input / 20,
                    ],
                ],
            ],
        ]
    }
}
