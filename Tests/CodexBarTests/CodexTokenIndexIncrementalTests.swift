import Foundation
import Testing
#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif
@testable import CodexBarCore

@Suite(.serialized)
struct CodexTokenIndexIncrementalTests {
    @Test
    // This end-to-end recovery case intentionally keeps setup, cache damage, and repair assertions together.
    // swiftlint:disable:next function_body_length
    func `missing parent sidecar rebuilds from byte zero and resolves its fork child`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentISO = env.isoString(for: day)
        let firstParentUsageISO = env.isoString(for: day.addingTimeInterval(1))
        let forkISO = env.isoString(for: day.addingTimeInterval(2))
        let secondParentUsageISO = env.isoString(for: day.addingTimeInterval(3))
        let firstChildUsageISO = env.isoString(for: day.addingTimeInterval(4))
        let secondChildUsageISO = env.isoString(for: day.addingTimeInterval(5))

        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "000-sidecar-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": parentISO,
                    "payload": ["session_id": "sidecar-parent"],
                ],
                [
                    "type": "turn_context",
                    "timestamp": parentISO,
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                Self.tokenCount(timestamp: firstParentUsageISO, input: 100),
                Self.tokenCount(timestamp: secondParentUsageISO, input: 200),
            ]))
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "100-sidecar-child.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": forkISO,
                    "payload": [
                        "session_id": "sidecar-child",
                        "forked_from_id": "sidecar-parent",
                        "timestamp": forkISO,
                    ],
                ],
                [
                    "type": "turn_context",
                    "timestamp": firstChildUsageISO,
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                Self.tokenCount(timestamp: firstChildUsageISO, input: 150),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0,
            preferNewestCodexSessionsFirst: false)
        options.refreshMinIntervalSeconds = 0

        var publishedCache = CostUsageCache()
        for pass in 0..<4 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            publishedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let parent = publishedCache.files.values.first { $0.sessionId == "sidecar-parent" }
            let child = publishedCache.files.values.first { $0.sessionId == "sidecar-child" }
            if parent?.codexTokenSidecarState?.eventCount == 2,
               parent?.codexScanComplete == true,
               child?.days.isEmpty == false,
               child?.codexDeferredForkScan != true
            {
                break
            }
        }

        let publishedParent = try #require(
            publishedCache.files.values.first { $0.sessionId == "sidecar-parent" })
        let publishedChild = try #require(
            publishedCache.files.values.first { $0.sessionId == "sidecar-child" })
        #expect(publishedParent.codexTokenSidecarState?.eventCount == 2)
        #expect(publishedParent.codexScanComplete == true)
        #expect(publishedParent.codexTokenSnapshots == nil)
        #expect(!publishedChild.days.isEmpty)
        #expect(publishedChild.codexDeferredForkScan != true)

        let parentMetadata = CostUsageScanner.codexFileMetadata(fileURL: parentURL)
        let publishedReference = try #require(CostUsageScanner.codexTokenIndexReference(
            fileURL: parentURL,
            fileId: publishedParent.codexScanFileId,
            anchor: publishedParent.codexTokenIndexAnchor,
            state: publishedParent.codexTokenSidecarState,
            isComplete: true))
        let store = CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot)
        #expect(store.contains(publishedReference))

        // Simulate a lost/corrupt SQLite parent row after JSON cursor B was published. Keep every
        // other source so this failure is isolated to the exact parent reference the child needs.
        let retainedSidecarPaths = Set(publishedCache.files.compactMap { path, usage -> String? in
            guard usage.sessionId != "sidecar-parent", usage.codexTokenSidecarState != nil else {
                return nil
            }
            return CostUsageCodexTokenIndexStore.sourcePath(for: URL(fileURLWithPath: path))
        })
        store.removeEntries(excluding: retainedSidecarPaths)
        #expect(!store.contains(publishedReference))
        let stillPublished = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(stillPublished.files.values.first {
            $0.sessionId == "sidecar-parent"
        }?.codexTokenSidecarState?.eventCount == 2)

        // Make the already-published child need its inherited baseline again. A normal refresh
        // must reject the fresh-looking parent cache, rebuild its exact sidecar from byte zero,
        // then resolve this appended child instead of leaving it permanently deferred.
        let appendedChild = try env.jsonl([
            Self.tokenCount(timestamp: secondChildUsageISO, input: 180),
        ])
        let childHandle = try FileHandle(forWritingTo: childURL)
        try childHandle.seekToEnd()
        try childHandle.write(contentsOf: Data(appendedChild.utf8))
        try childHandle.close()

        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("control-cache", isDirectory: true)
        var controlCache = CostUsageCache()
        for pass in 0..<4 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(100 + pass)),
                options: controlOptions)
            controlCache = CostUsageCacheIO.load(
                provider: .codex,
                cacheRoot: controlOptions.cacheRoot)
            let child = controlCache.files.values.first { $0.sessionId == "sidecar-child" }
            if child?.days.isEmpty == false, child?.codexDeferredForkScan != true {
                break
            }
        }
        let controlChild = try #require(
            controlCache.files.values.first { $0.sessionId == "sidecar-child" })
        #expect(!controlChild.days.isEmpty)
        #expect(controlChild.codexDeferredForkScan != true)

        var repairedCache = CostUsageCache()
        for pass in 0..<6 {
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(200 + pass)),
                options: options)
            repairedCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let parent = repairedCache.files.values.first { $0.sessionId == "sidecar-parent" }
            let child = repairedCache.files.values.first { $0.sessionId == "sidecar-child" }
            if parent?.codexTokenSidecarState?.eventCount == 2,
               child?.days == controlChild.days,
               child?.codexDeferredForkScan != true
            {
                break
            }
        }

        let repairedParent = try #require(
            repairedCache.files.values.first { $0.sessionId == "sidecar-parent" })
        let repairedChild = try #require(
            repairedCache.files.values.first { $0.sessionId == "sidecar-child" })
        let repairedReference = try #require(CostUsageScanner.codexTokenIndexReference(
            fileURL: parentURL,
            fileId: repairedParent.codexScanFileId,
            anchor: repairedParent.codexTokenIndexAnchor,
            state: repairedParent.codexTokenSidecarState,
            isComplete: repairedParent.codexScanComplete == true))
        #expect(repairedParent.parsedBytes == parentMetadata.size)
        #expect(repairedParent.codexTokenIndexAnchor?.indexedBytes == parentMetadata.size)
        #expect(repairedParent.codexTokenSidecarState?.eventCount == 2)
        #expect(repairedParent.codexTokenSnapshots == nil)
        #expect(store.contains(repairedReference))
        #expect(repairedChild.days == controlChild.days)
        #expect(repairedChild.codexDeferredForkScan != true)
        #expect(repairedChild.forkBaselineDependencyKey?.hasPrefix("file|sidecar-parent|") == true)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `append with a stripped legacy prefix rebuilds the complete token index`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "redacted-parent.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": ["id": "redacted-parent"],
                ],
                [
                    "type": "turn_context",
                    "timestamp": timestamp,
                    "payload": ["model": "openai/gpt-5.4"],
                ],
                Self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(1)),
                    input: 100),
                Self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(2)),
                    input: 200),
            ]))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        var cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let parentEntry = try #require(cache.files.first { $0.value.sessionId == "redacted-parent" })
        #expect(parentEntry.value.codexTokenSidecarState?.eventCount == 2)
        #expect(parentEntry.value.codexTokenSnapshots == nil)
        cache.files[parentEntry.key]?.codexTokenSidecarState = nil
        cache.files[parentEntry.key]?.codexTokenSnapshots = nil
        cache.files[parentEntry.key]?.codexTokenCheckpoints = nil
        cache.files[parentEntry.key]?.codexTokenTimestampsMonotonic = nil
        CostUsageCacheIO.save(
            provider: .codex,
            cache: cache,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)

        let appended = try env.jsonl([Self.tokenCount(
            timestamp: env.isoString(for: day.addingTimeInterval(3)),
            input: 300)])
        let handle = try FileHandle(forWritingTo: parentURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(appended.utf8))
        try handle.close()

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let rebuilt = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let rebuiltParent = try #require(rebuilt.files.values.first { $0.sessionId == "redacted-parent" })
        #expect(rebuiltParent.codexTokenSidecarState?.eventCount == 3)
        #expect(rebuiltParent.codexTokenSnapshots == nil)
        #expect(rebuiltParent.codexTokenCheckpoints == nil)
        #expect(rebuiltParent.codexTokenIndexAnchor?.indexedBytes
            == CostUsageScanner.codexFileMetadata(fileURL: parentURL).size)
    }

    @Test
    func `busy sidecar preserves the published suffix cursor until retry`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "busy-sidecar.jsonl",
            contents: env.jsonl([
                [
                    "type": "session_meta",
                    "timestamp": timestamp,
                    "payload": ["session_id": "busy-sidecar-session"],
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
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let beforeEntry = try #require(before.files.first { $0.value.sessionId == "busy-sidecar-session" })
        let path = beforeEntry.key
        let beforeUsage = beforeEntry.value
        #expect(beforeUsage.codexScanFileId == CostUsageScanner.codexFileMetadata(fileURL: fileURL).fileId)
        #expect(beforeUsage.codexTokenSidecarState?.eventCount == 1)

        let suffix = try env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 200),
        ])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()

        let databaseURL = CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot).databaseURL()
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer {
            if let connection = db {
                sqlite3_exec(connection, "ROLLBACK", nil, nil, nil)
                sqlite3_close(connection)
            }
        }
        try #require(sqlite3_exec(db, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredUsage = try #require(deferred.files[path])
        #expect(deferredUsage.parsedBytes == beforeUsage.parsedBytes)
        #expect(deferredUsage.codexTokenIndexAnchor == beforeUsage.codexTokenIndexAnchor)
        #expect(deferredUsage.codexTokenSidecarState == beforeUsage.codexTokenSidecarState)
        #expect(deferredUsage.days == beforeUsage.days)
        #expect(deferred.days == before.days)
        #expect(deferred.codexScanCatchUpPending == true)

        try #require(sqlite3_exec(db, "ROLLBACK", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(db)
        db = nil

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("busy-sidecar-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: controlOptions)
        let repaired = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let repairedUsage = try #require(repaired.files[path])
        #expect(repairedUsage.parsedBytes == CostUsageScanner.codexFileMetadata(fileURL: fileURL).size)
        #expect(repairedUsage.codexTokenSidecarState?.eventCount == 2)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
        #else
        #expect(Bool(true))
        #endif
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
