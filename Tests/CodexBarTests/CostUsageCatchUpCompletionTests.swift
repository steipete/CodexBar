import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageCatchUpCompletionTests {
    @Test
    func `touched old Codex file drains catch-up and permits exact proof`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let oldDay = try #require(Calendar.current.date(byAdding: .day, value: -10, to: day))
        let oldISO = env.isoString(for: oldDay)
        let currentISO = env.isoString(for: day)
        let oldURL = try env.writeCodexSessionFile(
            day: oldDay,
            filename: "rollout-old.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(oldISO)","payload":{"session_id":"resumed-session"}}"#,
                #"{"type":"turn_context","timestamp":"\#(oldISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(oldISO)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":50,"cached_input_tokens":10,"output_tokens":5},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")
        let currentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "rollout-current.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(currentISO)","payload":{"session_id":"resumed-session"}}"#,
                #"{"type":"turn_context","timestamp":"\#(currentISO)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(currentISO)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: oldURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(120)],
            ofItemAtPath: currentURL.path)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        let proofRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = proofRecorder

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(180),
            options: options)

        let completedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(completedCache.files[oldURL.path] == nil)
        #expect(completedCache.files[currentURL.path] != nil)
        #expect(proofRecorder.snapshot().codexProgressAccountingVisits == 1)
        #expect(completedCache.codexActiveLookbackState == nil)
        #expect(completedCache.codexScanInventoryPaths == [currentURL.path])
        #expect(completedCache.codexScanCatchUpPending == false)

        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        var damagedCache = completedCache
        damagedCache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(damagedCache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: [oldURL.path],
            completedCurrentWindowRootPaths: roots,
            completedCurrentWindowFlatRootPaths: roots)
        damagedCache.codexScanInventoryPaths = nil
        damagedCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: damagedCache)

        options.codexScanWorkRecorderForTesting = nil
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(181),
            options: options)
        let repairedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(repairedCache.codexActiveLookbackState == nil)
        #expect(repairedCache.codexScanCatchUpPending == false)
    }

    @Test
    func `unprocessed pending Codex file remains queued`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let cachedURL = try env.writeCodexSessionFile(
            day: day,
            filename: "a-cached.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"cached"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let pendingURL = try env.writeCodexSessionFile(
            day: day,
            filename: "b-pending.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"pending"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            ].joined(separator: "\n") + "\n")
        let cachedHandle = try FileHandle(forWritingTo: cachedURL)
        try cachedHandle.seekToEnd()
        try cachedHandle.write(contentsOf: Data("\n".utf8))
        try cachedHandle.close()

        var pendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        pendingCache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(pendingCache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: [cachedURL.path, pendingURL.path],
            completedCurrentWindowRootPaths: roots,
            completedCurrentWindowFlatRootPaths: roots)
        pendingCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: pendingCache)

        options.maxCodexScanBytesPerRefresh = 1
        options.maxCodexScanDurationPerRefresh = 60
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let deferredCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(deferredCache.files[pendingURL.path] == nil)
        #expect(deferredCache.codexActiveLookbackState?.pendingFilePaths.contains(pendingURL.path) == true)
        #expect(deferredCache.codexScanCatchUpPending == true)
    }

    @Test
    func `device identity restoration queues validation beyond the bounded slice`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let corpusSize = 600
        for index in 0..<corpusSize {
            _ = try env.writeCodexSessionFile(
                day: day,
                filename: String(format: "identity-%04d.jsonl", index),
                contents: [
                    #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"identity-\#(index)"}}"#,
                    #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                    // swiftlint:disable:next line_length
                    #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":1,"cached_input_tokens":0,"output_tokens":0},"model":"openai/gpt-5.2-codex"}}}"#,
                ].joined(separator: "\n") + "\n")
        }
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        let snapshot = await store.readSnapshot()
        #expect(snapshot.files.count == corpusSize)
        for var file in snapshot.files {
            let identity = try #require(file.scanState.fileIdentity)
            let inode = try #require(identity.split(separator: ":").last)
            file.scanState.fileIdentity = "0:\(inode)"
            #expect(await store.upsertFile(file))
        }

        let counter = IdentityValidationCounter()
        CostUsageStore.codexCatchUpReconciliationVisitForTesting = { counter.increment() }
        defer { CostUsageStore.codexCatchUpReconciliationVisitForTesting = nil }
        let restored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)

        #expect(counter.value == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(restored.codexActiveLookbackState?.pendingFilePaths.count
            == corpusSize - CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(restored.codexScanCatchUpPending == true)
    }

    @Test
    func `completion reconciliation requires the current scan inventory`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        for sessionID in ["current-window", "retained-wider-window"] {
            _ = try env.writeCodexSessionFile(
                day: day,
                filename: "\(sessionID).jsonl",
                contents: [
                    #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"\#(sessionID)"}}"#,
                    #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                    #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                        + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                        + #""model":"openai/gpt-5.2-codex"}}}"#,
                ].joined(separator: "\n") + "\n")
        }

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var staleCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(staleCache.files.count == 2)
        let currentPath = try #require(staleCache.files.keys.first(where: {
            $0.hasSuffix("current-window.jsonl")
        }))
        staleCache.files.removeValue(forKey: currentPath)
        staleCache.codexScanInventoryPaths = [currentPath]
        staleCache.codexScanTotalFiles = 1
        staleCache.codexScanCompletedFiles = 0
        staleCache.codexScanProcessedBytes = 0
        staleCache.codexScanCatchUpPending = true
        staleCache.codexActiveLookbackState = nil

        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: staleCache)

        let retainedPendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(retainedPendingCache.files.count == 1)
        #expect(retainedPendingCache.codexScanCatchUpPending == true)
        #expect(retainedPendingCache.codexScanCompletedFiles == 0)
        #expect(await CostUsageStore(cacheRoot: env.cacheRoot).fetchMetadata().catchUpPending)
    }

    @Test
    func `missing identity-drift candidate remains queued for scanner removal`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "missing-drift.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"missing-drift"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
            ].joined(separator: "\n") + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"))
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var staleCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let path = try #require(staleCache.files.keys.first)
        var usage = try #require(staleCache.files[path])
        let identity = try #require(usage.codexScanFileId)
        let inode = try #require(identity.split(separator: ":").last)
        usage.codexScanFileId = "0:\(inode)"
        staleCache.files[path] = usage
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        staleCache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(staleCache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: [path])
        staleCache.codexScanCatchUpPending = true
        try FileManager.default.removeItem(at: fileURL)
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: staleCache)

        let restored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(restored.codexActiveLookbackState?.pendingFilePaths == [path])
        #expect(restored.codexScanCatchUpPending == true)
    }

    @Test
    func `scan window reset preserves the bounded pending queue`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        let pendingPaths = try (0..<600).map { index in
            try env.writeCodexSessionFile(
                day: day,
                filename: "queued-\(index).jsonl",
                contents: "").standardizedFileURL.path
        }
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        var metadata = await store.fetchMetadata()
        metadata.scanSinceDay = "2026-05-09"
        metadata.catchUpPending = true
        #expect(await store.setMetadata(metadata))
        #expect(await store.setLookbackState(CostUsageStoreLookbackState(
            scanSinceDay: "2026-05-09",
            rootPaths: roots,
            nextDayByRoot: [:],
            nextDirectoryOffsetByRoot: [:],
            completedRootPaths: roots,
            pendingFilePaths: pendingPaths,
            legacyRecursivePendingRootPaths: [],
            currentWindowNextDayKeyByRoot: [:],
            currentWindowDirectoryOffsetByRoot: [:],
            completedCurrentWindowRootPaths: roots,
            currentWindowFlatDirectoryOffsetByRoot: [:],
            completedCurrentWindowFlatRootPaths: roots,
            cacheWideMigrationQueueActive: nil)))

        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let restored = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexFileScanAttempts == CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(restored.codexActiveLookbackState?.pendingFilePaths.count
            == pendingPaths.count - CostUsageScanner.codexCatchUpScanCandidateLimit)
        #expect(restored.codexScanCatchUpPending == true)
    }

    @Test
    func `bounded catch-up clears already complete files from a retained lookback queue`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let iso = env.isoString(for: day)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "retained-complete.jsonl",
            contents: [
                #"{"type":"session_meta","timestamp":"\#(iso)","payload":{"session_id":"retained-complete"}}"#,
                #"{"type":"turn_context","timestamp":"\#(iso)","payload":{"model":"openai/gpt-5.2-codex"}}"#,
                #"{"type":"event_msg","timestamp":"\#(iso)","payload":{"type":"token_count","info":"#
                    + #"{"total_token_usage":{"input_tokens":100,"cached_input_tokens":20,"output_tokens":10},"#
                    + #""model":"openai/gpt-5.2-codex"}}}"#,
            ].joined(separator: "\n") + "\n")

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            maxCodexScanDurationPerRefresh: 60)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var staleCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let roots = CostUsageScanner.codexSessionsRoots(options: options)
            .map { $0.resolvingSymlinksInPath().standardizedFileURL.path }
            .sorted()
        #expect(staleCache.files.count == 1)
        let path = try #require(staleCache.files.keys.first)
        var completedUsage = try #require(staleCache.files[path])
        let currentIdentity = try #require(completedUsage.codexScanFileId)
        let inode = try #require(currentIdentity.split(separator: ":").last)
        completedUsage.codexScanFileId = "0:\(inode)"
        #expect(completedUsage.codexScanFileId != currentIdentity)
        #expect(completedUsage.codexTokenIndexAnchor != nil)
        staleCache.files[path] = completedUsage
        let normalizedPath = path.hasPrefix("/var/")
            ? "/private" + path
            : path.replacingOccurrences(
                of: "/private/var/",
                with: "/var/",
                options: [.anchored])
        #expect(normalizedPath != path)
        staleCache.codexActiveLookbackState = try CostUsageCodexActiveLookbackState(
            scanSinceKey: #require(staleCache.scanSinceKey),
            rootPaths: roots,
            completedRootPaths: roots,
            pendingFilePaths: [path, normalizedPath])
        staleCache.codexScanCatchUpPending = true
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: staleCache)
        #expect(await CostUsageStore(cacheRoot: env.cacheRoot).fetchMetadata().catchUpPending == true)

        let repairedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(repairedCache.codexActiveLookbackState?.pendingFilePaths.isEmpty == true)
        #expect(repairedCache.codexScanCatchUpPending == true)
        #expect(repairedCache.files[path]?.codexScanFileId == currentIdentity)

        options.maxCodexScanDurationPerRefresh = nil
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)

        let completedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(recorder.snapshot().codexFileScanAttempts == 1)
        #expect(completedCache.codexActiveLookbackState == nil)
        #expect(completedCache.codexScanCatchUpPending == false)
        #expect(completedCache.files.count == 1)
        #expect(completedCache.files.values.first?.codexScanComplete == true)

        var staleProgressCache = completedCache
        var staleProgressUsage = try #require(staleProgressCache.files[path])
        staleProgressUsage.codexScanFileId = "0:\(inode)"
        staleProgressCache.files[path] = staleProgressUsage
        staleProgressCache.codexActiveLookbackState = nil
        staleProgressCache.codexScanCatchUpPending = true
        staleProgressCache.codexScanProcessedBytes = 0
        staleProgressCache.codexScanCompletedFiles = 0
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: staleProgressCache)
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try handle.seekToEnd()
        try handle.write(contentsOf: Data("\n".utf8))
        try handle.close()

        let normalizedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(normalizedCache.files[path]?.codexScanFileId == currentIdentity)
        #expect(normalizedCache.files[path]?.codexScanComplete == false)

        let normalizedRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = normalizedRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)

        let normalizedCompletedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(normalizedRecorder.snapshot().codexFileScanAttempts == 1)
        #expect(normalizedCompletedCache.codexScanCatchUpPending == false)
        #expect(normalizedCompletedCache.codexScanProcessedBytes == normalizedCompletedCache.codexScanTotalBytes)
        #expect(normalizedCompletedCache.codexScanCompletedFiles == normalizedCompletedCache.codexScanTotalFiles)

        var appendedWhilePendingCache = normalizedCompletedCache
        appendedWhilePendingCache.codexScanCatchUpPending = true
        appendedWhilePendingCache.codexScanProcessedBytes = 0
        appendedWhilePendingCache.codexScanCompletedFiles = 0
        CostUsageStoreAccess.replace(cacheRoot: env.cacheRoot, cache: appendedWhilePendingCache)
        #expect(await CostUsageStore(cacheRoot: env.cacheRoot).fetchMetadata().catchUpPending == false)
        let secondHandle = try FileHandle(forWritingTo: URL(fileURLWithPath: path))
        try secondHandle.seekToEnd()
        try secondHandle.write(contentsOf: Data("\n".utf8))
        try secondHandle.close()

        let repairedPendingCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(repairedPendingCache.codexScanCatchUpPending == false)
        #expect(repairedPendingCache.codexScanProcessedBytes == repairedPendingCache.codexScanTotalBytes)
        #expect(repairedPendingCache.codexScanCompletedFiles == repairedPendingCache.codexScanTotalFiles)

        let appendedRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = appendedRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)

        let appendedCompletedCache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        #expect(appendedRecorder.snapshot().codexFileScanAttempts == 1)
        #expect(appendedCompletedCache.codexScanCatchUpPending == false)
        #expect(appendedCompletedCache.codexScanProcessedBytes == appendedCompletedCache.codexScanTotalBytes)
        #expect(appendedCompletedCache.codexScanCompletedFiles == appendedCompletedCache.codexScanTotalFiles)
    }
}

private final class IdentityValidationCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.count
    }

    func increment() {
        self.lock.lock()
        self.count += 1
        self.lock.unlock()
    }
}
