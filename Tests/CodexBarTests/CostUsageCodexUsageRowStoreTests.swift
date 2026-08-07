import Foundation
import Testing

#if canImport(SQLite3)
import SQLite3
#elseif canImport(CSQLite3)
import CSQLite3
#endif

@testable import CodexBarCore

@Suite(.serialized)
// swiftlint:disable:next type_body_length
struct CostUsageCodexUsageRowStoreTests {
    @Test
    func `create and load round trips complete audit rows`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(fileURL: fixture.fileURL, indexedBytes: 1024)
        let records = [
            Self.record(
                eventIndex: 0,
                input: 100,
                turnID: "redacted-turn-a",
                knownCostNanos: 125_000,
                unpricedTokens: 7,
                pricingModel: "openai/gpt-redacted",
                pricingMode: "priority"),
            Self.record(eventIndex: 2, input: 200, turnID: "redacted-turn-b"),
        ]

        let reference = try fixture.store.createGeneration(
            source: source,
            records: records,
            nextUsageRowIndex: 3,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            ownershipKey: "owner-v1",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-create-load")

        let loaded = try Self.readyRows(store: fixture.store, reference: reference)
        let first = try #require(loaded.first)
        #expect(loaded == records)
        #expect(first.usageRow.knownCostNanos == 125_000)
        #expect(first.usageRow.unpricedTokens == 7)
        #expect(first.usageRow.pricingModel == "openai/gpt-redacted")
        #expect(first.usageRow.pricingMode == "priority")
        #expect(reference.state.pricingKey == "pricing-v1")
        #expect(reference.state.priorityMetadataKey == "priority-v1")

        let idempotent = try fixture.store.createGeneration(
            source: source,
            records: records,
            nextUsageRowIndex: 3,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            ownershipKey: "owner-v1",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-create-load")
        #expect(idempotent == reference)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `append writes only the suffix and retry is idempotent`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let prefix = [Self.record(eventIndex: 0, input: 100, turnID: "prefix-turn")]
        let published = try fixture.store.createGeneration(
            source: Self.source(fileURL: fixture.fileURL, indexedBytes: 512),
            records: prefix,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-append")
        let suffix = [
            Self.record(
                eventIndex: 2,
                input: 250,
                turnID: "suffix-turn",
                knownCostNanos: 500_000,
                pricingModel: "openai/gpt-redacted",
                pricingMode: "standard"),
        ]
        let updatedSource = try Self.source(fileURL: fixture.fileURL, indexedBytes: 1024)

        let updated = try fixture.store.append(
            expected: published,
            updatedSource: updatedSource,
            records: suffix,
            nextUsageRowIndex: 3)
        let retry = try fixture.store.append(
            expected: published,
            updatedSource: updatedSource,
            records: suffix,
            nextUsageRowIndex: 3)

        #expect(retry == updated)
        #expect(try Self.readyRows(store: fixture.store, reference: updated) == prefix + suffix)
        #expect(try Self.readyRows(store: fixture.store, reference: published) == prefix)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `suffix load decodes only appended rows and rejects a wrong boundary`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let prefix = (0..<8).map {
            Self.record(eventIndex: $0, input: 100 + $0, turnID: "prefix-turn-\($0)")
        }
        let published = try fixture.store.createGeneration(
            source: Self.source(fileURL: fixture.fileURL, indexedBytes: 512),
            records: prefix,
            nextUsageRowIndex: prefix.count,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-suffix-load")
        let suffix = [Self.record(eventIndex: 8, input: 250, turnID: "suffix-turn")]
        let updated = try fixture.store.append(
            expected: published,
            updatedSource: Self.source(fileURL: fixture.fileURL, indexedBytes: 1024),
            records: suffix,
            nextUsageRowIndex: 9)
        let recorder = CostUsageCodexUsageRowStore.RowReadRecorder()
        let reader = CostUsageCodexUsageRowStore(
            cacheRoot: fixture.cacheRoot,
            rowReadRecorder: recorder)
        let boundary = CostUsageCodexUsageRowPrefixBoundary(
            generation: published.state.generation,
            rowCount: published.state.rowCount,
            prefixDigest: published.state.prefixDigest)

        switch reader.loadSuffix(updated, after: boundary) {
        case let .ready(rows):
            #expect(rows == suffix)
        case .needsRebuild, .temporarilyUnavailable:
            Issue.record("Expected a ready suffix lookup")
        }
        #expect(recorder.snapshot().decodedRowCount == suffix.count)

        let decodedBeforeValidation = recorder.snapshot().decodedRowCount
        switch reader.validatePublishedReference(updated) {
        case .ready:
            break
        case .needsRebuild, .temporarilyUnavailable:
            Issue.record("Expected the published reference to validate")
        }
        #expect(recorder.snapshot().decodedRowCount == decodedBeforeValidation)

        let decodedBeforeFailure = recorder.snapshot().decodedRowCount
        let wrongBoundary = CostUsageCodexUsageRowPrefixBoundary(
            generation: published.state.generation,
            rowCount: published.state.rowCount,
            prefixDigest: String(repeating: "0", count: 64))
        #expect(Self.needsRebuild(reader.loadSuffix(updated, after: wrongBoundary)))
        #expect(recorder.snapshot().decodedRowCount == decodedBeforeFailure)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `SQLite ahead rewinds unpublished sparse rows and replays authoritatively`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let prefix = [Self.record(eventIndex: 0, input: 100, turnID: "prefix-turn")]
        let published = try fixture.store.createGeneration(
            source: Self.source(fileURL: fixture.fileURL, indexedBytes: 512),
            records: prefix,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-rewind")

        let unpublishedRows = [
            Self.record(eventIndex: 2, input: 900, turnID: "unpublished-turn"),
        ]
        let ahead = try fixture.store.append(
            expected: published,
            updatedSource: Self.source(fileURL: fixture.fileURL, indexedBytes: 1024),
            records: unpublishedRows,
            nextUsageRowIndex: 3)
        #expect(try Self.readyRows(store: fixture.store, reference: published) == prefix)

        let authoritativeRows = [
            Self.record(eventIndex: 1, input: 300, turnID: "authoritative-turn-a"),
            Self.record(eventIndex: 3, input: 400, turnID: "authoritative-turn-b"),
        ]
        let completed = try fixture.store.append(
            expected: published,
            updatedSource: Self.source(
                fileURL: fixture.fileURL,
                indexedBytes: 2048,
                isComplete: true),
            records: authoritativeRows,
            nextUsageRowIndex: 4)
        let retry = try fixture.store.append(
            expected: published,
            updatedSource: completed.source,
            records: authoritativeRows,
            nextUsageRowIndex: 4)

        #expect(retry == completed)
        #expect(try Self.readyRows(store: fixture.store, reference: completed) == prefix + authoritativeRows)
        #expect(Self.needsRebuild(fixture.store.load(ahead)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `replacement generations retain old published rows`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        let oldRows = [
            Self.record(
                eventIndex: 0,
                input: 100,
                turnID: "old-turn",
                knownCostNanos: 100_000,
                pricingMode: "standard"),
        ]
        let newRows = [
            Self.record(
                eventIndex: 0,
                input: 100,
                turnID: "new-turn",
                knownCostNanos: 75000,
                pricingMode: "priority"),
        ]
        let oldReference = try fixture.store.createGeneration(
            source: source,
            records: oldRows,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-old")
        let newReference = try fixture.store.createGeneration(
            source: source,
            records: newRows,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v2",
            priorityMetadataKey: "priority-v2",
            generation: "generation-new")

        #expect(try Self.readyRows(store: fixture.store, reference: oldReference) == oldRows)
        #expect(try Self.readyRows(store: fixture.store, reference: newReference) == newRows)
        #expect(fixture.store.contains(oldReference))
        #expect(fixture.store.contains(newReference))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `audit field tampering invalidates the published digest`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let rows = [
            Self.record(
                eventIndex: 0,
                input: 100,
                turnID: "audit-turn",
                knownCostNanos: 123_456,
                unpricedTokens: 9,
                pricingModel: "openai/gpt-redacted",
                pricingMode: "priority"),
        ]
        let reference = try fixture.store.createGeneration(
            source: Self.source(
                fileURL: fixture.fileURL,
                indexedBytes: 2048,
                isComplete: true),
            records: rows,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-audit-tamper")
        #expect(try Self.readyRows(store: fixture.store, reference: reference) == rows)

        try Self.tamperKnownCost(
            databaseURL: fixture.store.databaseURL(),
            generation: reference.state.generation)

        #expect(Self.needsRebuild(fixture.store.load(reference)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `structural corruption is quarantined and old references fail closed`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        let rows = [Self.record(eventIndex: 0, input: 100, turnID: "original-turn")]
        let original = try fixture.store.createGeneration(
            source: source,
            records: rows,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-before-corruption")
        let databaseURL = fixture.store.databaseURL()
        try Data("not-a-sqlite-database".utf8).write(to: databaseURL)

        let structuralError: Error
        do {
            _ = try fixture.store.createGeneration(
                source: source,
                records: rows,
                nextUsageRowIndex: 1,
                coverageSinceKey: "2026-01-01",
                coverageUntilKey: "2026-01-07",
                pricingKey: "pricing-v1",
                priorityMetadataKey: "priority-v1",
                generation: "generation-corruption-probe")
            Issue.record("Expected the malformed database to fail structurally")
            return
        } catch {
            structuralError = error
        }
        #expect(CostUsageCodexUsageRowStore.failureDisposition(for: structuralError) == .needsRebuild)

        let recovery = try fixture.store.quarantineAndResetDatabaseAfterStructuralFailure(structuralError)
        guard case let .quarantined(quarantineURL) = recovery else {
            Issue.record("Expected structural recovery to quarantine the live database")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: databaseURL.path))
        #expect(FileManager.default.fileExists(
            atPath: quarantineURL.appendingPathComponent(databaseURL.lastPathComponent).path))
        #expect(Self.needsRebuild(fixture.store.load(original)))

        let rebuilt = try fixture.store.createGeneration(
            source: source,
            records: rows,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-after-corruption")
        #expect(try Self.readyRows(store: fixture.store, reference: rebuilt) == rows)
        #expect(Self.needsRebuild(fixture.store.load(original)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `repeated owned refresh checks schema without repeating full health scan`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let recorder = CostUsageCodexUsageRowStore.MaintenanceRecorder()
        let fixture = try Self.makeFixture(maintenanceRecorder: recorder)
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        let reference = try fixture.store.createGeneration(
            source: source,
            records: [Self.record(eventIndex: 0, input: 100, turnID: "health-turn")],
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-health")
        var usage = CostUsageFileUsage(mtimeUnixMs: 1, size: source.indexedBytes, days: [:])
        usage.codexUsageRowSidecarState = reference.state
        var cache = CostUsageCache()
        cache.files[fixture.fileURL.path] = usage

        CostUsageScanner.prepareCodexUsageRowStoreForOwnedRefresh(
            cache: &cache,
            store: fixture.store)
        let nextPassStore = CostUsageCodexUsageRowStore(
            cacheRoot: fixture.cacheRoot,
            maintenanceRecorder: recorder)
        CostUsageScanner.prepareCodexUsageRowStoreForOwnedRefresh(
            cache: &cache,
            store: nextPassStore)

        #expect(recorder.snapshot().fullHealthScanCount == 1)
        #expect(cache.files[fixture.fileURL.path]?.codexUsageRowSidecarState == reference.state)

        // Memoization removes only the full-table quick check. A later pass still opens the
        // database and rejects a schema it cannot safely understand.
        try Self.setUserVersion(databaseURL: fixture.store.databaseURL(), version: 2)
        do {
            try nextPassStore.validateDatabaseHealth(requireExistingDatabase: true)
            Issue.record("Expected the repeated health check to reject a newer schema")
        } catch let CostUsageCodexUsageRowStore.StoreError.incompatibleSchema(version) {
            #expect(version == 2)
        }
        #expect(recorder.snapshot().fullHealthScanCount == 1)

        // Any structural store failure rearms the complete check for the next owned refresh.
        try Self.setUserVersion(databaseURL: fixture.store.databaseURL(), version: 1)
        nextPassStore.recordDatabaseFailure(
            CostUsageCodexUsageRowStore.StoreError.sqlite(code: SQLITE_CORRUPT))
        try nextPassStore.validateDatabaseHealth(requireExistingDatabase: true)
        #expect(recorder.snapshot().fullHealthScanCount == 2)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `garbage collection retains every published generation and honors grace`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        let rows = [Self.record(eventIndex: 0, input: 100, turnID: "gc-turn")]
        func generation(_ id: String) throws -> CostUsageCodexUsageRowReference {
            try fixture.store.createGeneration(
                source: source,
                records: rows,
                nextUsageRowIndex: 1,
                coverageSinceKey: "2026-01-01",
                coverageUntilKey: "2026-01-07",
                pricingKey: "pricing-v1",
                priorityMetadataKey: "priority-v1",
                generation: id)
        }

        let published = try generation("generation-gc-published")
        let expired = try generation("generation-gc-expired")
        let recent = try generation("generation-gc-recent")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        let nowUnixMs = Int64((now.timeIntervalSince1970 * 1000).rounded())
        try Self.setGenerationCreatedAt(
            databaseURL: fixture.store.databaseURL(),
            generation: published.state.generation,
            unixMs: 0)
        try Self.setGenerationCreatedAt(
            databaseURL: fixture.store.databaseURL(),
            generation: expired.state.generation,
            unixMs: 0)
        try Self.setGenerationCreatedAt(
            databaseURL: fixture.store.databaseURL(),
            generation: recent.state.generation,
            unixMs: nowUnixMs)

        let first = try fixture.store.garbageCollect(
            publishedGenerationIDs: [published.state.generation],
            gracePeriod: 3600,
            now: now)
        #expect(first.deletedGenerationCount == 1)
        #expect(first.deletedRowCount == 1)
        #expect(try Self.readyRows(store: fixture.store, reference: published) == rows)
        #expect(Self.needsRebuild(fixture.store.load(expired)))
        #expect(try Self.readyRows(store: fixture.store, reference: recent) == rows)

        let second = try fixture.store.garbageCollect(
            publishedGenerationIDs: [published.state.generation],
            gracePeriod: 3600,
            now: now.addingTimeInterval(7200))
        #expect(second.deletedGenerationCount == 1)
        #expect(second.deletedRowCount == 1)
        #expect(try Self.readyRows(store: fixture.store, reference: published) == rows)
        #expect(Self.needsRebuild(fixture.store.load(recent)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `garbage collection sweep is rate limited without weakening publication protection`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let recorder = CostUsageCodexUsageRowStore.MaintenanceRecorder()
        let fixture = try Self.makeFixture(maintenanceRecorder: recorder)
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        let rows = [Self.record(eventIndex: 0, input: 100, turnID: "gc-cadence-turn")]
        func generation(_ id: String) throws -> CostUsageCodexUsageRowReference {
            try fixture.store.createGeneration(
                source: source,
                records: rows,
                nextUsageRowIndex: 1,
                coverageSinceKey: "2026-01-01",
                coverageUntilKey: "2026-01-07",
                pricingKey: "pricing-v1",
                priorityMetadataKey: "priority-v1",
                generation: id)
        }

        let published = try generation("generation-gc-cadence-published")
        let unreferenced = try generation("generation-gc-cadence-unreferenced")
        try Self.setGenerationCreatedAt(
            databaseURL: fixture.store.databaseURL(),
            generation: published.state.generation,
            unixMs: 0)
        try Self.setGenerationCreatedAt(
            databaseURL: fixture.store.databaseURL(),
            generation: unreferenced.state.generation,
            unixMs: 0)
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(fixture.store.shouldRunGarbageCollection(now: now))

        let initial = try fixture.store.garbageCollect(
            publishedGenerationIDs: [published.state.generation, unreferenced.state.generation],
            gracePeriod: 0,
            now: now)
        #expect(initial.deletedGenerationCount == 0)
        #expect(recorder.snapshot().garbageCollectionSweepCount == 1)
        #expect(!fixture.store.shouldRunGarbageCollection(now: now.addingTimeInterval(1)))

        let skipped = try fixture.store.garbageCollect(
            publishedGenerationIDs: [published.state.generation],
            gracePeriod: 0,
            now: now.addingTimeInterval(1))
        #expect(skipped.deletedGenerationCount == 0)
        #expect(recorder.snapshot().garbageCollectionSweepCount == 1)
        #expect(try Self.readyRows(store: fixture.store, reference: published) == rows)
        #expect(try Self.readyRows(store: fixture.store, reference: unreferenced) == rows)

        let dueAt = now.addingTimeInterval(
            CostUsageCodexUsageRowStore.garbageCollectionMinimumInterval + 1)
        #expect(fixture.store.shouldRunGarbageCollection(now: dueAt))
        let due = try fixture.store.garbageCollect(
            publishedGenerationIDs: [published.state.generation],
            gracePeriod: 0,
            now: dueAt)
        #expect(due.deletedGenerationCount == 1)
        #expect(due.deletedRowCount == 1)
        #expect(recorder.snapshot().garbageCollectionSweepCount == 2)
        #expect(try Self.readyRows(store: fixture.store, reference: published) == rows)
        #expect(Self.needsRebuild(fixture.store.load(unreferenced)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `skipped garbage collection attempt backs off but clock rollback retries immediately`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        _ = try fixture.store.createGeneration(
            source: source,
            records: [Self.record(eventIndex: 0, input: 100, turnID: "gc-attempt-turn")],
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-gc-attempt")
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(fixture.store.shouldRunGarbageCollection(now: now))
        #expect(fixture.store.recordSkippedGarbageCollectionAttempt(now: now))
        #expect(!fixture.store.shouldRunGarbageCollection(now: now.addingTimeInterval(1)))
        #expect(fixture.store.shouldRunGarbageCollection(now: now.addingTimeInterval(
            CostUsageCodexUsageRowStore.garbageCollectionMinimumInterval + 1)))
        #expect(fixture.store.shouldRunGarbageCollection(now: now.addingTimeInterval(-1)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `skipped garbage collection attempt does not delay a replacement database`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        let records = [Self.record(eventIndex: 0, input: 100, turnID: "gc-replacement-turn")]
        _ = try fixture.store.createGeneration(
            source: source,
            records: records,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-before-gc-replacement")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(fixture.store.recordSkippedGarbageCollectionAttempt(now: now))
        #expect(!fixture.store.shouldRunGarbageCollection(now: now.addingTimeInterval(1)))

        let databaseURL = fixture.store.databaseURL()
        let movedURL = databaseURL.appendingPathExtension("replaced")
        for suffix in ["-wal", "-shm", "-journal"] {
            try? FileManager.default.removeItem(atPath: databaseURL.path + suffix)
        }
        try FileManager.default.moveItem(at: databaseURL, to: movedURL)
        let replacementStore = CostUsageCodexUsageRowStore(cacheRoot: fixture.cacheRoot)
        _ = try replacementStore.createGeneration(
            source: source,
            records: records,
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-after-gc-replacement")

        #expect(replacementStore.shouldRunGarbageCollection(now: now.addingTimeInterval(1)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `structural failure cannot be overwritten by skipped garbage collection backoff`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let source = try Self.source(
            fileURL: fixture.fileURL,
            indexedBytes: 2048,
            isComplete: true)
        _ = try fixture.store.createGeneration(
            source: source,
            records: [Self.record(eventIndex: 0, input: 100, turnID: "gc-structural-turn")],
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-gc-structural")
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        #expect(fixture.store.recordSkippedGarbageCollectionAttempt(now: now))
        let corruption = CostUsageCodexUsageRowStore.StoreError.sqlite(code: SQLITE_CORRUPT)
        fixture.store.recordDatabaseFailure(corruption)

        #expect(!fixture.store.recordSkippedGarbageCollectionAttempt(
            now: now.addingTimeInterval(1),
            failure: corruption))
        #expect(fixture.store.shouldRunGarbageCollection(now: now.addingTimeInterval(2)))
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `turn lookup returns only published matching source paths`() throws {
        #if canImport(SQLite3) || canImport(CSQLite3)
        let fixture = try Self.makeFixture()
        defer { fixture.cleanup() }
        let secondFile = fixture.cacheRoot.appendingPathComponent("redacted-child.jsonl")
        try Data(repeating: 0x62, count: 2048).write(to: secondFile)
        let firstReference = try fixture.store.createGeneration(
            source: Self.source(
                fileURL: fixture.fileURL,
                indexedBytes: 2048,
                isComplete: true),
            records: [Self.record(eventIndex: 0, input: 100, turnID: "other-turn")],
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-turn-first")
        let secondReference = try fixture.store.createGeneration(
            source: Self.source(
                fileURL: secondFile,
                indexedBytes: 2048,
                isComplete: true),
            records: [Self.record(eventIndex: 0, input: 200, turnID: "target-turn")],
            nextUsageRowIndex: 1,
            coverageSinceKey: "2026-01-01",
            coverageUntilKey: "2026-01-07",
            pricingKey: "pricing-v1",
            priorityMetadataKey: "priority-v1",
            generation: "generation-turn-second")

        let paths = try Self.readyPaths(fixture.store.pathsContaining(
            turnIDs: ["target-turn"],
            references: [firstReference, secondReference]))
        #expect(paths == [CostUsageCodexUsageRowStore.sourcePath(for: secondFile)])
        #expect(try Self.readyPaths(fixture.store.pathsContaining(
            turnIDs: ["missing-turn"],
            references: [firstReference, secondReference])).isEmpty)
        #else
        #expect(Bool(true))
        #endif
    }

    private struct Fixture {
        let cacheRoot: URL
        let fileURL: URL
        let store: CostUsageCodexUsageRowStore

        func cleanup() {
            try? FileManager.default.removeItem(at: self.cacheRoot)
        }
    }

    private static func makeFixture(
        maintenanceRecorder: CostUsageCodexUsageRowStore.MaintenanceRecorder? = nil) throws -> Fixture
    {
        let cacheRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("CostUsageCodexUsageRowStoreTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        let fileURL = cacheRoot.appendingPathComponent("redacted-session.jsonl")
        try Data(repeating: 0x61, count: 2048).write(to: fileURL)
        return Fixture(
            cacheRoot: cacheRoot,
            fileURL: fileURL,
            store: CostUsageCodexUsageRowStore(
                cacheRoot: cacheRoot,
                maintenanceRecorder: maintenanceRecorder))
    }

    private static func source(
        fileURL: URL,
        indexedBytes: Int64,
        isComplete: Bool = false) throws -> CostUsageCodexUsageRowSource
    {
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        return try CostUsageCodexUsageRowSource(
            path: CostUsageCodexUsageRowStore.sourcePath(for: fileURL),
            fileId: #require(metadata.fileId),
            indexedBytes: indexedBytes,
            anchor: #require(CostUsageScanner.codexTokenIndexAnchor(
                fileURL: fileURL,
                indexedBytes: indexedBytes)),
            isComplete: isComplete,
            changeUnixNs: metadata.changeUnixNs,
            sessionId: "redacted-session",
            forkedFromId: nil,
            forkDependencyKey: nil,
            producerKey: "producer-v1",
            timeZoneIdentifier: "UTC")
    }

    private static func record(
        eventIndex: Int,
        input: Int,
        turnID: String,
        knownCostNanos: Int64? = nil,
        unpricedTokens: Int? = nil,
        pricingModel: String? = nil,
        pricingMode: String? = nil) -> CostUsageCodexUsageRowRecord
    {
        CostUsageCodexUsageRowRecord(
            eventIndex: eventIndex,
            timestampUnixMs: 1_767_225_600_000 + Int64(eventIndex),
            day: "2026-01-01",
            model: "openai/gpt-redacted",
            rawModel: "gpt-redacted",
            turnID: turnID,
            input: input,
            cached: input / 10,
            output: input / 5,
            reasoning: input / 20,
            knownCostNanos: knownCostNanos,
            unpricedTokens: unpricedTokens,
            pricingModel: pricingModel,
            pricingMode: pricingMode,
            dedupKey: Data("dedup-\(eventIndex)-\(turnID)".utf8))
    }

    private static func readyRows(
        store: CostUsageCodexUsageRowStore,
        reference: CostUsageCodexUsageRowReference) throws -> [CostUsageCodexUsageRowRecord]
    {
        switch store.load(reference) {
        case let .ready(rows):
            return rows
        case .needsRebuild, .temporarilyUnavailable:
            Issue.record("Expected a ready row-store lookup")
            return []
        }
    }

    private static func readyPaths(
        _ lookup: CostUsageCodexUsageRowsLookup<Set<String>>) throws -> Set<String>
    {
        switch lookup {
        case let .ready(paths):
            return paths
        case .needsRebuild, .temporarilyUnavailable:
            Issue.record("Expected a ready turn lookup")
            return []
        }
    }

    private static func needsRebuild(_ lookup: CostUsageCodexUsageRowsLookup<some Any>) -> Bool {
        if case .needsRebuild = lookup {
            return true
        }
        return false
    }

    #if canImport(SQLite3) || canImport(CSQLite3)
    private static func tamperKnownCost(databaseURL: URL, generation: String) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            db,
            """
            UPDATE rows SET known_cost_nanos = known_cost_nanos + 1
            WHERE generation_id = ? AND event_index = 0
            """,
            -1,
            &statement,
            nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, generation, -1, Self.sqliteTransient)
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        #expect(sqlite3_changes(db) == 1)
    }

    private static func setGenerationCreatedAt(
        databaseURL: URL,
        generation: String,
        unixMs: Int64) throws
    {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        var statement: OpaquePointer?
        try #require(sqlite3_prepare_v2(
            db,
            "UPDATE generations SET created_at_ms = ? WHERE id = ?",
            -1,
            &statement,
            nil) == SQLITE_OK)
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_int64(statement, 1, unixMs)
        sqlite3_bind_text(statement, 2, generation, -1, Self.sqliteTransient)
        try #require(sqlite3_step(statement) == SQLITE_DONE)
        #expect(sqlite3_changes(db) == 1)
    }

    private static func setUserVersion(databaseURL: URL, version: Int32) throws {
        var db: OpaquePointer?
        try #require(sqlite3_open_v2(
            databaseURL.path,
            &db,
            SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX,
            nil) == SQLITE_OK)
        defer { sqlite3_close(db) }
        try #require(sqlite3_exec(db, "PRAGMA user_version = \(version)", nil, nil, nil) == SQLITE_OK)
    }

    private static let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    #endif
}
