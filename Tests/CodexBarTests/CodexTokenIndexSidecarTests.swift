import Foundation
import Testing

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@testable import CodexBarCore

@Suite(.serialized)
// Keep the serialized SQLite protocol matrix together so commit hooks cannot overlap.
// swiftlint:disable:next type_body_length
struct CodexTokenIndexSidecarTests {
    @Test
    func `all compatible pre EOF producers revalidate published fork children`() {
        let expectedProducerKeys = Set([
            "codex:cu:p1cd29792d9ca2b11",
            "codex:cu:p37aedd661c4272a8",
            "codex:cu:p6c0f1fa950e63467",
            "codex:cu:p843ca061c36bbea1",
            "codex:cu:p89e80f722cad05c8",
            "codex:cu:paa27d287348e79b5",
        ])
        #expect(CostUsageScanner.codexPreEOFBaselineProducerKeys == expectedProducerKeys)

        for producerKey in expectedProducerKeys {
            let childDays = ["2026-01-01": ["openai/gpt-5.4": [50, 5, 3]]]
            var cache = CostUsageCache()
            cache.producerKey = producerKey
            cache.days = childDays
            cache.files["/redacted-parent.jsonl"] = CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: 1024,
                days: [:],
                parsedBytes: 512,
                sessionId: "redacted-parent",
                codexScanFileId: "redacted-parent-file-id",
                codexScanTargetSize: 1024,
                codexScanComplete: false)
            cache.files["/redacted-child.jsonl"] = CostUsageScanner.makeFileUsage(
                mtimeUnixMs: 1,
                size: 512,
                days: childDays,
                parsedBytes: 512,
                sessionId: "redacted-child",
                forkedFromId: "redacted-parent",
                codexForkTimestamp: "2026-01-01T00:00:00Z",
                forkBaselineDependencyKey: "file|redacted-parent|published-too-early",
                codexScanFileId: "redacted-child-file-id",
                codexScanTargetSize: 512,
                codexScanComplete: true)

            #expect(CostUsageScanner.revalidatePreEOFCodexForkBaselines(cache: &cache))
            let child = cache.files["/redacted-child.jsonl"]
            #expect(cache.days.isEmpty)
            #expect(child?.days.isEmpty == true)
            #expect(child?.parsedBytes == 0)
            #expect(child?.forkBaselineDependencyKey == nil)
            #expect(child?.codexScanComplete == false)
            #expect(child?.codexDeferredForkScan == true)
            #expect(cache.codexScanCatchUpPending == true)
            #expect(cache.lastScanUnixMs == 0)
        }
    }

    @Test
    func `replace survives reopen and cutoff uses the last matching event in file order`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 1024)
        defer { fixture.cleanup() }

        let t0 = "2026-01-01T00:00:00Z"
        let t1 = "2026-01-01T00:00:01Z"
        let t2 = "2026-01-01T00:00:02Z"
        let t3 = "2026-01-01T00:00:03Z"
        let malformedBetweenT0AndT1 = "2026-01-01T00:00:00~invalid"
        #expect(CostUsageScanner.dateFromTimestamp(malformedBetweenT0AndT1) == nil)
        let events = [
            Self.event(timestamp: t0, input: 100, endOffset: 128),
            Self.event(timestamp: t2, input: 200, endOffset: 256),
            Self.event(timestamp: t1, input: 250, endOffset: 384),
            Self.event(timestamp: t1, input: 275, endOffset: 512),
            Self.event(timestamp: malformedBetweenT0AndT1, input: 290, endOffset: 640),
            Self.event(timestamp: t3, input: 300, endOffset: 768),
        ]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 1024,
            eventCount: events.count,
            isComplete: true)

        try fixture.store.replace(reference: reference, records: folded.records)

        let reopened = CostUsageCodexTokenIndexStore(cacheRoot: fixture.cacheRoot)
        #expect(reopened.contains(reference))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: reference,
            cutoff: t1) == Self.totals(290))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: reference,
            cutoff: t0) == Self.totals(100))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: reference,
            cutoff: t3) == Self.totals(300))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: reference,
            cutoff: "2025-12-31T23:59:59Z") == nil)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `append persists only the suffix and retry is idempotent`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }

        let prefixEvents = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 128),
            Self.event(timestamp: "2026-01-01T00:00:01Z", input: 200, endOffset: 384),
        ]
        let prefix = try Self.fold(prefixEvents)
        let expected = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: prefixEvents.count,
            isComplete: true)
        try fixture.store.replace(reference: expected, records: prefix.records)

        try Self.appendBytes(count: 512, to: fixture.fileURL)
        let suffixEvents = [
            Self.event(timestamp: "2026-01-01T00:00:02Z", input: 300, endOffset: 640),
            Self.event(timestamp: "2026-01-01T00:00:03Z", input: 400, endOffset: 896),
        ]
        let suffix = try Self.fold(suffixEvents, initialState: prefix.terminalState)
        let updated = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 1024,
            eventCount: prefixEvents.count + suffixEvents.count,
            isComplete: true)

        try fixture.store.append(expected: expected, updated: updated, records: suffix.records)
        let reopened = CostUsageCodexTokenIndexStore(cacheRoot: fixture.cacheRoot)
        try reopened.append(expected: expected, updated: updated, records: suffix.records)

        #expect(reopened.contains(updated))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: updated,
            cutoff: "2026-01-01T00:00:01Z") == Self.totals(200))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: updated,
            cutoff: "2026-01-01T00:00:03Z") == Self.totals(400))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `append advances indexed bytes when the suffix has no token events`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }

        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        let expected = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.replace(reference: expected, records: folded.records)

        try Self.appendBytes(count: 512, to: fixture.fileURL)
        let updated = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 1024,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.append(expected: expected, updated: updated, records: [])

        let reopened = CostUsageCodexTokenIndexStore(cacheRoot: fixture.cacheRoot)
        #expect(reopened.contains(updated))
        #expect(!reopened.contains(expected))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: updated,
            cutoff: "2026-01-01T00:00:00Z") == Self.totals(100))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `SQLite ahead of the JSON cursor rewinds and replays the authoritative suffix`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 1536)
        defer { fixture.cleanup() }

        let prefixEvents = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 128),
            Self.event(timestamp: "2026-01-01T00:00:01Z", input: 200, endOffset: 384),
        ]
        let prefix = try Self.fold(prefixEvents)
        let published = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: prefixEvents.count,
            isComplete: false)
        try fixture.store.replace(reference: published, records: prefix.records)

        // Simulate a SQLite transaction that committed before its matching JSON cursor was saved.
        let unpublishedEvents = [
            Self.event(timestamp: "2026-01-01T00:00:02Z", input: 900, endOffset: 768),
        ]
        let unpublished = try Self.fold(
            unpublishedEvents,
            initialState: prefix.terminalState)
        let ahead = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 1024,
            eventCount: prefixEvents.count + unpublishedEvents.count,
            isComplete: false)
        try fixture.store.append(
            expected: published,
            updated: ahead,
            records: unpublished.records)

        // The next refresh still starts at the published JSON cursor. Its complete delta replaces
        // every unpublished row before appending the newly observed event. The replacement is
        // deliberately out of timestamp order so rewind also restores monotonicity metadata.
        let authoritativeEvents = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 300, endOffset: 768),
            Self.event(timestamp: "2026-01-01T00:00:03Z", input: 400, endOffset: 1280),
        ]
        let authoritative = try Self.fold(
            authoritativeEvents,
            initialState: prefix.terminalState)
        let completed = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 1536,
            eventCount: prefixEvents.count + authoritativeEvents.count,
            isComplete: true)
        try fixture.store.append(
            expected: published,
            updated: completed,
            records: authoritative.records)

        let reopened = CostUsageCodexTokenIndexStore(cacheRoot: fixture.cacheRoot)
        #expect(reopened.contains(completed))
        #expect(!reopened.contains(ahead))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: completed,
            cutoff: "2026-01-01T00:00:01Z") == Self.totals(300))
        #expect(try Self.readyTotals(
            store: reopened,
            reference: completed,
            cutoff: "2026-01-01T00:00:03Z") == Self.totals(400))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `lookup requires the exact stored reference to be complete`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }

        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        let incomplete = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: false)
        let complete = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.replace(reference: incomplete, records: folded.records)

        #expect(try Self.needsRebuild(fixture.store.inheritedTotals(
            reference: incomplete,
            cutoffTimestamp: "2026-01-01T00:00:00Z",
            cutoffUnixSeconds: Self.unixSeconds("2026-01-01T00:00:00Z"))))
        #expect(try Self.needsRebuild(fixture.store.inheritedTotals(
            reference: complete,
            cutoffTimestamp: "2026-01-01T00:00:00Z",
            cutoffUnixSeconds: Self.unixSeconds("2026-01-01T00:00:00Z"))))

        try fixture.store.append(expected: incomplete, updated: complete, records: [])
        #expect(try Self.readyTotals(
            store: fixture.store,
            reference: complete,
            cutoff: "2026-01-01T00:00:00Z") == Self.totals(100))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `complete commit raced by append is retryable and never serves a parent baseline`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }
        let cutoff = "2026-01-01T00:00:00Z"
        let events = [Self.event(timestamp: cutoff, input: 100, endOffset: 384)]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)

        do {
            _ = try CostUsageCodexTokenIndexStore.withAfterCommitHookForTesting { observedURL in
                guard observedURL.standardizedFileURL == fixture.fileURL.standardizedFileURL else { return }
                try? Self.appendBytes(count: 512, to: fixture.fileURL)
            } operation: {
                try fixture.store.replace(reference: reference, records: folded.records)
            }
            Issue.record("expected source growth after commit to defer publication")
        } catch {
            #expect(error as? CostUsageCodexTokenIndexStore.StoreError == .sourceAdvanced)
            #expect(CostUsageCodexTokenIndexStore.failureDisposition(for: error) == .retryLater)
        }

        #expect(fixture.store.contains(reference))
        #expect(try Self.temporarilyUnavailable(fixture.store.inheritedTotals(
            reference: reference,
            cutoffTimestamp: cutoff,
            cutoffUnixSeconds: Self.unixSeconds(cutoff))))

        do {
            try fixture.store.replace(reference: reference, records: folded.records)
            Issue.record("expected a complete preflight against a grown source to retry")
        } catch {
            #expect(error as? CostUsageCodexTokenIndexStore.StoreError == .sourceAdvanced)
            #expect(CostUsageCodexTokenIndexStore.failureDisposition(for: error) == .retryLater)
        }
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `incomplete commit remains valid while its source appends`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 1024)
        defer { fixture.cleanup() }
        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: false)

        let committed = try CostUsageCodexTokenIndexStore.withAfterCommitHookForTesting { observedURL in
            guard observedURL.standardizedFileURL == fixture.fileURL.standardizedFileURL else { return }
            try? Self.appendBytes(count: 512, to: fixture.fileURL)
        } operation: {
            try fixture.store.replace(reference: reference, records: folded.records)
        }

        #expect(committed == reference)
        #expect(fixture.store.contains(reference))
        #expect(try Self.needsRebuild(fixture.store.inheritedTotals(
            reference: reference,
            cutoffTimestamp: events[0].timestamp,
            cutoffUnixSeconds: Self.unixSeconds(events[0].timestamp))))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `cache save retains aliases and never deletes unpublished sidecars`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }

        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        #if os(macOS)
        let privateVarRoot = URL(fileURLWithPath: "/var/tmp", isDirectory: true)
            .appendingPathComponent(
                "CodexTokenIndexSidecarTests-\(UUID().uuidString)",
                isDirectory: true)
        try FileManager.default.createDirectory(
            at: privateVarRoot,
            withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: privateVarRoot) }
        let varAliasURL = privateVarRoot
            .appendingPathComponent("redacted-private-var-parent.jsonl", isDirectory: false)
        try Data(repeating: 0x61, count: 512).write(to: varAliasURL)
        let privateVarAliasURL = URL(fileURLWithPath: "/private\(varAliasURL.path)")
        let privateVarReference = try Self.canonicalReference(
            fileURL: varAliasURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        let privateVarUsage = Self.sidecarUsage(
            fileURL: varAliasURL,
            reference: privateVarReference,
            state: folded.terminalState)
        #expect(varAliasURL.path.hasPrefix("/var/"))
        #expect(privateVarAliasURL.path.hasPrefix("/private/var/"))
        #expect(varAliasURL.path != privateVarAliasURL.path)
        #expect(CostUsageCodexTokenIndexStore.sourcePath(for: privateVarAliasURL)
            == CostUsageCodexTokenIndexStore.sourcePath(for: varAliasURL))

        try fixture.store.replace(
            reference: privateVarReference,
            records: folded.records)
        var cache = CostUsageCache()
        cache.files[privateVarAliasURL.path] = privateVarUsage
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: fixture.cacheRoot)
        #expect(fixture.store.contains(privateVarReference))

        cache.files.removeAll()
        CostUsageCacheIO.save(provider: .codex, cache: cache, cacheRoot: fixture.cacheRoot)
        // A concurrent writer may have committed this row before publishing its JSON cursor.
        #expect(fixture.store.contains(privateVarReference))
        #endif

        let reference = try Self.canonicalReference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        let usage = Self.sidecarUsage(
            fileURL: fixture.fileURL,
            reference: reference,
            state: folded.terminalState)

        let symlinkURL = fixture.cacheRoot
            .appendingPathComponent("redacted-parent-alias.jsonl", isDirectory: false)
        try FileManager.default.createSymbolicLink(
            at: symlinkURL,
            withDestinationURL: fixture.fileURL)
        #expect(CostUsageCodexTokenIndexStore.sourcePath(for: symlinkURL) == reference.path)

        try fixture.store.replace(reference: reference, records: folded.records)
        var aliasCache = CostUsageCache()
        aliasCache.files[symlinkURL.path] = usage
        CostUsageCacheIO.save(provider: .codex, cache: aliasCache, cacheRoot: fixture.cacheRoot)
        #expect(fixture.store.contains(reference))

        aliasCache.files.removeAll()
        CostUsageCacheIO.save(provider: .codex, cache: aliasCache, cacheRoot: fixture.cacheRoot)
        #expect(fixture.store.contains(reference))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `future SQLite schema requests a rebuild`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }

        let cutoff = "2026-01-01T00:00:00Z"
        let events = [
            Self.event(timestamp: cutoff, input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.replace(reference: reference, records: folded.records)
        #expect(fixture.store.contains(reference))

        try Self.advanceSQLiteUserVersion(at: fixture.store.databaseURL())

        #expect(!fixture.store.contains(reference))
        #expect(try Self.needsRebuild(fixture.store.inheritedTotals(
            reference: reference,
            cutoffTimestamp: cutoff,
            cutoffUnixSeconds: Self.unixSeconds(cutoff))))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `empty and corrupt SQLite sidecars request a rebuild`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }
        let cutoff = "2026-01-01T00:00:00Z"
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: 1,
            isComplete: true)
        let databaseURL = fixture.store.databaseURL()
        try FileManager.default.createDirectory(
            at: databaseURL.deletingLastPathComponent(),
            withIntermediateDirectories: true)

        try Data().write(to: databaseURL)
        #expect(try Self.needsRebuild(fixture.store.inheritedTotals(
            reference: reference,
            cutoffTimestamp: cutoff,
            cutoffUnixSeconds: Self.unixSeconds(cutoff))))

        try FileManager.default.removeItem(at: databaseURL)
        try Data("redacted-not-a-sqlite-database".utf8).write(to: databaseURL)
        #expect(try Self.needsRebuild(fixture.store.inheritedTotals(
            reference: reference,
            cutoffTimestamp: cutoff,
            cutoffUnixSeconds: Self.unixSeconds(cutoff))))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `SQLite result codes retain rebuild versus retry semantics`() {
        #if canImport(SQLite3) || canImport(CSQLite3)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.sqlite(code: SQLITE_BUSY)) == .retryLater)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.sqlite(code: SQLITE_LOCKED)) == .retryLater)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.sqlite(code: SQLITE_IOERR)) == .retryLater)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.sqlite(code: SQLITE_CORRUPT)) == .needsRebuild)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.sqlite(code: SQLITE_NOTADB)) == .needsRebuild)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.incompatibleSchema(version: 999))
            == .needsRebuild)
        #expect(CostUsageCodexTokenIndexStore.failureDisposition(
            for: CostUsageCodexTokenIndexStore.StoreError.sourceAdvanced) == .retryLater)
        #expect(!CostUsageCodexTokenIndexStore().resetDatabaseAfterStructuralFailure(
            CostUsageCodexTokenIndexStore.StoreError.incompatibleSchema(version: 999)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `structural SQLite code survives transaction rollback`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }
        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.replace(reference: reference, records: folded.records)
        try Self.dropEventsTable(at: fixture.store.databaseURL())

        do {
            try fixture.store.replace(reference: reference, records: folded.records)
            Issue.record("expected the structurally invalid sidecar to fail")
        } catch {
            #expect(CostUsageCodexTokenIndexStore.failureDisposition(for: error) == .needsRebuild)
            guard let storeError = error as? CostUsageCodexTokenIndexStore.StoreError,
                  case let .sqlite(code) = storeError
            else {
                Issue.record("expected a captured SQLite result code")
                return
            }
            #expect(code & 0xFF == SQLITE_ERROR)
        }
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `full replacement recreates a structurally invalid current sidecar`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 512)
        defer { fixture.cleanup() }
        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 384),
        ]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 512,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.replace(reference: reference, records: folded.records)
        try Self.dropEventsTable(at: fixture.store.databaseURL())

        let rebuilt = CostUsageScanner.replacingCodexTokenIndex(
            events: events,
            nextUsageRowIndex: events.count,
            fileURL: fixture.fileURL,
            fileId: reference.fileId,
            indexedBytes: reference.indexedBytes,
            isComplete: true,
            store: fixture.store)
        let rebuiltReference = try #require(CostUsageScanner.codexTokenIndexReference(
            fileURL: fixture.fileURL,
            fileId: reference.fileId,
            anchor: rebuilt.anchor,
            state: rebuilt.sidecarState,
            isComplete: true))

        #expect(rebuilt.snapshots == nil)
        #expect(rebuilt.sidecarState?.eventCount == events.count)
        #expect(fixture.store.contains(rebuiltReference))
        #expect(try Self.readyTotals(
            store: fixture.store,
            reference: rebuiltReference,
            cutoff: events[0].timestamp) == Self.totals(100))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `monotonic cutoff uses the timestamp index without a sort`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture(fileBytes: 1024)
        defer { fixture.cleanup() }
        let events = [
            Self.event(timestamp: "2026-01-01T00:00:00Z", input: 100, endOffset: 128),
            Self.event(timestamp: "2026-01-01T00:00:01Z", input: 200, endOffset: 256),
            Self.event(timestamp: "2026-01-01T00:00:02Z", input: 300, endOffset: 384),
            Self.event(timestamp: "2026-01-01T00:00:03Z", input: 400, endOffset: 512),
        ]
        let folded = try Self.fold(events)
        let reference = try Self.reference(
            fileURL: fixture.fileURL,
            indexedBytes: 1024,
            eventCount: events.count,
            isComplete: true)
        try fixture.store.replace(reference: reference, records: folded.records)

        #expect(try Self.readyTotals(
            store: fixture.store,
            reference: reference,
            cutoff: "2026-01-01T00:00:01Z") == Self.totals(200))

        let plan = try Self.queryPlan(
            databaseURL: fixture.store.databaseURL(),
            sql: CostUsageCodexTokenIndexStore.monotonicNumericCandidateSQL)
        #expect(plan.contains(where: { $0.contains("events_numeric_timestamp") }))
        #expect(!plan.contains(where: { $0.contains("USE TEMP B-TREE") }))
        #else
        #expect(Bool(true))
        #endif
    }

    private struct Fixture {
        let cacheRoot: URL
        let fileURL: URL
        let store: CostUsageCodexTokenIndexStore

        func cleanup() {
            try? FileManager.default.removeItem(at: self.cacheRoot)
        }
    }

    private static func makeFixture(fileBytes: Int) throws -> Fixture {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexTokenIndexSidecarTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let fileURL = cacheRoot.appendingPathComponent("redacted-parent.jsonl", isDirectory: false)
        try Data(repeating: 0x61, count: fileBytes).write(to: fileURL)
        return Fixture(
            cacheRoot: cacheRoot,
            fileURL: fileURL,
            store: CostUsageCodexTokenIndexStore(cacheRoot: cacheRoot))
    }

    private static func appendBytes(count: Int, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(repeating: 0x62, count: count))
    }

    private static func reference(
        fileURL: URL,
        indexedBytes: Int64,
        eventCount: Int,
        isComplete: Bool) throws -> CostUsageCodexTokenIndexReference
    {
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        let fileId = try #require(metadata.fileId)
        let anchor = try #require(CostUsageScanner.codexTokenIndexAnchor(
            fileURL: fileURL,
            indexedBytes: indexedBytes))
        return CostUsageCodexTokenIndexReference(
            path: fileURL.path,
            fileId: fileId,
            indexedBytes: indexedBytes,
            eventCount: eventCount,
            anchor: anchor,
            isComplete: isComplete)
    }

    private static func canonicalReference(
        fileURL: URL,
        indexedBytes: Int64,
        eventCount: Int,
        isComplete: Bool) throws -> CostUsageCodexTokenIndexReference
    {
        let reference = try Self.reference(
            fileURL: fileURL,
            indexedBytes: indexedBytes,
            eventCount: eventCount,
            isComplete: isComplete)
        return CostUsageCodexTokenIndexReference(
            path: CostUsageCodexTokenIndexStore.sourcePath(for: fileURL),
            fileId: reference.fileId,
            indexedBytes: reference.indexedBytes,
            eventCount: reference.eventCount,
            anchor: reference.anchor,
            isComplete: reference.isComplete)
    }

    private static func sidecarUsage(
        fileURL: URL,
        reference: CostUsageCodexTokenIndexReference,
        state: CostUsageCodexTokenAccumulatorState) -> CostUsageFileUsage
    {
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        return CostUsageScanner.makeFileUsage(
            mtimeUnixMs: metadata.mtimeUnixMs,
            size: metadata.size,
            days: [:],
            parsedBytes: reference.indexedBytes,
            codexTokenIndexAnchor: reference.anchor,
            codexTokenSidecarState: CostUsageCodexTokenSidecarState(
                eventCount: reference.eventCount,
                accumulatorState: state),
            codexScanFileId: reference.fileId,
            codexScanTargetSize: metadata.size,
            codexScanComplete: reference.isComplete)
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func dropEventsTable(at databaseURL: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "DROP TABLE events", nil, nil, nil) == SQLITE_OK)
    }

    private static func queryPlan(databaseURL: URL, sql: String) throws -> [String] {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer { sqlite3_close(db) }

        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            db,
            "EXPLAIN QUERY PLAN \(sql)",
            -1,
            &statement,
            nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }

        var result: [String] = []
        var stepResult = sqlite3_step(statement)
        while stepResult == SQLITE_ROW {
            if let detail = sqlite3_column_text(statement, 3) {
                result.append(String(cString: detail))
            }
            stepResult = sqlite3_step(statement)
        }
        try #require(stepResult == SQLITE_DONE)
        return result
    }

    private static func advanceSQLiteUserVersion(at databaseURL: URL) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer { sqlite3_close(db) }

        let currentVersion: Int32 = try {
            var statement: OpaquePointer?
            try #require(sqlite3_prepare_v2(
                db,
                "PRAGMA user_version",
                -1,
                &statement,
                nil) == SQLITE_OK)
            defer { sqlite3_finalize(statement) }
            try #require(sqlite3_step(statement) == SQLITE_ROW)
            return sqlite3_column_int(statement, 0)
        }()
        let futureVersion = currentVersion + 1
        #expect(futureVersion > currentVersion)
        try #require(sqlite3_exec(
            db,
            "PRAGMA user_version = \(futureVersion)",
            nil,
            nil,
            nil) == SQLITE_OK)
    }
    #endif

    private static func fold(
        _ events: [CostUsageCodexTokenSnapshot],
        initialState: CostUsageCodexTokenAccumulatorState? = nil) throws
        -> (records: [CostUsageCodexTokenIndexRecord], terminalState: CostUsageCodexTokenAccumulatorState)
    {
        try #require(CostUsageScanner.codexTokenIndexRecords(
            events: events,
            initialState: initialState))
    }

    private static func event(
        timestamp: String,
        input: Int,
        endOffset: Int64) -> CostUsageCodexTokenSnapshot
    {
        CostUsageCodexTokenSnapshot(
            timestamp: timestamp,
            last: nil,
            total: self.totals(input),
            endOffset: endOffset)
    }

    private static func totals(_ input: Int) -> CostUsageCodexTotals {
        CostUsageCodexTotals(
            input: input,
            cached: input / 10,
            output: input / 20)
    }

    private static func unixSeconds(_ timestamp: String) throws -> Double {
        try #require(CostUsageScanner.dateFromTimestamp(timestamp)).timeIntervalSince1970
    }

    private static func readyTotals(
        store: CostUsageCodexTokenIndexStore,
        reference: CostUsageCodexTokenIndexReference,
        cutoff: String) throws -> CostUsageCodexTotals?
    {
        switch try store.inheritedTotals(
            reference: reference,
            cutoffTimestamp: cutoff,
            cutoffUnixSeconds: self.unixSeconds(cutoff))
        {
        case let .ready(totals):
            return totals
        case .needsRebuild, .temporarilyUnavailable:
            Issue.record("expected a ready token-index lookup")
            return nil
        }
    }

    private static func needsRebuild(_ lookup: CostUsageCodexTokenIndexLookup) -> Bool {
        if case .needsRebuild = lookup {
            return true
        }
        return false
    }

    private static func temporarilyUnavailable(_ lookup: CostUsageCodexTokenIndexLookup) -> Bool {
        if case .temporarilyUnavailable = lookup {
            return true
        }
        return false
    }
}
