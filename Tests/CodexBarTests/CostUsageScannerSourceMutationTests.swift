// swiftlint:disable file_length
import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
// Keep the serialized source-mutation race matrix together so TaskLocal hooks cannot overlap.
// swiftlint:disable:next type_body_length
struct CostUsageScannerSourceMutationTests {
    @Test
    func `head discovery restarts at zero when a same size source is replaced during read`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let original = Self.sessionMetadataLine(timestamp: timestamp, sessionID: "old-session")
        let replacement = Self.sessionMetadataLine(timestamp: timestamp, sessionID: "new-session")
        #expect(original.utf8.count == replacement.utf8.count)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "mutable-head.jsonl",
            contents: original)
        let originalMtime = try Self.modificationDate(fileURL)
        var mutationError: Error?

        let budget = CostUsageScanner.CodexScanBudget(maxFileBytes: 4096, maxBytesPerRefresh: 4096)
        let index = CostUsageScanner.CodexSessionFileIndex(
            files: [fileURL],
            roots: [env.codexSessionsRoot],
            scanBudget: budget,
            headParseObserver: {
                do {
                    try Data(replacement.utf8).write(to: fileURL, options: .atomic)
                    try FileManager.default.setAttributes(
                        [.modificationDate: originalMtime],
                        ofItemAtPath: fileURL.path)
                } catch {
                    mutationError = error
                }
            })

        let firstLookup = try index.lookup(sessionId: "not-present")
        guard case .deferred = firstLookup else {
            Issue.record("A source replacement must defer the discovery cursor")
            return
        }
        try #require(mutationError == nil)
        let persisted = index.persistedState
        let head = try #require(persisted.headScan)
        let replacementMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(budget.deferredBySourceMutationFileCount == 1)
        #expect(head.offset == 0)
        #expect(head.resumeState == nil)
        #expect(head.sourceStamp?.mtimeUnixMs == replacementMetadata.mtimeUnixMs)
        #expect(head.sourceStamp?.size == replacementMetadata.size)
        #expect(head.sourceStamp?.fileId == replacementMetadata.fileId)
        #expect(head.sourceStamp?.changeUnixNs == replacementMetadata.changeUnixNs)
        #expect(persisted.filePathBySessionId.isEmpty)

        let retryBudget = CostUsageScanner.CodexScanBudget(maxFileBytes: 4096, maxBytesPerRefresh: 4096)
        let retryIndex = CostUsageScanner.CodexSessionFileIndex(
            files: [fileURL],
            roots: [env.codexSessionsRoot],
            cachedDiscovery: persisted,
            scanBudget: retryBudget)
        let retryLookup = try retryIndex.lookup(sessionId: "new-session")
        guard case let .found(foundURL) = retryLookup else {
            Issue.record("The stable replacement session must be discovered on retry")
            return
        }
        #expect(foundURL.standardizedFileURL == fileURL.standardizedFileURL)
    }

    @Test
    func `append mutation preserves the published cursor and aggregate days`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let prefix = try env.jsonl(Self.sessionPrefix(timestamp: timestamp, sessionID: "append-session") + [
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(1)), input: 100),
        ])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "append-mutation.jsonl",
            contents: prefix)
        var options = Self.options(env: env)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let beforeEntry = try #require(before.files.first { $0.value.sessionId == "append-session" })
        let path = beforeEntry.key
        let beforeUsage = beforeEntry.value

        let suffix = try env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 200),
        ])
        let handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(suffix.utf8))
        try handle.close()
        let replacementBody = try (String(contentsOf: fileURL, encoding: .utf8))
            .replacingOccurrences(of: #""input_tokens":200"#, with: #""input_tokens":900"#)
        #expect(try replacementBody.utf8.count == Data(contentsOf: fileURL).count)
        let appendedMtime = try Self.modificationDate(fileURL)
        var mutationError: Error?

        _ = CostUsageScanner.withCodexBeforeFileUsagePublicationHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == fileURL.standardizedFileURL else { return }
            do {
                try Data(replacementBody.utf8).write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.modificationDate: appendedMtime],
                    ofItemAtPath: fileURL.path)
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options)
        }
        try #require(mutationError == nil)

        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredUsage = try #require(deferred.files[path])
        #expect(deferredUsage.parsedBytes == beforeUsage.parsedBytes)
        #expect(deferredUsage.days == beforeUsage.days)
        #expect(deferredUsage.codexTokenIndexAnchor == beforeUsage.codexTokenIndexAnchor)
        #expect(deferredUsage.codexTokenSidecarState == beforeUsage.codexTokenSidecarState)
        #expect(deferred.days == before.days)
        #expect(deferred.codexScanCatchUpPending == true)

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        options.cacheRoot = env.root.appendingPathComponent("append-control-cache", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
    }

    @Test
    func `bounded active append advances a verified cursor on every refresh`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let padding = String(repeating: "x", count: 320)
        let body = try env.jsonl(
            Self.sessionPrefix(timestamp: timestamp, sessionID: "active-append-session")
                + [Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(1)), input: 100)]
                + (0..<64).map { index in
                    [
                        "type": "response_item",
                        "payload": ["index": index, "text": padding],
                    ] as [String: Any]
                }
                + [Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 500)])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "active-append.jsonl",
            contents: body)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: fileURL).size > 16 * 1024)

        var options = Self.options(env: env)
        options.maxCodexSessionFileBytes = 1024
        options.maxCodexScanBytesPerRefresh = 64 * 1024 * 1024
        var previousParsedBytes: Int64 = 0

        for pass in 0..<4 {
            let suffix = try env.jsonl([
                Self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(TimeInterval(3 + pass))),
                    input: 600 + pass * 100),
            ])
            var didAppend = false
            var mutationError: Error?
            _ = CostUsageScanner.withCodexAfterFileParseHookForTesting { observedURL in
                guard observedURL.standardizedFileURL == fileURL.standardizedFileURL,
                      !didAppend
                else { return }
                do {
                    try Self.append(suffix, to: fileURL)
                    didAppend = true
                } catch {
                    mutationError = error
                }
            } operation: {
                CostUsageScanner.loadDailyReport(
                    provider: .codex,
                    since: day,
                    until: day,
                    now: day.addingTimeInterval(TimeInterval(pass)),
                    options: options)
            }
            try #require(mutationError == nil)
            #expect(didAppend)

            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let usage = try #require(cache.files.values.first { $0.sessionId == "active-append-session" })
            let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
            let parsedBytes = try #require(usage.parsedBytes)
            let anchor = try #require(usage.codexTokenIndexAnchor)
            #expect(parsedBytes > previousParsedBytes)
            #expect(parsedBytes <= metadata.size)
            #expect(usage.size == metadata.size)
            #expect(usage.codexScanTargetSize == metadata.size)
            #expect(usage.codexScanChangeUnixNs == metadata.changeUnixNs)
            #expect(usage.codexScanComplete == false)
            #expect(anchor.indexedBytes == parsedBytes)
            #expect(CostUsageScanner.codexTokenIndexAnchorMatches(
                anchor,
                fileURL: fileURL,
                metadata: metadata))
            #expect(cache.codexScanCatchUpPending == true)
            previousParsedBytes = parsedBytes
        }

        var stableOptions = options
        stableOptions.maxCodexSessionFileBytes = 0
        stableOptions.maxCodexScanBytesPerRefresh = 0
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10),
            options: stableOptions)
        var controlOptions = stableOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent("active-append-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(10),
            options: controlOptions)
        let settled = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let settledUsage = try #require(settled.files.values.first { $0.sessionId == "active-append-session" })
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
        #expect(settledUsage.codexScanComplete == true)
        #expect(settled.codexScanCatchUpPending == false)
    }

    @Test
    func `bounded metadata free file advances every pass to stable EOF`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let padding = String(repeating: "x", count: 320)
        let body = try env.jsonl((0..<32).map { index in
            [
                "type": "response_item",
                "timestamp": timestamp,
                "payload": ["index": index, "text": padding],
            ] as [String: Any]
        })
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "bounded-metadata-free.jsonl",
            contents: body)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: fileURL.path)
        let sourceSize = CostUsageScanner.codexFileMetadata(fileURL: fileURL).size
        #expect(sourceSize > 8 * 1024)

        var options = Self.options(env: env)
        options.maxCodexSessionFileBytes = 1024
        options.maxCodexScanBytesPerRefresh = 1024
        var previousOffset: Int64 = 0
        var completedUsage: CostUsageFileUsage?

        for pass in 0..<32 {
            let recorder = CostUsageScanner.CodexScanWorkRecorder()
            options.codexScanWorkRecorderForTesting = recorder
            _ = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(TimeInterval(pass)),
                options: options)
            let metrics = recorder.snapshot()
            let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let usage = try #require(cache.files.values.first)
            let offset = try #require(usage.parsedBytes)

            #expect(usage.sessionId == nil)
            #expect(offset > previousOffset)
            #expect(offset <= sourceSize)
            #expect(metrics.fileParseInvocations == 1)
            #expect(metrics.fileBodyBudgetBytesConsumed > 0)
            #expect(metrics.fileBodyBudgetBytesConsumed <= 1024)
            #expect(usage.codexTokenIndexAnchor?.indexedBytes == offset)
            previousOffset = offset

            if usage.codexScanComplete == true {
                completedUsage = usage
                #expect(offset == sourceSize)
                #expect(cache.codexScanCatchUpPending == false)
                break
            }
            #expect(cache.codexScanCatchUpPending == true)
        }

        let completed = try #require(completedUsage)
        let completedRowState = try #require(completed.codexUsageRowSidecarState)
        #expect(completedRowState.rowCount == 0)

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = stableRecorder
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(60),
            options: options)
        let stableMetrics = stableRecorder.snapshot()
        let stableCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let stableUsage = try #require(stableCache.files.values.first)

        #expect(stableMetrics.fileBodyBudgetBytesConsumed == 0)
        #expect(stableMetrics.fileParseInvocations == 0)
        #expect(stableMetrics.usageRowsRead == 0)
        #expect(stableMetrics.usageRowsWritten == 0)
        #expect(stableUsage.parsedBytes == sourceSize)
        #expect(stableUsage.codexUsageRowSidecarState == completedRowState)
    }

    @Test
    func `append after a complete slice preserves the older published cursor`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let original = try env.jsonl(
            Self.sessionPrefix(timestamp: timestamp, sessionID: "complete-race-session") + [
                Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(1)), input: 100),
            ])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "complete-race.jsonl",
            contents: original)
        let options = Self.options(env: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let beforeEntry = try #require(before.files.first { $0.value.sessionId == "complete-race-session" })

        try Self.append(env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 200),
        ]), to: fileURL)
        let racingSuffix = try env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(3)), input: 300),
        ])
        var didAppend = false
        var mutationError: Error?
        _ = CostUsageScanner.withCodexAfterFileParseHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == fileURL.standardizedFileURL,
                  !didAppend
            else { return }
            do {
                try Self.append(racingSuffix, to: fileURL)
                didAppend = true
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(3),
                options: options)
        }
        try #require(mutationError == nil)
        #expect(didAppend)

        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredUsage = try #require(deferred.files[beforeEntry.key])
        #expect(deferredUsage.parsedBytes == beforeEntry.value.parsedBytes)
        #expect(deferredUsage.days == beforeEntry.value.days)
        #expect(deferredUsage.codexRows == beforeEntry.value.codexRows)
        #expect(deferredUsage.codexTokenIndexAnchor == beforeEntry.value.codexTokenIndexAnchor)
        #expect(deferredUsage.codexTokenSidecarState == beforeEntry.value.codexTokenSidecarState)
        #expect(deferred.days == before.days)
        #expect(deferred.codexScanCatchUpPending == true)

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("complete-race-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: controlOptions)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
    }

    @Test
    func `append after sidecar commit preserves JSON cursor then recovers SQLite ahead`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let original = try env.jsonl(
            Self.sessionPrefix(timestamp: timestamp, sessionID: "sqlite-ahead-race") + [
                Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(1)), input: 100),
            ])
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "sqlite-ahead-race.jsonl",
            contents: original)
        let options = Self.options(env: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let beforeEntry = try #require(before.files.first { $0.value.sessionId == "sqlite-ahead-race" })
        #expect(beforeEntry.value.codexTokenSidecarState?.eventCount == 1)

        try Self.append(env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(2)), input: 200),
        ]), to: fileURL)
        let committedMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let committedAnchor = try #require(CostUsageScanner.codexTokenIndexAnchor(
            fileURL: fileURL,
            indexedBytes: committedMetadata.size))
        let racingSuffix = try env.jsonl([
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(3)), input: 300),
        ])
        var didAppend = false
        var mutationError: Error?
        _ = CostUsageCodexTokenIndexStore.withAfterCommitHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == fileURL.standardizedFileURL,
                  !didAppend
            else { return }
            do {
                try Self.append(racingSuffix, to: fileURL)
                didAppend = true
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(3),
                options: options)
        }
        try #require(mutationError == nil)
        #expect(didAppend)

        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredUsage = try #require(deferred.files[beforeEntry.key])
        #expect(deferredUsage.parsedBytes == beforeEntry.value.parsedBytes)
        #expect(deferredUsage.days == beforeEntry.value.days)
        #expect(deferredUsage.codexRows == beforeEntry.value.codexRows)
        #expect(deferredUsage.codexTokenIndexAnchor == beforeEntry.value.codexTokenIndexAnchor)
        #expect(deferredUsage.codexTokenSidecarState == beforeEntry.value.codexTokenSidecarState)
        #expect(deferred.codexScanCatchUpPending == true)

        let aheadReference = try CostUsageCodexTokenIndexReference(
            path: CostUsageCodexTokenIndexStore.sourcePath(for: fileURL),
            fileId: #require(committedMetadata.fileId),
            indexedBytes: committedMetadata.size,
            eventCount: 2,
            anchor: committedAnchor,
            isComplete: true)
        let store = CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot)
        #expect(store.contains(aheadReference))

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("sqlite-ahead-race-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: controlOptions)
        let settled = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let settledUsage = try #require(settled.files[beforeEntry.key])
        #expect(settledUsage.codexTokenSidecarState?.eventCount == 3)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
        #expect(settled.codexScanCatchUpPending == false)
    }

    @Test
    func `cold rescan mutation publishes no mixed source state`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let original = try env.jsonl(Self.sessionPrefix(timestamp: timestamp, sessionID: "cold-session") + [
            Self.tokenCount(timestamp: env.isoString(for: day.addingTimeInterval(1)), input: 100),
        ])
        let replacement = original.replacingOccurrences(
            of: #""input_tokens":100"#,
            with: #""input_tokens":900"#)
        #expect(original.utf8.count == replacement.utf8.count)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "cold-mutation.jsonl",
            contents: original)
        let originalMtime = try Self.modificationDate(fileURL)
        let options = Self.options(env: env)
        var mutationError: Error?

        let mutationReport = CostUsageScanner.withCodexBeforeFileUsagePublicationHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == fileURL.standardizedFileURL else { return }
            do {
                try Data(replacement.utf8).write(to: fileURL, options: .atomic)
                try FileManager.default.setAttributes(
                    [.modificationDate: originalMtime],
                    ofItemAtPath: fileURL.path)
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day,
                options: options)
        }
        try #require(mutationError == nil)
        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        #expect(mutationReport.data.isEmpty)
        #expect(deferred.files.isEmpty)
        #expect(deferred.days.isEmpty)
        #expect(deferred.codexScanCatchUpPending == true)

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("cold-control-cache", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: controlOptions)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
    }

    @Test
    func `partial fork append defers when its parent changes before publication`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentTimestamp = env.isoString(for: day)
        let parentUpdateTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childTimestamp = env.isoString(for: day.addingTimeInterval(3))
        let parentEvents = [Self.tokenCount(timestamp: parentTimestamp, input: 100)]
        let parentContents = Self.sessionPrefix(
            timestamp: parentTimestamp,
            sessionID: "dependency-parent") + parentEvents
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "00-dependency-parent.jsonl",
            contents: env.jsonl(parentContents))

        var options = Self.options(env: env)
        options.maxCodexSessionFileBytes = 1024
        options.maxCodexScanBytesPerRefresh = 64 * 1024 * 1024
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let padding = String(repeating: "x", count: 380)
        let childBody = try env.jsonl(
            Self.forkSessionPrefix(
                timestamp: childTimestamp,
                sessionID: "dependency-child",
                parentSessionID: "dependency-parent",
                forkTimestamp: forkTimestamp)
                + [Self.tokenCount(timestamp: forkTimestamp, input: 200)]
                + (0..<16).map { index in
                    [
                        "type": "response_item",
                        "payload": ["index": index, "text": padding],
                    ] as [String: Any]
                }
                + [Self.tokenCount(timestamp: childTimestamp, input: 250)])
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-dependency-child.jsonl",
            contents: childBody)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: childURL).size > 4 * 1024)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let beforeChildEntry = try #require(before.files.first { $0.value.sessionId == "dependency-child" })
        let beforeChild = beforeChildEntry.value
        #expect(beforeChild.codexScanComplete == false)
        #expect(beforeChild.codexForkAccountingState != nil)
        #expect(beforeChild.forkBaselineDependencyKey != nil)

        let parentSuffix = try env.jsonl([
            Self.tokenCount(timestamp: parentUpdateTimestamp, input: 150),
        ])
        var didMutateParent = false
        var mutationError: Error?
        _ = CostUsageScanner.withCodexBeforeFileUsagePublicationHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == childURL.standardizedFileURL,
                  !didMutateParent
            else { return }
            do {
                try Self.append(parentSuffix, to: parentURL)
                didMutateParent = true
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(2),
                options: options)
        }
        try #require(mutationError == nil)
        #expect(didMutateParent)

        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredChild = try #require(deferred.files[beforeChildEntry.key])
        #expect(deferredChild.parsedBytes == beforeChild.parsedBytes)
        #expect(deferredChild.days == beforeChild.days)
        #expect(deferredChild.codexRows?.count == beforeChild.codexRows?.count)
        #expect(deferredChild.codexTokenIndexAnchor == beforeChild.codexTokenIndexAnchor)
        #expect(deferredChild.codexTokenSidecarState == beforeChild.codexTokenSidecarState)
        #expect(deferred.days == before.days)
        #expect(deferred.codexScanCatchUpPending == true)

        var stableOptions = options
        stableOptions.maxCodexSessionFileBytes = 0
        stableOptions.maxCodexScanBytesPerRefresh = 0
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: stableOptions)
        var controlOptions = stableOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent("dependency-append-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: controlOptions)
        let stableCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let controlCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: controlOptions.cacheRoot)
        let stableChild = try #require(stableCache.files.values.first { $0.sessionId == "dependency-child" })
        let controlChild = try #require(controlCache.files.values.first { $0.sessionId == "dependency-child" })
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
        #expect(stableChild.days == controlChild.days)
        #expect(stableCache.codexScanCatchUpPending == false)
    }

    @Test
    // swiftlint:disable:next function_body_length
    func `partial ordinary fork preserves cursor transiently then rebuilds a legacy parent key`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentTimestamp = env.isoString(for: day)
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childDate = day.addingTimeInterval(3)
        let childTimestamp = env.isoString(for: childDate)
        let parentSessionID = "alias-parent"
        let childSessionID = "alias-child"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "00-alias-parent.jsonl",
            contents: env.jsonl(
                Self.sessionPrefix(timestamp: parentTimestamp, sessionID: parentSessionID)
                    + [Self.tokenCount(timestamp: parentTimestamp, input: 100)]))
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: parentURL.path)

        var options = Self.options(env: env)
        options.maxCodexSessionFileBytes = 1024
        options.maxCodexScanBytesPerRefresh = 64 * 1024 * 1024
        options.preferNewestCodexSessionsFirst = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let padding = String(repeating: "x", count: 380)
        let childBody = try env.jsonl(
            Self.forkSessionPrefix(
                timestamp: childTimestamp,
                sessionID: childSessionID,
                parentSessionID: parentSessionID,
                forkTimestamp: forkTimestamp)
                + [Self.tokenCount(timestamp: forkTimestamp, input: 200)]
                + (0..<24).flatMap { index in
                    [
                        [
                            "type": "response_item",
                            "payload": ["index": index, "text": padding],
                        ] as [String: Any],
                        Self.tokenCount(
                            timestamp: env.isoString(for: childDate.addingTimeInterval(Double(index))),
                            input: 201 + index),
                    ]
                }
                + [Self.tokenCount(timestamp: env.isoString(for: childDate.addingTimeInterval(30)), input: 250)])
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-alias-child.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(60)],
            ofItemAtPath: childURL.path)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: childURL).size > 8 * 1024)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        var before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let parentEntry = try #require(before.files.first { $0.value.sessionId == parentSessionID })
        let childEntry = try #require(before.files.first { $0.value.sessionId == childSessionID })
        let beforeOffset = try #require(childEntry.value.parsedBytes)
        let beforeAnchor = try #require(childEntry.value.codexTokenIndexAnchor)
        let beforeSidecar = try #require(childEntry.value.codexTokenSidecarState)
        let beforeAccounting = try #require(childEntry.value.codexForkAccountingState)
        let beforeDays = childEntry.value.days
        let beforeRows = childEntry.value.codexRows
        let beforeProcessedBytes = before.codexScanProcessedBytes ?? 0
        let beforeReference = try #require(CostUsageScanner.codexTokenIndexReference(
            fileURL: childURL,
            fileId: childEntry.value.codexScanFileId,
            anchor: beforeAnchor,
            state: beforeSidecar,
            isComplete: false))
        #expect(childEntry.value.codexScanComplete == false)
        #expect(beforeOffset > 0)
        #expect(beforeAnchor.indexedBytes == beforeOffset)
        #expect(beforeSidecar.eventCount > 0)

        let parentDirectory = parentURL.deletingLastPathComponent()
        let aliasHop = parentDirectory.appendingPathComponent(".alias-hop", isDirectory: true)
        try FileManager.default.createDirectory(at: aliasHop, withIntermediateDirectories: true)
        let legacyParentPath = parentDirectory.path
            + "/.alias-hop/../"
            + parentURL.lastPathComponent
        #expect(legacyParentPath != parentURL.standardizedFileURL.path)
        #expect(URL(fileURLWithPath: legacyParentPath).standardizedFileURL.path
            == parentURL.standardizedFileURL.path)
        #expect(FileManager.default.fileExists(atPath: legacyParentPath))

        // Recreate the dangerous boundary from the real failure without relying on macOS's
        // `/private/var` spelling. The parent index is temporarily incomplete when the newer child
        // is visited first, and the child still carries #2648's six-field alias key.
        let parentMetadata = CostUsageScanner.codexFileMetadata(fileURL: parentURL)
        var incompleteParent = parentEntry.value
        incompleteParent.codexScanComplete = false
        var legacyChild = childEntry.value
        legacyChild.forkBaselineDependencyKey = try [
            "file",
            parentSessionID,
            legacyParentPath,
            #require(parentMetadata.fileId),
            String(parentMetadata.mtimeUnixMs),
            String(parentMetadata.size),
        ].joined(separator: "|")
        before.files[parentEntry.key] = incompleteParent
        before.files[childEntry.key] = legacyChild
        before.codexSessionDiscovery = nil
        before.codexScanCatchUpPending = true
        before.lastScanUnixMs = 0
        CostUsageCacheIO.save(provider: .codex, cache: before, cacheRoot: env.cacheRoot)

        // Rewrite the parent in place without changing the legacy key's inode, size, or mtime.
        // Only ctime proves that the inherited baseline changed, which the six-field key cannot
        // carry. Resuming the child's old accounting state here would silently use the 100-token
        // baseline after the real parent changed to 900.
        let originalParentBody = try String(contentsOf: parentURL, encoding: .utf8)
        let rewrittenParentBody = originalParentBody.replacingOccurrences(
            of: #""input_tokens":100"#,
            with: #""input_tokens":900"#)
        #expect(rewrittenParentBody != originalParentBody)
        #expect(rewrittenParentBody.utf8.count == originalParentBody.utf8.count)
        let parentHandle = try FileHandle(forWritingTo: parentURL)
        try parentHandle.truncate(atOffset: 0)
        try parentHandle.write(contentsOf: Data(rewrittenParentBody.utf8))
        try parentHandle.close()
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: parentURL.path)
        let rewrittenParentMetadata = CostUsageScanner.codexFileMetadata(fileURL: parentURL)
        #expect(rewrittenParentMetadata.fileId == parentMetadata.fileId)
        #expect(rewrittenParentMetadata.size == parentMetadata.size)
        #expect(rewrittenParentMetadata.mtimeUnixMs == parentMetadata.mtimeUnixMs)
        #expect(rewrittenParentMetadata.changeUnixNs != parentMetadata.changeUnixNs)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredChild = try #require(deferred.files.values.first { $0.sessionId == childSessionID })
        let settledParent = try #require(deferred.files.values.first { $0.sessionId == parentSessionID })
        #expect(deferredChild.parsedBytes == beforeOffset)
        #expect(deferredChild.codexTokenIndexAnchor == beforeAnchor)
        #expect(deferredChild.codexTokenSidecarState == beforeSidecar)
        #expect(deferredChild.codexForkAccountingState == beforeAccounting)
        #expect(deferredChild.days == beforeDays)
        #expect(deferredChild.codexRows == beforeRows)
        #expect(deferredChild.codexDeferredForkScan != true)
        #expect(deferredChild.forkBaselineDependencyKey == legacyChild.forkBaselineDependencyKey)
        #expect(settledParent.codexScanComplete != false)
        #expect(deferred.codexScanCatchUpPending == true)
        #expect((deferred.codexScanProcessedBytes ?? 0) >= beforeProcessedBytes)
        #expect(CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot).contains(beforeReference))

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: options)
        let restarted = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let restartedChild = try #require(restarted.files.values.first { $0.sessionId == childSessionID })
        let restartedKey = try #require(restartedChild.forkBaselineDependencyKey)
        #expect(restartedChild.parsedBytes == beforeOffset)
        #expect(restartedChild.codexTokenIndexAnchor?.indexedBytes == restartedChild.parsedBytes)
        #expect(restartedChild.codexForkAccountingState != nil)
        #expect(restartedChild.codexDeferredForkScan != true)
        #expect(restartedKey.hasPrefix("file|\(parentSessionID)|"))
        #expect(restartedKey.split(separator: "|", omittingEmptySubsequences: false).count == 7)
        #expect(try !CostUsageScanner.codexResolvedForkDependencyKeysMatch(
            restartedKey,
            #require(legacyChild.forkBaselineDependencyKey)))

        var stableOptions = options
        stableOptions.maxCodexSessionFileBytes = 0
        stableOptions.maxCodexScanBytesPerRefresh = 0
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: stableOptions)
        var controlOptions = stableOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent("legacy-key-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: controlOptions)
        let after = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let afterChild = try #require(after.files.values.first { $0.sessionId == childSessionID })
        #expect(afterChild.parsedBytes == CostUsageScanner.codexFileMetadata(fileURL: childURL).size)
        #expect(afterChild.codexScanComplete == true)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
    }

    @Test
    func `transient parent deferral registers a preserved child before its duplicate`() throws {
        try Self.assertTransientParentDeferralDeduplicatesSession(duplicateFirst: false)
    }

    @Test
    func `transient parent deferral filters a preserved child after its duplicate`() throws {
        try Self.assertTransientParentDeferralDeduplicatesSession(duplicateFirst: true)
    }

    @Test
    func `transient parent deferral preserves a zero row fork cursor`() throws {
        try Self.assertTransientParentDeferralDeduplicatesSession(
            duplicateFirst: true,
            childProducesUsage: false)
    }

    @Test
    func `missing parent marker suppresses a later nonfork copy`() throws {
        try Self.assertMissingParentMarkerOwnsSession(duplicateFirst: false)
    }

    @Test
    func `missing parent marker removes an earlier nonfork copy`() throws {
        try Self.assertMissingParentMarkerOwnsSession(duplicateFirst: true)
    }

    @Test
    func `full fork rescan defers when its parent changes before publication`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentTimestamp = env.isoString(for: day)
        let parentUpdateTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childTimestamp = env.isoString(for: day.addingTimeInterval(3))
        let parentEvents = [Self.tokenCount(timestamp: parentTimestamp, input: 100)]
        let parentContents = Self.sessionPrefix(
            timestamp: parentTimestamp,
            sessionID: "full-parent") + parentEvents
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "00-full-parent.jsonl",
            contents: env.jsonl(parentContents))
        var options = Self.options(env: env)
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)

        let childEvents = [
            Self.tokenCount(timestamp: forkTimestamp, input: 200),
            Self.tokenCount(timestamp: childTimestamp, input: 250),
        ]
        let childContents = Self.forkSessionPrefix(
            timestamp: childTimestamp,
            sessionID: "full-child",
            parentSessionID: "full-parent",
            forkTimestamp: forkTimestamp) + childEvents
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-full-child.jsonl",
            contents: env.jsonl(childContents))
        let parentSuffix = try env.jsonl([
            Self.tokenCount(timestamp: parentUpdateTimestamp, input: 150),
        ])
        var didMutateParent = false
        var mutationError: Error?
        _ = CostUsageScanner.withCodexBeforeFileUsagePublicationHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == childURL.standardizedFileURL,
                  !didMutateParent
            else { return }
            do {
                try Self.append(parentSuffix, to: parentURL)
                didMutateParent = true
            } catch {
                mutationError = error
            }
        } operation: {
            CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(1),
                options: options)
        }
        try #require(mutationError == nil)
        #expect(didMutateParent)

        let deferred = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let deferredChild = try #require(deferred.files.values.first { $0.sessionId == "full-child" })
        #expect(deferredChild.days.isEmpty)
        #expect(deferredChild.parsedBytes == 0)
        #expect(deferredChild.codexRows?.isEmpty != false)
        #expect(deferredChild.codexTokenSidecarState == nil)
        #expect(deferred.days == before.days)
        #expect(deferred.codexScanCatchUpPending == true)

        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("dependency-full-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: controlOptions)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)
    }

    @Test
    func `replacement full rescan drops stale out of window source detail`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let oldDay = try env.makeLocalNoon(year: 2026, month: 5, day: 1)
        let newDay = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let oldTimestamp = env.isoString(for: oldDay)
        let newTimestamp = env.isoString(for: newDay)
        let oldBody = try env.jsonl([
            Self.sessionMetadata(
                timestamp: oldTimestamp,
                sessionID: "old-source",
                cwd: "/redacted/old-project"),
            Self.turnContext(
                timestamp: oldTimestamp,
                cwd: "/redacted/old-project",
                title: "old-title"),
            Self.tokenCount(timestamp: oldTimestamp, input: 100),
            Self.turnContext(
                timestamp: newTimestamp,
                cwd: "/redacted/old-project",
                title: "old-title"),
            Self.tokenCount(timestamp: newTimestamp, input: 200),
        ])
        let fileURL = try env.writeCodexSessionFile(
            day: newDay,
            filename: "replacement-detail.jsonl",
            contents: oldBody)
        let options = Self.options(env: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: oldDay,
            until: newDay,
            now: newDay,
            options: options)
        let oldDayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: oldDay)
        let originalCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let originalEntry = try #require(originalCache.files.first { $0.value.sessionId == "old-source" })
        let originalUsage = originalEntry.value
        let originalRows = try CodexPublishedUsageRowsTestSupport.load(
            path: originalEntry.key,
            usage: originalUsage,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        let narrowRange = CostUsageScanner.CostUsageDayRange(
            since: newDay,
            until: newDay,
            calendar: options.calendar)
        #expect(originalCache.scanSinceKey != narrowRange.scanSinceKey)
        #expect(originalCache.days[oldDayKey] != nil)
        #expect(originalRows.contains { $0.day == oldDayKey })
        #expect(originalUsage.codexCostNanos?[oldDayKey] != nil)
        #expect(originalUsage.codexStandardCostNanos?[oldDayKey] != nil)
        #expect(originalUsage.codexStandardTokens?[oldDayKey] != nil)
        #expect(originalUsage.codexSession?.title == "old-title")
        #expect(originalUsage.projectPath == "/redacted/old-project")

        let replacement = try env.jsonl([
            Self.sessionMetadata(
                timestamp: newTimestamp,
                sessionID: "new-source",
                cwd: "/redacted/new-project"),
            Self.turnContext(
                timestamp: newTimestamp,
                cwd: "/redacted/new-project",
                title: nil),
            Self.tokenCount(timestamp: newTimestamp, input: 900),
        ])
        try Data(replacement.utf8).write(to: fileURL, options: .atomic)

        let rewritten = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay.addingTimeInterval(1),
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let usageEntry = try #require(cache.files.first { $0.value.sessionId == "new-source" })
        let usage = usageEntry.value
        let rows = try CodexPublishedUsageRowsTestSupport.load(
            path: usageEntry.key,
            usage: usage,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        #expect(cache.files.values.contains { $0.sessionId == "old-source" } == false)
        #expect(cache.scanSinceKey == narrowRange.scanSinceKey)
        #expect(cache.scanUntilKey == narrowRange.scanUntilKey)
        #expect(cache.days[oldDayKey] == nil)
        #expect(usage.days[oldDayKey] == nil)
        #expect(!rows.contains { $0.day == oldDayKey })
        #expect(usage.codexCostNanos?[oldDayKey] == nil)
        #expect(usage.codexPrioritySurchargeNanos?[oldDayKey] == nil)
        #expect(usage.codexStandardCostNanos?[oldDayKey] == nil)
        #expect(usage.codexPriorityCostNanos?[oldDayKey] == nil)
        #expect(usage.codexStandardTokens?[oldDayKey] == nil)
        #expect(usage.codexPriorityTokens?[oldDayKey] == nil)
        #expect(usage.projectPath == "/redacted/new-project")
        #expect(usage.canonicalProjectPath == "/redacted/new-project")
        #expect(usage.codexSession?.cwd == "/redacted/new-project")
        #expect(usage.codexSession?.title == nil)
        #expect(usage.codexSession?.startedAtUnixMs == Int64(newDay.timeIntervalSince1970 * 1000))

        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent("replacement-detail-control", isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: newDay,
            until: newDay,
            now: newDay.addingTimeInterval(1),
            options: controlOptions)
        #expect(rewritten.data == control.data)
        #expect(rewritten.summary == control.summary)
    }

    @Test
    func `same session fork replacement is not suppressed by stale authority`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let parentSessionID = "replacement-parent"
        let sessionID = "replacement-same-session"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "00-replacement-parent.jsonl",
            contents: env.jsonl(
                Self.sessionPrefix(timestamp: timestamp, sessionID: parentSessionID)
                    + [Self.tokenCount(timestamp: timestamp, input: 100)]))
        let sourceURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-replacement-child.jsonl",
            contents: env.jsonl(
                Self.forkSessionPrefix(
                    timestamp: timestamp,
                    sessionID: sessionID,
                    parentSessionID: parentSessionID,
                    forkTimestamp: timestamp)
                    + [Self.tokenCount(timestamp: timestamp, input: 200)]))
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: parentURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(1)],
            ofItemAtPath: sourceURL.path)

        var options = Self.options(env: env)
        options.preferNewestCodexSessionsFirst = false
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let forkUsage = try #require(before.files.values.first { $0.sessionId == sessionID })
        let oldFileID = try #require(forkUsage.codexScanFileId)
        #expect(forkUsage.forkedFromId == parentSessionID)
        #expect(!forkUsage.days.isEmpty)

        let replacement = try env.jsonl(
            Self.sessionPrefix(timestamp: timestamp, sessionID: sessionID)
                + [Self.tokenCount(timestamp: timestamp, input: 700)])
        try Data(replacement.utf8).write(to: sourceURL, options: .atomic)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(1)],
            ofItemAtPath: sourceURL.path)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: sourceURL).fileId != oldFileID)

        let rewritten = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let rewrittenCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let rewrittenEntry = try #require(rewrittenCache.files.first { $0.value.sessionId == sessionID })
        let rewrittenUsage = rewrittenEntry.value
        let rewrittenRows = try CodexPublishedUsageRowsTestSupport.load(
            path: rewrittenEntry.key,
            usage: rewrittenUsage,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        #expect(rewrittenUsage.forkedFromId == nil)
        #expect(!rewrittenUsage.days.isEmpty)
        #expect(!rewrittenRows.isEmpty)

        var controlOptions = options
        controlOptions.cacheRoot = env.root.appendingPathComponent(
            "same-session-replacement-control",
            isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: controlOptions)
        #expect(rewritten.data == control.data)
        #expect(rewritten.summary == control.summary)
    }

    @Test
    func `post parent retry inherits fork copy row ownership`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentTimestamp = env.isoString(for: day)
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(1))
        let childTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let parentSessionID = "retry-parent"
        let childSessionID = "retry-child"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "00-retry-parent.jsonl",
            contents: env.jsonl(
                Self.sessionPrefix(timestamp: parentTimestamp, sessionID: parentSessionID)
                    + [Self.tokenCount(timestamp: parentTimestamp, input: 100)]))
        let childEvents = [
            Self.tokenCount(timestamp: forkTimestamp, input: 200),
            Self.tokenCount(timestamp: childTimestamp, input: 250),
        ]
        let childBody = try env.jsonl(
            Self.forkSessionPrefix(
                timestamp: childTimestamp,
                sessionID: childSessionID,
                parentSessionID: parentSessionID,
                forkTimestamp: forkTimestamp)
                + childEvents)
        let firstChildURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-retry-child-a.jsonl",
            contents: childBody)
        let secondChildURL = try env.writeCodexSessionFile(
            day: day,
            filename: "02-retry-child-b.jsonl",
            contents: childBody)
        try FileManager.default.setAttributes([.modificationDate: day], ofItemAtPath: parentURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(3)],
            ofItemAtPath: firstChildURL.path)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(2)],
            ofItemAtPath: secondChildURL.path)

        var options = Self.options(env: env)
        options.preferNewestCodexSessionsFirst = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(4),
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let childEntries = cache.files.filter { $0.value.sessionId == childSessionID }
        let childUsages = childEntries.map(\.value)
        let childRows = try childEntries.flatMap {
            try CodexPublishedUsageRowsTestSupport.load(
                path: $0.key,
                usage: $0.value,
                cacheRoot: env.cacheRoot,
                calendar: options.calendar)
        }
        let uniqueChildRows = Set(childRows.map {
            CostUsageScanner.codexUsageRowKey(sessionId: childSessionID, row: $0)
        })
        let childDay = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let childTotals = childUsages.reduce([0, 0, 0]) { totals, usage in
            let packed = usage.days[childDay]?.values.first ?? []
            var merged = totals
            for index in 0..<min(merged.count, packed.count) {
                merged[index] += packed[index]
            }
            return merged
        }
        #expect(childUsages.count == 2)
        #expect(childUsages.count(where: { !$0.days.isEmpty }) == 1)
        #expect(childRows.count == uniqueChildRows.count)
        #expect(childTotals == [150, 15, 7])
        #expect(cache.codexScanCatchUpPending == false)
    }

    @Test
    func `grown same inode is not eligible for full rescan detail retention`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let events = [Self.tokenCount(timestamp: timestamp, input: 100)]
        let contents = Self.sessionPrefix(
            timestamp: timestamp,
            sessionID: "grown-source") + events
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "grown-source.jsonl",
            contents: env.jsonl(contents))
        let options = Self.options(env: env)
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let cache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let cached = try #require(cache.files.values.first { $0.sessionId == "grown-source" })
        let originalMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)

        try Self.append("{\"type\":\"response_item\",\"payload\":{\"text\":\"appended\"}}\n", to: fileURL)
        let grownMetadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        #expect(grownMetadata.fileId == originalMetadata.fileId)
        #expect(grownMetadata.size > originalMetadata.size)
        let input = CostUsageScanner.CodexFileScanInput(
            fileURL: fileURL,
            metadata: grownMetadata,
            cached: cached)
        #expect(!CostUsageScanner.codexCachedUsageBelongsToCurrentSource(cached, input: input))
    }

    @Test
    func `scheduler alternates dependency lanes and rotates foreground after cache reload`() throws {
        let foregroundA = URL(fileURLWithPath: "/synthetic/foreground-a.jsonl")
        let foregroundB = URL(fileURLWithPath: "/synthetic/foreground-b.jsonl")
        let childURL = URL(fileURLWithPath: "/synthetic/child.jsonl")
        let parentURL = URL(fileURLWithPath: "/synthetic/parent.jsonl")
        var cache = CostUsageCache()
        var parent = CostUsageFileUsage(mtimeUnixMs: 1, size: 100, days: [:])
        parent.sessionId = "parent"
        parent.parsedBytes = 0
        parent.codexScanComplete = false
        var child = CostUsageFileUsage(mtimeUnixMs: 1, size: 100, days: [:])
        child.sessionId = "child"
        child.forkedFromId = "parent"
        child.codexDeferredForkScan = true
        child.forkBaselineDependencyKey = nil
        cache.files[parentURL.path] = parent
        cache.files[childURL.path] = child
        let files = [foregroundA, foregroundB, childURL, parentURL]

        let first = CostUsageScanner.schedulingCodexForegroundBeforeDependencies(files, cache: &cache)
        #expect(first == [foregroundA, childURL, parentURL, foregroundB])
        #expect(cache.codexDependencyLaneStartsNext == true)
        #expect(cache.codexForegroundScheduleCursor == 1)

        let encoded = try JSONEncoder().encode(cache)
        var reloaded = try JSONDecoder().decode(CostUsageCache.self, from: encoded)
        let second = CostUsageScanner.schedulingCodexForegroundBeforeDependencies(files, cache: &reloaded)
        #expect(second == [childURL, foregroundB, foregroundA, parentURL])
        #expect(reloaded.codexDependencyLaneStartsNext == false)
        #expect(reloaded.codexForegroundScheduleCursor == 0)
    }

    private static func options(env: CostUsageTestEnvironment) -> CostUsageScanner.Options {
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: nil,
            cacheRoot: env.cacheRoot,
            codexTraceDatabaseURL: env.root.appendingPathComponent("missing.sqlite"),
            maxCodexSessionFileBytes: 0,
            maxCodexScanBytesPerRefresh: 0)
        options.refreshMinIntervalSeconds = 0
        return options
    }

    // swiftlint:disable:next function_body_length
    private static func assertTransientParentDeferralDeduplicatesSession(
        duplicateFirst: Bool,
        childProducesUsage: Bool = true) throws
    {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let parentTimestamp = env.isoString(for: day)
        let forkTimestamp = env.isoString(for: day.addingTimeInterval(2))
        let childTimestamp = env.isoString(for: day.addingTimeInterval(3))
        let parentSessionID = "dedupe-parent"
        let childSessionID = "dedupe-child"
        let parentURL = try env.writeCodexSessionFile(
            day: day,
            filename: "00-dedupe-parent.jsonl",
            contents: env.jsonl(
                Self.sessionPrefix(timestamp: parentTimestamp, sessionID: parentSessionID)
                    + [Self.tokenCount(
                        timestamp: parentTimestamp,
                        input: childProducesUsage ? 100 : 200)]))
        try FileManager.default.setAttributes(
            [.modificationDate: day],
            ofItemAtPath: parentURL.path)

        var options = Self.options(env: env)
        options.maxCodexSessionFileBytes = 1024
        options.maxCodexScanBytesPerRefresh = 64 * 1024 * 1024
        options.preferNewestCodexSessionsFirst = true
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        let padding = String(repeating: "x", count: 380)
        let tokenEvents = [Self.tokenCount(timestamp: forkTimestamp, input: 200)]
            + (0..<12).flatMap { index in
                [
                    [
                        "type": "response_item",
                        "payload": ["index": index, "text": padding],
                    ] as [String: Any],
                    Self.tokenCount(
                        timestamp: env.isoString(for: day.addingTimeInterval(Double(index + 3))),
                        input: childProducesUsage ? 201 + index : 200),
                ]
            }
        let childBody = try env.jsonl(
            Self.forkSessionPrefix(
                timestamp: childTimestamp,
                sessionID: childSessionID,
                parentSessionID: parentSessionID,
                forkTimestamp: forkTimestamp)
                + tokenEvents)
        let childURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-dedupe-child.jsonl",
            contents: childBody)
        let childMtime = day.addingTimeInterval(duplicateFirst ? 30 : 60)
        try FileManager.default.setAttributes(
            [.modificationDate: childMtime],
            ofItemAtPath: childURL.path)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        var before = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let parentEntry = try #require(before.files.first { $0.value.sessionId == parentSessionID })
        let childEntry = try #require(before.files.first { $0.value.sessionId == childSessionID })
        let beforeOffset = try #require(childEntry.value.parsedBytes)
        let beforeAnchor = try #require(childEntry.value.codexTokenIndexAnchor)
        let beforeSidecar = try #require(childEntry.value.codexTokenSidecarState)
        let beforeProcessedBytes = before.codexScanProcessedBytes ?? 0
        let beforeReference = try #require(CostUsageScanner.codexTokenIndexReference(
            fileURL: childURL,
            fileId: childEntry.value.codexScanFileId,
            anchor: beforeAnchor,
            state: beforeSidecar,
            isComplete: false))
        let beforeChildRows = try CodexPublishedUsageRowsTestSupport.load(
            path: childEntry.key,
            usage: childEntry.value,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        #expect(childEntry.value.codexScanComplete == false)
        #expect(childEntry.value.codexForkAccountingState != nil)
        #expect(childEntry.value.days.isEmpty == !childProducesUsage)
        #expect(beforeChildRows.isEmpty == !childProducesUsage)

        // An active/archive copy can have a different inode and omit fork metadata. Whether it is
        // visited before or after the validated fork, the fork-aware source remains authoritative.
        let duplicatePrefix = Self.sessionPrefix(timestamp: childTimestamp, sessionID: childSessionID)
        let duplicateBody = try env.jsonl(duplicatePrefix + tokenEvents)
        let duplicateURL = try env.writeCodexSessionFile(
            day: day,
            filename: "02-dedupe-copy.jsonl",
            contents: duplicateBody)
        let duplicateMtime = day.addingTimeInterval(duplicateFirst ? 60 : 30)
        try FileManager.default.setAttributes(
            [.modificationDate: duplicateMtime],
            ofItemAtPath: duplicateURL.path)
        #expect(CostUsageScanner.codexFileMetadata(fileURL: duplicateURL).fileId
            != CostUsageScanner.codexFileMetadata(fileURL: childURL).fileId)
        let duplicateFileID = try #require(CostUsageScanner.codexFileMetadata(fileURL: duplicateURL).fileId)

        var incompleteParent = parentEntry.value
        incompleteParent.codexScanComplete = false
        before.files[parentEntry.key] = incompleteParent
        before.codexSessionDiscovery = nil
        before.codexScanCatchUpPending = true
        before.lastScanUnixMs = 0
        CostUsageCacheIO.save(provider: .codex, cache: before, cacheRoot: env.cacheRoot)

        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        let after = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let childEntries = after.files.filter { $0.value.sessionId == childSessionID }
        let childUsages = childEntries.map(\.value)
        let childRows = try childEntries.flatMap {
            try CodexPublishedUsageRowsTestSupport.load(
                path: $0.key,
                usage: $0.value,
                cacheRoot: env.cacheRoot,
                calendar: options.calendar)
        }
        let uniqueChildRowKeys = Set(childRows.map {
            CostUsageScanner.codexUsageRowKey(
                sessionId: childSessionID,
                row: $0)
        })
        let preserved = try #require(after.files[childEntry.key])
        let preservedRows = try CodexPublishedUsageRowsTestSupport.load(
            path: childEntry.key,
            usage: preserved,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        #expect(childRows.count == uniqueChildRowKeys.count)
        #expect(childUsages.count(where: { !$0.days.isEmpty }) == (childProducesUsage ? 1 : 0))
        #expect(preserved.parsedBytes == beforeOffset)
        #expect(preserved.codexTokenIndexAnchor == beforeAnchor)
        #expect(preserved.codexTokenSidecarState == beforeSidecar)
        #expect(preserved.codexForkAccountingState == childEntry.value.codexForkAccountingState)
        #expect(preserved.days == childEntry.value.days)
        #expect(preservedRows == beforeChildRows)
        let duplicateEntry = try #require(after.files.first { $0.value.codexScanFileId == duplicateFileID })
        let duplicate = duplicateEntry.value
        let duplicateRows = try CodexPublishedUsageRowsTestSupport.load(
            path: duplicateEntry.key,
            usage: duplicate,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        #expect(duplicate.days.isEmpty)
        #expect(duplicateRows.isEmpty)
        #expect(duplicate.codexTokenIndexAnchor != nil)
        #expect(duplicate.codexTokenSidecarState != nil)
        #expect(after.days == before.days)
        #expect(after.codexScanCatchUpPending == true)
        #expect((after.codexScanProcessedBytes ?? 0) >= beforeProcessedBytes)
        #expect(CostUsageCodexTokenIndexStore(cacheRoot: env.cacheRoot).contains(beforeReference))

        var stableOptions = options
        stableOptions.maxCodexSessionFileBytes = 0
        stableOptions.maxCodexScanBytesPerRefresh = 0
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: stableOptions)
        let stableCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let stableUsages = stableCache.files.values.filter { $0.sessionId == childSessionID }
        let stablePreserved = try #require(stableCache.files[childEntry.key])
        #expect(stableUsages.count(where: { !$0.days.isEmpty }) == (childProducesUsage ? 1 : 0))
        #expect(stablePreserved.codexScanComplete == true)
        #expect(stablePreserved.codexTokenIndexAnchor?.indexedBytes == stablePreserved.parsedBytes)
        let stableDuplicateEntry = try #require(stableCache.files.first {
            $0.value.codexScanFileId == duplicateFileID
        })
        let stableDuplicate = stableDuplicateEntry.value
        let stableDuplicateRows = try CodexPublishedUsageRowsTestSupport.load(
            path: stableDuplicateEntry.key,
            usage: stableDuplicate,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar)
        #expect(stableDuplicate.days.isEmpty)
        #expect(stableDuplicateRows.isEmpty)
        #expect(stableDuplicate.codexTokenIndexAnchor != nil)
        #expect(stableDuplicate.codexTokenSidecarState != nil)

        var controlOptions = stableOptions
        controlOptions.cacheRoot = env.root.appendingPathComponent(
            "dedupe-control-\(duplicateFirst)-\(childProducesUsage)",
            isDirectory: true)
        let control = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(3),
            options: controlOptions)
        #expect(stable.data == control.data)
        #expect(stable.summary == control.summary)

        if !childProducesUsage {
            let stableDuplicate = try #require(stableCache.files.values.first {
                $0.codexScanFileId == duplicateFileID
            })
            let beforeDuplicateAppendOffset = stableDuplicate.parsedBytes ?? 0
            try Self.append(
                env.jsonl([Self.tokenCount(
                    timestamp: env.isoString(for: day.addingTimeInterval(4)),
                    input: 400)]),
                to: duplicateURL)
            let afterAppend = CostUsageScanner.loadDailyReport(
                provider: .codex,
                since: day,
                until: day,
                now: day.addingTimeInterval(4),
                options: stableOptions)
            let afterAppendCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
            let appendedDuplicateEntry = try #require(afterAppendCache.files.first {
                $0.value.codexScanFileId == duplicateFileID
            })
            let appendedDuplicate = appendedDuplicateEntry.value
            let appendedDuplicateRows = try CodexPublishedUsageRowsTestSupport.load(
                path: appendedDuplicateEntry.key,
                usage: appendedDuplicate,
                cacheRoot: env.cacheRoot,
                calendar: options.calendar)
            #expect((appendedDuplicate.parsedBytes ?? 0) > beforeDuplicateAppendOffset)
            #expect(appendedDuplicate.days.isEmpty)
            #expect(appendedDuplicateRows.isEmpty)
            #expect(afterAppend.data == stable.data)
            #expect(afterAppend.summary == stable.summary)
        }
    }

    private static func assertMissingParentMarkerOwnsSession(duplicateFirst: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 5, day: 10)
        let timestamp = env.isoString(for: day)
        let childSessionID = "missing-marker-child"
        let forkBody = try env.jsonl(
            Self.forkSessionPrefix(
                timestamp: timestamp,
                sessionID: childSessionID,
                parentSessionID: "absent-parent",
                forkTimestamp: timestamp)
                + [Self.tokenCount(timestamp: timestamp, input: 200)])
        let forkURL = try env.writeCodexSessionFile(
            day: day,
            filename: "01-missing-marker-fork.jsonl",
            contents: forkBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(duplicateFirst ? 30 : 60)],
            ofItemAtPath: forkURL.path)

        let duplicateBody = try env.jsonl(
            Self.sessionPrefix(timestamp: timestamp, sessionID: childSessionID)
                + [Self.tokenCount(timestamp: timestamp, input: 200)])
        let duplicateURL = try env.writeCodexSessionFile(
            day: day,
            filename: "02-missing-marker-copy.jsonl",
            contents: duplicateBody)
        try FileManager.default.setAttributes(
            [.modificationDate: day.addingTimeInterval(duplicateFirst ? 60 : 30)],
            ofItemAtPath: duplicateURL.path)
        let duplicateFileID = try #require(CostUsageScanner.codexFileMetadata(fileURL: duplicateURL).fileId)

        var options = Self.options(env: env)
        options.preferNewestCodexSessionsFirst = true
        let first = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let firstCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let marker = try #require(firstCache.files.values.first {
            $0.sessionId == childSessionID && $0.forkedFromId == "absent-parent"
        })
        #expect(marker.codexDeferredForkScan == true)
        #expect(marker.forkBaselineDependencyKey?.hasPrefix("missing|") == true)
        #expect(marker.days.isEmpty)
        let duplicate = try #require(firstCache.files.values.first {
            $0.codexScanFileId == duplicateFileID
        })
        #expect(duplicate.days.isEmpty)
        #expect(duplicate.codexRows?.isEmpty != false)
        #expect(firstCache.days.isEmpty)
        #expect(first.data.isEmpty)

        let warm = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        let warmCache = CostUsageCacheIO.load(provider: .codex, cacheRoot: env.cacheRoot)
        let warmMarker = try #require(warmCache.files.values.first {
            $0.sessionId == childSessionID && $0.forkedFromId == "absent-parent"
        })
        #expect(warmMarker.codexDeferredForkScan == true)
        #expect(warmMarker.days.isEmpty)
        let warmDuplicate = try #require(warmCache.files.values.first {
            $0.codexScanFileId == duplicateFileID
        })
        #expect(warmDuplicate.days.isEmpty)
        #expect(warmCache.days.isEmpty)
        #expect(warm.data.isEmpty)
        #expect(warmCache.codexScanCatchUpPending == false)
    }

    private static func sessionMetadataLine(timestamp: String, sessionID: String) -> String {
        #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"session_id":"\#(sessionID)"}}"#
            + "\n"
    }

    private static func sessionPrefix(timestamp: String, sessionID: String) -> [[String: Any]] {
        [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": ["session_id": sessionID],
            ],
            [
                "type": "turn_context",
                "timestamp": timestamp,
                "payload": ["model": "openai/gpt-5.4"],
            ],
        ]
    }

    private static func forkSessionPrefix(
        timestamp: String,
        sessionID: String,
        parentSessionID: String,
        forkTimestamp: String) -> [[String: Any]]
    {
        [
            [
                "type": "session_meta",
                "timestamp": timestamp,
                "payload": [
                    "session_id": sessionID,
                    "forked_from_id": parentSessionID,
                    "timestamp": forkTimestamp,
                ],
            ],
            self.turnContext(timestamp: timestamp, cwd: nil, title: nil),
        ]
    }

    private static func sessionMetadata(
        timestamp: String,
        sessionID: String,
        cwd: String) -> [String: Any]
    {
        [
            "type": "session_meta",
            "timestamp": timestamp,
            "payload": ["session_id": sessionID, "cwd": cwd],
        ]
    }

    private static func turnContext(
        timestamp: String,
        cwd: String?,
        title: String?) -> [String: Any]
    {
        var payload: [String: Any] = ["model": "openai/gpt-5.4"]
        if let cwd { payload["cwd"] = cwd }
        if let title { payload["title"] = title }
        return [
            "type": "turn_context",
            "timestamp": timestamp,
            "payload": payload,
        ]
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

    private static func modificationDate(_ fileURL: URL) throws -> Date {
        let attributes = try FileManager.default.attributesOfItem(atPath: fileURL.path)
        return try #require(attributes[.modificationDate] as? Date)
    }

    private static func append(_ contents: String, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
