import Foundation
#if canImport(SQLite3)
import SQLite3
#endif
import Testing
@testable import CodexBarCore

struct CodexWorkspaceUsageRowSidecarTests {
    private enum FixtureError: Error {
        case missingFileIdentity
        case missingAnchor
        case sqliteFailure(Int32)
        case missingWorkspaceMetadata
    }

    @Test
    func `workspace imports full priced rows from the JSON published reference`() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let row = Self.row(
            eventIndex: 3,
            timestampUnixMs: fixture.timestampUnixMs,
            input: 120,
            cached: 20,
            output: 30,
            reasoning: 17,
            knownCostNanos: 987_654,
            unpricedTokens: 7,
            pricingMode: "priority")
        let published = try fixture.store.createGeneration(
            source: fixture.source,
            records: [row],
            nextUsageRowIndex: 4,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        var cache = Self.cache(fixture: fixture, reference: published, rows: [row])

        // Inline data is deliberately stale. A sidecar-backed import must ignore it and load the
        // exact prefix named by the compact JSON state.
        cache.files[fixture.fileURL.path]?.codexRows = [Self.row(
            eventIndex: 99,
            timestampUnixMs: fixture.timestampUnixMs + 99,
            input: 999,
            cached: 0,
            output: 0,
            reasoning: nil,
            knownCostNanos: nil,
            unpricedTokens: 999,
            pricingMode: "standard").usageRow]

        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        try workspace.synchronizeSources(cache: cache, catalog: .empty)

        let imported = try #require(
            workspace.usageCache(roots: cache.roots ?? [:]).files[fixture.fileURL.path]?.codexRows)
        #expect(imported == [row.usageRow])
        let audited = try #require(imported.first)
        #expect(audited.rawModel == "raw-gpt-5.4")
        #expect(audited.turnID == "turn-audit")
        #expect(audited.eventIndex == 3)
        #expect(audited.timestampUnixMs == fixture.timestampUnixMs)
        #expect(audited.input == 120)
        #expect(audited.cached == 20)
        #expect(audited.output == 30)
        #expect(audited.reasoning == 17)
        #expect(audited.knownCostNanos == 987_654)
        #expect(audited.unpricedTokens == 7)
        #expect(audited.pricingModel == "priced-gpt-5.4")
        #expect(audited.pricingMode == "priority")
    }

    @Test
    func `workspace ignores SQLite ahead rows beyond the JSON published prefix`() throws {
        var fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let publishedRow = Self.row(
            eventIndex: 0,
            timestampUnixMs: fixture.timestampUnixMs,
            input: 100,
            cached: 10,
            output: 20,
            reasoning: 5,
            knownCostNanos: 111,
            unpricedTokens: 0,
            pricingMode: "standard")
        let published = try fixture.store.createGeneration(
            source: fixture.source,
            records: [publishedRow],
            nextUsageRowIndex: 1,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let cache = Self.cache(fixture: fixture, reference: published, rows: [publishedRow])

        try Self.append(Data(repeating: 0x62, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let aheadRow = Self.row(
            eventIndex: 1,
            timestampUnixMs: fixture.timestampUnixMs + 1,
            input: 900,
            cached: 90,
            output: 80,
            reasoning: 70,
            knownCostNanos: 999,
            unpricedTokens: 0,
            pricingMode: "priority")
        _ = try fixture.store.append(
            expected: published,
            updatedSource: fixture.source,
            records: [aheadRow],
            nextUsageRowIndex: 2)

        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        try workspace.synchronizeSources(cache: cache, catalog: .empty)

        let imported = try #require(
            workspace.usageCache(roots: cache.roots ?? [:]).files[fixture.fileURL.path]?.codexRows)
        #expect(imported == [publishedRow.usageRow])
        #expect(!imported.contains(where: { $0.eventIndex == aheadRow.eventIndex }))
    }

    @Test
    func `unavailable published rows roll back and preserve the last complete workspace snapshot`() throws {
        var fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let row = Self.row(
            eventIndex: 0,
            timestampUnixMs: fixture.timestampUnixMs,
            input: 100,
            cached: 10,
            output: 20,
            reasoning: 5,
            knownCostNanos: 111,
            unpricedTokens: 0,
            pricingMode: "standard")
        let published = try fixture.store.createGeneration(
            source: fixture.source,
            records: [row],
            nextUsageRowIndex: 1,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let cache = Self.cache(fixture: fixture, reference: published, rows: [row])
        let firstSnapshot = try Self.snapshot(fixture: fixture, cache: cache, now: fixture.day)
        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        try workspace.synchronize(
            snapshot: firstSnapshot,
            cache: cache,
            catalog: .empty,
            rootsFingerprint: cache.roots ?? [:])

        var missingGenerationCache = cache
        var missingState = published.state
        missingState.generation = "missing-(UUID().uuidString)"
        missingGenerationCache.files[fixture.fileURL.path]?.codexUsageRowSidecarState = missingState
        missingGenerationCache.files[fixture.fileURL.path] = missingGenerationCache.files[fixture.fileURL.path]?
            .refreshingCodexWorkspaceUsageFingerprint()
        let replacementSnapshot = try Self.snapshot(
            fixture: fixture,
            cache: missingGenerationCache,
            now: fixture.day.addingTimeInterval(60))

        #expect(throws: (any Error).self) {
            try workspace.synchronize(
                snapshot: replacementSnapshot,
                cache: missingGenerationCache,
                catalog: .empty,
                rootsFingerprint: missingGenerationCache.roots ?? [:])
        }
        try Self.expectSnapshotAndRowsPreserved(
            workspace: workspace,
            snapshot: firstSnapshot,
            cache: cache,
            path: fixture.fileURL.path,
            row: row.usageRow)

        #if canImport(SQLite3)
        try Self.append(Data(repeating: 0x65, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let futureRow = Self.row(
            eventIndex: 1,
            timestampUnixMs: fixture.timestampUnixMs + 1,
            input: 1,
            cached: 0,
            output: 1,
            reasoning: 0,
            knownCostNanos: 1,
            unpricedTokens: 0,
            pricingMode: "standard")
        let futureReference = try fixture.store.append(
            expected: published,
            updatedSource: fixture.source,
            records: [futureRow],
            nextUsageRowIndex: 2)
        let futureSchemaCache = Self.cache(
            fixture: fixture,
            reference: futureReference,
            rows: [row, futureRow])

        var database: OpaquePointer?
        #expect(sqlite3_open(fixture.store.databaseURL().path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA user_version = 3", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)

        #expect(throws: (any Error).self) {
            try workspace.synchronizeSources(cache: futureSchemaCache, catalog: .empty)
        }
        try Self.expectSnapshotAndRowsPreserved(
            workspace: workspace,
            snapshot: firstSnapshot,
            cache: cache,
            path: fixture.fileURL.path,
            row: row.usageRow)
        #endif
    }

    @Test
    func `same generation imports only one event after a 2048 row published prefix`() throws {
        var fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let prefixRows = (0..<2048).map { index in
            Self.row(
                eventIndex: index,
                timestampUnixMs: fixture.timestampUnixMs + Int64(index),
                input: 1,
                cached: 0,
                output: 1,
                reasoning: 0,
                knownCostNanos: 1,
                unpricedTokens: 0,
                pricingMode: "standard")
        }
        let published = try fixture.store.createGeneration(
            source: fixture.source,
            records: prefixRows,
            nextUsageRowIndex: prefixRows.count,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let rowReadRecorder = CostUsageCodexUsageRowStore.RowReadRecorder()
        let usageCacheWorkRecorder = CodexWorkspaceUsageSidecar.UsageCacheWorkRecorder()
        let workspace = CodexWorkspaceUsageSidecar(
            cacheRoot: fixture.env.cacheRoot,
            usageRowReadRecorder: rowReadRecorder,
            usageCacheWorkRecorder: usageCacheWorkRecorder)
        try workspace.synchronizeSources(
            cache: Self.cache(fixture: fixture, reference: published, rows: prefixRows),
            catalog: .empty)
        let decodedBeforeAppend = rowReadRecorder.snapshot().decodedRowCount
        #expect(decodedBeforeAppend == prefixRows.count)
        #if canImport(SQLite3)
        try Self.installEventMutationAudit(cacheRoot: fixture.env.cacheRoot)
        #endif

        try Self.append(Data(repeating: 0x63, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let appendedRow = Self.row(
            eventIndex: 2048,
            timestampUnixMs: fixture.timestampUnixMs + 2048,
            input: 7,
            cached: 3,
            output: 2,
            reasoning: 1,
            knownCostNanos: 9,
            unpricedTokens: 0,
            pricingMode: "priority")
        let appended = try fixture.store.append(
            expected: published,
            updatedSource: fixture.source,
            records: [appendedRow],
            nextUsageRowIndex: 2049)
        let allRows = prefixRows + [appendedRow]
        var appendedCache = Self.cache(fixture: fixture, reference: appended, rows: allRows)
        let model = "openai/gpt-5.4"
        appendedCache.files[fixture.fileURL.path]?.codexStandardTokens = [
            fixture.dayKey: [model: 4096],
        ]
        appendedCache.files[fixture.fileURL.path]?.codexPriorityTokens = [
            fixture.dayKey: [model: 9],
        ]
        appendedCache.files[fixture.fileURL.path]?.codexStandardCostNanos = [
            fixture.dayKey: [model: 2048],
        ]
        appendedCache.files[fixture.fileURL.path]?.codexPriorityCostNanos = [
            fixture.dayKey: [model: 9],
        ]
        appendedCache.files[fixture.fileURL.path]?.codexPrioritySurchargeNanos = [
            fixture.dayKey: [model: 4],
        ]
        appendedCache.files[fixture.fileURL.path] = appendedCache.files[fixture.fileURL.path]?
            .refreshingCodexWorkspaceUsageFingerprint()
        try workspace.synchronizeSources(cache: appendedCache, catalog: .empty)
        #expect(rowReadRecorder.snapshot().decodedRowCount - decodedBeforeAppend == 1)

        let expectedUsage = try #require(appendedCache.files[fixture.fileURL.path])
        let importedUsage = try #require(
            workspace.usageCache(roots: appendedCache.roots ?? [:]).files[fixture.fileURL.path])
        #expect(usageCacheWorkRecorder.snapshot() == .init(
            eventRowsDecoded: allRows.count,
            eventRowGroupWritebacks: 1))
        #expect(importedUsage.codexRows == allRows.map(\.usageRow))
        #expect(importedUsage.days == expectedUsage.days)
        #expect(importedUsage.codexCostNanos == expectedUsage.codexCostNanos)
        #expect(importedUsage.codexStandardTokens == expectedUsage.codexStandardTokens)
        #expect(importedUsage.codexPriorityTokens == expectedUsage.codexPriorityTokens)
        #expect(importedUsage.codexStandardCostNanos == expectedUsage.codexStandardCostNanos)
        #expect(importedUsage.codexPriorityCostNanos == expectedUsage.codexPriorityCostNanos)
        #expect(importedUsage.codexPrioritySurchargeNanos == expectedUsage.codexPrioritySurchargeNanos)
        #if canImport(SQLite3)
        #expect(try Self.eventMutationCount(cacheRoot: fixture.env.cacheRoot, action: "insert") == 1)
        #expect(try Self.eventMutationCount(cacheRoot: fixture.env.cacheRoot, action: "delete") == 0)
        #endif
    }

    @Test
    func `same content replacement generation validates without decoding historical rows`() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let rows = (0..<32).map { index in
            Self.row(
                eventIndex: index,
                timestampUnixMs: fixture.timestampUnixMs + Int64(index),
                input: index + 1,
                cached: index,
                output: 1,
                reasoning: 0,
                knownCostNanos: Int64(index + 1),
                unpricedTokens: 0,
                pricingMode: "standard")
        }
        let first = try fixture.store.createGeneration(
            source: fixture.source,
            records: rows,
            nextUsageRowIndex: rows.count,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let rowReadRecorder = CostUsageCodexUsageRowStore.RowReadRecorder()
        let workspace = CodexWorkspaceUsageSidecar(
            cacheRoot: fixture.env.cacheRoot,
            usageRowReadRecorder: rowReadRecorder)
        try workspace.synchronizeSources(
            cache: Self.cache(fixture: fixture, reference: first, rows: rows),
            catalog: .empty)
        let decodedBeforeRepublish = rowReadRecorder.snapshot().decodedRowCount
        #expect(decodedBeforeRepublish == rows.count)

        let replacement = try fixture.store.createGeneration(
            source: fixture.source,
            records: rows,
            nextUsageRowIndex: rows.count,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        #expect(replacement.state.generation != first.state.generation)
        let replacementCache = Self.cache(fixture: fixture, reference: replacement, rows: rows)
        try workspace.synchronizeSources(cache: replacementCache, catalog: .empty)

        #expect(rowReadRecorder.snapshot().decodedRowCount == decodedBeforeRepublish)
        let imported = try #require(
            workspace.usageCache(roots: replacementCache.roots ?? [:])
                .files[fixture.fileURL.path]?.codexRows)
        #expect(imported == rows.map(\.usageRow))
        #if canImport(SQLite3)
        let metadata = try Self.workspaceRolloutMetadata(
            cacheRoot: fixture.env.cacheRoot,
            path: fixture.fileURL.path)
        #expect(metadata.generation == replacement.state.generation)
        #endif
    }

    @Test
    func `published suffix excludes a later SQLite ahead append`() throws {
        var fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let prefixRow = Self.row(
            eventIndex: 0,
            timestampUnixMs: fixture.timestampUnixMs,
            input: 10,
            cached: 1,
            output: 2,
            reasoning: 1,
            knownCostNanos: 10,
            unpricedTokens: 0,
            pricingMode: "standard")
        let prefix = try fixture.store.createGeneration(
            source: fixture.source,
            records: [prefixRow],
            nextUsageRowIndex: 1,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let rowReadRecorder = CostUsageCodexUsageRowStore.RowReadRecorder()
        let workspace = CodexWorkspaceUsageSidecar(
            cacheRoot: fixture.env.cacheRoot,
            usageRowReadRecorder: rowReadRecorder)
        try workspace.synchronizeSources(
            cache: Self.cache(fixture: fixture, reference: prefix, rows: [prefixRow]),
            catalog: .empty)
        let decodedBeforeSuffix = rowReadRecorder.snapshot().decodedRowCount

        try Self.append(Data(repeating: 0x66, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let publishedRow = Self.row(
            eventIndex: 1,
            timestampUnixMs: fixture.timestampUnixMs + 1,
            input: 20,
            cached: 2,
            output: 3,
            reasoning: 1,
            knownCostNanos: 20,
            unpricedTokens: 0,
            pricingMode: "standard")
        let published = try fixture.store.append(
            expected: prefix,
            updatedSource: fixture.source,
            records: [publishedRow],
            nextUsageRowIndex: 2)

        try Self.append(Data(repeating: 0x67, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let aheadRow = Self.row(
            eventIndex: 2,
            timestampUnixMs: fixture.timestampUnixMs + 2,
            input: 900,
            cached: 90,
            output: 80,
            reasoning: 70,
            knownCostNanos: 900,
            unpricedTokens: 0,
            pricingMode: "priority")
        _ = try fixture.store.append(
            expected: published,
            updatedSource: fixture.source,
            records: [aheadRow],
            nextUsageRowIndex: 3)

        let publishedRows = [prefixRow, publishedRow]
        let publishedCache = Self.cache(fixture: fixture, reference: published, rows: publishedRows)
        try workspace.synchronizeSources(cache: publishedCache, catalog: .empty)

        #expect(rowReadRecorder.snapshot().decodedRowCount - decodedBeforeSuffix == 1)
        let imported = try #require(
            workspace.usageCache(roots: publishedCache.roots ?? [:])
                .files[fixture.fileURL.path]?.codexRows)
        #expect(imported == publishedRows.map(\.usageRow))
        #expect(!imported.contains(where: { $0.eventIndex == aheadRow.eventIndex }))
    }

    @Test
    func `zero row suffix updates rollout metadata without rewriting events`() throws {
        var fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let row = Self.row(
            eventIndex: 0,
            timestampUnixMs: fixture.timestampUnixMs,
            input: 10,
            cached: 2,
            output: 3,
            reasoning: 1,
            knownCostNanos: 5,
            unpricedTokens: 0,
            pricingMode: "standard")
        let published = try fixture.store.createGeneration(
            source: fixture.source,
            records: [row],
            nextUsageRowIndex: 1,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let initialCache = Self.cache(fixture: fixture, reference: published, rows: [row])
        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        try workspace.synchronizeSources(cache: initialCache, catalog: .empty)
        #if canImport(SQLite3)
        try Self.installEventMutationAudit(cacheRoot: fixture.env.cacheRoot)
        #endif

        try Self.append(Data(repeating: 0x64, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let advanced = try fixture.store.append(
            expected: published,
            updatedSource: fixture.source,
            records: [],
            nextUsageRowIndex: published.state.nextUsageRowIndex)
        let advancedCache = Self.cache(fixture: fixture, reference: advanced, rows: [row])
        try workspace.synchronizeSources(cache: advancedCache, catalog: .empty)

        let imported = try #require(
            workspace.usageCache(roots: advancedCache.roots ?? [:]).files[fixture.fileURL.path]?.codexRows)
        #expect(imported == [row.usageRow])
        #if canImport(SQLite3)
        #expect(try Self.eventMutationCount(cacheRoot: fixture.env.cacheRoot, action: "insert") == 0)
        #expect(try Self.eventMutationCount(cacheRoot: fixture.env.cacheRoot, action: "delete") == 0)
        let metadata = try Self.workspaceRolloutMetadata(
            cacheRoot: fixture.env.cacheRoot,
            path: fixture.fileURL.path)
        #expect(metadata.parsedBytes == advanced.source.indexedBytes)
        #expect(metadata.generation == advanced.state.generation)
        #expect(metadata.rowCount == advanced.state.rowCount)
        #expect(metadata.prefixDigest == advanced.state.prefixDigest)
        #endif
    }

    @Test
    func `wrong suffix boundary rolls back Workspace metadata events daily rows and snapshot`() throws {
        #if canImport(SQLite3)
        var fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let prefixRow = Self.row(
            eventIndex: 0,
            timestampUnixMs: fixture.timestampUnixMs,
            input: 100,
            cached: 10,
            output: 20,
            reasoning: 5,
            knownCostNanos: 111,
            unpricedTokens: 0,
            pricingMode: "standard")
        let prefix = try fixture.store.createGeneration(
            source: fixture.source,
            records: [prefixRow],
            nextUsageRowIndex: 1,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let initialCache = Self.cache(fixture: fixture, reference: prefix, rows: [prefixRow])
        let initialSnapshot = try Self.snapshot(fixture: fixture, cache: initialCache, now: fixture.day)
        let initialCatalogEntry = CodexThreadCatalogEntry(
            id: fixture.sessionID,
            rolloutPath: fixture.fileURL.path,
            cwd: "/catalog/before",
            title: "Before failed suffix import",
            preview: nil,
            modelProvider: "openai",
            model: "openai/gpt-5.4",
            reasoningEffort: nil,
            createdAtUnixMs: fixture.timestampUnixMs,
            updatedAtUnixMs: fixture.timestampUnixMs,
            archived: false)
        let initialCatalog = CodexThreadCatalog(
            entriesById: [initialCatalogEntry.id: initialCatalogEntry],
            entriesByRolloutPath: [fixture.fileURL.standardizedFileURL.path: initialCatalogEntry],
            fingerprint: "wrong-boundary-before")
        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        try workspace.synchronize(
            snapshot: initialSnapshot,
            cache: initialCache,
            catalog: initialCatalog,
            rootsFingerprint: initialCache.roots ?? [:])

        try Self.append(Data(repeating: 0x68, count: 4096), to: fixture.fileURL)
        fixture.source = try Self.source(
            fileURL: fixture.fileURL,
            isComplete: false,
            sessionID: fixture.sessionID,
            producerKey: fixture.producerKey,
            timeZoneIdentifier: fixture.timeZoneIdentifier)
        let suffixRow = Self.row(
            eventIndex: 1,
            timestampUnixMs: fixture.timestampUnixMs + 1,
            input: 900,
            cached: 90,
            output: 80,
            reasoning: 70,
            knownCostNanos: 999,
            unpricedTokens: 0,
            pricingMode: "priority")
        let appended = try fixture.store.append(
            expected: prefix,
            updatedSource: fixture.source,
            records: [suffixRow],
            nextUsageRowIndex: 2)
        let appendedCache = Self.cache(
            fixture: fixture,
            reference: appended,
            rows: [prefixRow, suffixRow])
        let replacementSnapshot = try Self.snapshot(
            fixture: fixture,
            cache: appendedCache,
            now: fixture.day.addingTimeInterval(60))
        let replacementCatalogEntry = CodexThreadCatalogEntry(
            id: fixture.sessionID,
            rolloutPath: fixture.fileURL.path,
            cwd: "/catalog/after",
            title: "After failed suffix import",
            preview: nil,
            modelProvider: "openai",
            model: "openai/gpt-5.4",
            reasoningEffort: nil,
            createdAtUnixMs: fixture.timestampUnixMs,
            updatedAtUnixMs: fixture.timestampUnixMs + 60000,
            archived: false)
        let replacementCatalog = CodexThreadCatalog(
            entriesById: [replacementCatalogEntry.id: replacementCatalogEntry],
            entriesByRolloutPath: [fixture.fileURL.standardizedFileURL.path: replacementCatalogEntry],
            fingerprint: "wrong-boundary-after")

        try Self.tamperUsageRowBoundary(
            databaseURL: fixture.store.databaseURL(),
            generation: prefix.state.generation,
            rowOrdinal: prefix.state.rowCount - 1)
        #expect(throws: (any Error).self) {
            try workspace.synchronize(
                snapshot: replacementSnapshot,
                cache: appendedCache,
                catalog: replacementCatalog,
                rootsFingerprint: appendedCache.roots ?? [:])
        }

        try Self.expectSnapshotAndRowsPreserved(
            workspace: workspace,
            snapshot: initialSnapshot,
            cache: initialCache,
            path: fixture.fileURL.path,
            row: prefixRow.usageRow)
        let retainedUsage = try #require(
            workspace.usageCache(roots: initialCache.roots ?? [:]).files[fixture.fileURL.path])
        let expectedUsage = try #require(initialCache.files[fixture.fileURL.path])
        #expect(retainedUsage.days == expectedUsage.days)
        #expect(retainedUsage.codexCostNanos == expectedUsage.codexCostNanos)
        #expect(retainedUsage.codexSession?.cwd == initialCatalogEntry.cwd)
        #expect(retainedUsage.codexSession?.title == initialCatalogEntry.title)
        let metadata = try Self.workspaceRolloutMetadata(
            cacheRoot: fixture.env.cacheRoot,
            path: fixture.fileURL.path)
        #expect(metadata.generation == prefix.state.generation)
        #expect(metadata.rowCount == prefix.state.rowCount)
        #expect(metadata.prefixDigest == prefix.state.prefixDigest)
        #else
        #expect(Bool(true))
        #endif
    }

    @Test
    func `replacement generation fully replaces workspace events`() throws {
        let fixture = try Self.makeFixture()
        defer { fixture.env.cleanup() }

        let oldRows = [0, 1].map { index in
            Self.row(
                eventIndex: index,
                timestampUnixMs: fixture.timestampUnixMs + Int64(index),
                input: 10 + index,
                cached: 1,
                output: 2,
                reasoning: 1,
                knownCostNanos: Int64(10 + index),
                unpricedTokens: 0,
                pricingMode: "standard")
        }
        let first = try fixture.store.createGeneration(
            source: fixture.source,
            records: oldRows,
            nextUsageRowIndex: 2,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let workspace = CodexWorkspaceUsageSidecar(cacheRoot: fixture.env.cacheRoot)
        try workspace.synchronizeSources(
            cache: Self.cache(fixture: fixture, reference: first, rows: oldRows),
            catalog: .empty)
        #if canImport(SQLite3)
        try Self.installEventMutationAudit(cacheRoot: fixture.env.cacheRoot)
        #endif

        let replacementRow = Self.row(
            eventIndex: 0,
            timestampUnixMs: fixture.timestampUnixMs + 100,
            input: 99,
            cached: 9,
            output: 8,
            reasoning: 7,
            knownCostNanos: 1234,
            unpricedTokens: 0,
            pricingMode: "priority")
        let replacement = try fixture.store.createGeneration(
            source: fixture.source,
            records: [replacementRow],
            nextUsageRowIndex: 1,
            coverageSinceKey: fixture.dayKey,
            coverageUntilKey: fixture.dayKey,
            pricingKey: fixture.pricingKey,
            priorityMetadataKey: fixture.priorityMetadataKey)
        let replacementCache = Self.cache(fixture: fixture, reference: replacement, rows: [replacementRow])
        try workspace.synchronizeSources(cache: replacementCache, catalog: .empty)

        let imported = try #require(
            workspace.usageCache(roots: replacementCache.roots ?? [:]).files[fixture.fileURL.path]?.codexRows)
        #expect(imported == [replacementRow.usageRow])
        #if canImport(SQLite3)
        #expect(try Self.eventMutationCount(cacheRoot: fixture.env.cacheRoot, action: "delete") == 2)
        #expect(try Self.eventMutationCount(cacheRoot: fixture.env.cacheRoot, action: "insert") == 1)
        let metadata = try Self.workspaceRolloutMetadata(
            cacheRoot: fixture.env.cacheRoot,
            path: fixture.fileURL.path)
        #expect(metadata.generation == replacement.state.generation)
        #expect(metadata.rowCount == 1)
        #endif
    }
}

extension CodexWorkspaceUsageRowSidecarTests {
    fileprivate struct WorkspaceRolloutMetadata {
        let parsedBytes: Int64
        let generation: String
        let rowCount: Int
        let prefixDigest: String
    }

    fileprivate struct Fixture {
        let env: CostUsageTestEnvironment
        let day: Date
        let dayKey: String
        let timestampUnixMs: Int64
        let fileURL: URL
        let projectURL: URL
        let sessionID: String
        let producerKey: String
        let pricingKey: String
        let priorityMetadataKey: String
        let timeZoneIdentifier: String
        let store: CostUsageCodexUsageRowStore
        var source: CostUsageCodexUsageRowSource
    }

    fileprivate static func makeFixture() throws -> Fixture {
        let env = try CostUsageTestEnvironment()
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 7)
        let dayKey = CostUsageScanner.CostUsageDayRange.dayKey(from: day)
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "workspace-row-sidecar.jsonl",
            contents: String(repeating: "a", count: 4096))
        let projectURL = env.root.appendingPathComponent("Project", isDirectory: true)
        try FileManager.default.createDirectory(
            at: projectURL.appendingPathComponent(".git", isDirectory: true),
            withIntermediateDirectories: true)
        let sessionID = "workspace-row-sidecar-session"
        let producerKey = "codex:workspace-row-sidecar-test"
        let pricingKey = "pricing:test-v1"
        let priorityMetadataKey = "priority:test-v1"
        let timeZoneIdentifier = Calendar.current.timeZone.identifier
        let source = try Self.source(
            fileURL: fileURL,
            isComplete: false,
            sessionID: sessionID,
            producerKey: producerKey,
            timeZoneIdentifier: timeZoneIdentifier)
        return Fixture(
            env: env,
            day: day,
            dayKey: dayKey,
            timestampUnixMs: Int64((day.timeIntervalSince1970 * 1000).rounded()),
            fileURL: fileURL,
            projectURL: projectURL,
            sessionID: sessionID,
            producerKey: producerKey,
            pricingKey: pricingKey,
            priorityMetadataKey: priorityMetadataKey,
            timeZoneIdentifier: timeZoneIdentifier,
            store: CostUsageCodexUsageRowStore(cacheRoot: env.cacheRoot),
            source: source)
    }

    fileprivate static func source(
        fileURL: URL,
        isComplete: Bool,
        sessionID: String,
        producerKey: String,
        timeZoneIdentifier: String) throws -> CostUsageCodexUsageRowSource
    {
        let metadata = CostUsageScanner.codexFileMetadata(fileURL: fileURL)
        guard let fileId = metadata.fileId else { throw FixtureError.missingFileIdentity }
        guard let anchor = CostUsageScanner.codexTokenIndexAnchor(
            fileURL: fileURL,
            indexedBytes: metadata.size)
        else { throw FixtureError.missingAnchor }
        return CostUsageCodexUsageRowSource(
            path: CostUsageCodexUsageRowStore.sourcePath(for: fileURL),
            fileId: fileId,
            indexedBytes: metadata.size,
            anchor: anchor,
            isComplete: isComplete,
            changeUnixNs: metadata.changeUnixNs,
            sessionId: sessionID,
            forkedFromId: nil,
            forkDependencyKey: nil,
            producerKey: producerKey,
            timeZoneIdentifier: timeZoneIdentifier)
    }

    // swiftlint:disable:next function_parameter_count
    fileprivate static func row(
        eventIndex: Int,
        timestampUnixMs: Int64,
        input: Int,
        cached: Int,
        output: Int,
        reasoning: Int?,
        knownCostNanos: Int64?,
        unpricedTokens: Int?,
        pricingMode: String) -> CostUsageCodexUsageRowRecord
    {
        CostUsageCodexUsageRowRecord(
            eventIndex: eventIndex,
            timestampUnixMs: timestampUnixMs,
            day: "2026-08-07",
            model: "openai/gpt-5.4",
            rawModel: "raw-gpt-5.4",
            turnID: "turn-audit",
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            knownCostNanos: knownCostNanos,
            unpricedTokens: unpricedTokens,
            pricingModel: "priced-gpt-5.4",
            pricingMode: pricingMode,
            dedupKey: Data("dedup-\(eventIndex)".utf8))
    }

    fileprivate static func cache(
        fixture: Fixture,
        reference: CostUsageCodexUsageRowReference,
        rows: [CostUsageCodexUsageRowRecord]) -> CostUsageCache
    {
        let totals = rows.reduce(into: (input: 0, cached: 0, output: 0, cost: Int64(0))) { result, row in
            result.input += row.input
            result.cached += row.cached
            result.output += row.output
            result.cost += row.knownCostNanos ?? 0
        }
        let model = "openai/gpt-5.4"
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: reference.source.indexedBytes,
            days: [fixture.dayKey: [model: [totals.input, totals.cached, totals.output]]],
            parsedBytes: reference.source.indexedBytes,
            lastModel: model,
            sessionId: fixture.sessionID,
            projectPath: fixture.projectURL.path,
            canonicalProjectPath: fixture.projectURL.path,
            codexSession: CostUsageCodexSessionMetadata(
                sessionId: fixture.sessionID,
                forkedFromId: nil,
                cwd: fixture.projectURL.path,
                title: "Workspace row sidecar",
                startedAtUnixMs: fixture.timestampUnixMs,
                latestActivityUnixMs: fixture.timestampUnixMs),
            codexCostNanos: [fixture.dayKey: [model: totals.cost]],
            codexRows: nil,
            codexTokenIndexAnchor: reference.source.anchor,
            codexUsageRowSidecarState: reference.state,
            codexScanFileId: reference.source.fileId,
            codexScanChangeUnixNs: reference.source.changeUnixNs,
            codexScanTargetSize: reference.source.indexedBytes,
            codexScanComplete: reference.source.isComplete)
            .refreshingCodexWorkspaceUsageFingerprint()

        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: fixture.timeZoneIdentifier) ?? .current
        let options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.env.codexSessionsRoot,
            cacheRoot: fixture.env.cacheRoot,
            calendar: calendar)
        var cache = CostUsageCache()
        cache.producerKey = fixture.producerKey
        cache.timeZoneIdentifier = fixture.timeZoneIdentifier
        cache.codexPricingKey = fixture.pricingKey
        cache.codexPriorityMetadataKey = fixture.priorityMetadataKey
        cache.scanSinceKey = fixture.dayKey
        cache.scanUntilKey = fixture.dayKey
        cache.roots = CostUsageScanner.codexRootsFingerprint(options: options)
        cache.files[fixture.fileURL.path] = usage
        cache.days = usage.days
        return cache
    }

    fileprivate static func snapshot(
        fixture: Fixture,
        cache: CostUsageCache,
        now: Date) throws -> CodexLocalProjectUsageSnapshot
    {
        var calendar = Calendar.current
        calendar.timeZone = TimeZone(identifier: fixture.timeZoneIdentifier) ?? .current
        return try CodexLocalProjectUsageIndexer.buildSnapshotFromCostCache(
            now: now,
            historyDays: 1,
            since: fixture.day,
            until: fixture.day,
            options: CostUsageScanner.Options(
                codexSessionsRoot: fixture.env.codexSessionsRoot,
                cacheRoot: fixture.env.cacheRoot,
                calendar: calendar),
            cacheOverride: cache,
            catalogOverride: .empty)
    }

    fileprivate static func append(_ data: Data, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        _ = try handle.seekToEnd()
        try handle.write(contentsOf: data)
    }

    #if canImport(SQLite3)
    fileprivate static func tamperUsageRowBoundary(
        databaseURL: URL,
        generation: String,
        rowOrdinal: Int) throws
    {
        var database: OpaquePointer?
        let openResult = sqlite3_open(databaseURL.path, &database)
        guard openResult == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw FixtureError.sqliteFailure(openResult)
        }
        defer { sqlite3_close(database) }

        var statement: OpaquePointer?
        let sql = "UPDATE rows SET prefix_digest = ? WHERE generation_id = ? AND row_ordinal = ?"
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else { throw FixtureError.sqliteFailure(prepareResult) }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, String(repeating: "0", count: 64), -1, transient)
        sqlite3_bind_text(statement, 2, generation, -1, transient)
        sqlite3_bind_int64(statement, 3, Int64(rowOrdinal))
        let stepResult = sqlite3_step(statement)
        guard stepResult == SQLITE_DONE else { throw FixtureError.sqliteFailure(stepResult) }
        guard sqlite3_changes(database) == 1 else { throw FixtureError.missingWorkspaceMetadata }
    }

    fileprivate static func installEventMutationAudit(cacheRoot: URL) throws {
        let database = try Self.openWorkspaceDatabase(cacheRoot: cacheRoot)
        defer { sqlite3_close(database) }
        let sql = """
        CREATE TABLE workspace_event_mutations (action TEXT NOT NULL);
        CREATE TRIGGER workspace_event_insert_audit AFTER INSERT ON usage_events BEGIN
            INSERT INTO workspace_event_mutations(action) VALUES ('insert');
        END;
        CREATE TRIGGER workspace_event_delete_audit AFTER DELETE ON usage_events BEGIN
            INSERT INTO workspace_event_mutations(action) VALUES ('delete');
        END;
        """
        let result = sqlite3_exec(database, sql, nil, nil, nil)
        guard result == SQLITE_OK else { throw FixtureError.sqliteFailure(result) }
    }

    fileprivate static func eventMutationCount(cacheRoot: URL, action: String) throws -> Int {
        let database = try Self.openWorkspaceDatabase(cacheRoot: cacheRoot)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let prepareResult = sqlite3_prepare_v2(
            database,
            "SELECT COUNT(*) FROM workspace_event_mutations WHERE action = ?",
            -1,
            &statement,
            nil)
        guard prepareResult == SQLITE_OK else { throw FixtureError.sqliteFailure(prepareResult) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, action, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW else { throw FixtureError.missingWorkspaceMetadata }
        return Int(sqlite3_column_int64(statement, 0))
    }

    fileprivate static func workspaceRolloutMetadata(cacheRoot: URL, path: String) throws -> WorkspaceRolloutMetadata {
        let database = try Self.openWorkspaceDatabase(cacheRoot: cacheRoot)
        defer { sqlite3_close(database) }
        var statement: OpaquePointer?
        let sql = """
        SELECT source_parsed_bytes, row_sidecar_generation, row_sidecar_row_count,
               row_sidecar_prefix_digest
        FROM usage_rollouts WHERE rollout_path = ?
        """
        let prepareResult = sqlite3_prepare_v2(database, sql, -1, &statement, nil)
        guard prepareResult == SQLITE_OK else { throw FixtureError.sqliteFailure(prepareResult) }
        defer { sqlite3_finalize(statement) }
        sqlite3_bind_text(statement, 1, path, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(statement) == SQLITE_ROW,
              let generationText = sqlite3_column_text(statement, 1),
              let rowCount = Int(exactly: sqlite3_column_int64(statement, 2)),
              let prefixDigestText = sqlite3_column_text(statement, 3)
        else { throw FixtureError.missingWorkspaceMetadata }
        return WorkspaceRolloutMetadata(
            parsedBytes: sqlite3_column_int64(statement, 0),
            generation: String(cString: generationText),
            rowCount: rowCount,
            prefixDigest: String(cString: prefixDigestText))
    }

    fileprivate static func openWorkspaceDatabase(cacheRoot: URL) throws -> OpaquePointer {
        let url = cacheRoot
            .appendingPathComponent("local-usage", isDirectory: true)
            .appendingPathComponent("codex-workspaces-v1.sqlite", isDirectory: false)
        var database: OpaquePointer?
        let result = sqlite3_open(url.path, &database)
        guard result == SQLITE_OK, let database else {
            sqlite3_close(database)
            throw FixtureError.sqliteFailure(result)
        }
        return database
    }
    #endif

    fileprivate static func expectSnapshotAndRowsPreserved(
        workspace: CodexWorkspaceUsageSidecar,
        snapshot: CodexLocalProjectUsageSnapshot,
        cache: CostUsageCache,
        path: String,
        row: CostUsageScanner.CodexUsageRow) throws
    {
        let retained = try #require(workspace.loadLatestSnapshot(
            scopeSignature: snapshot.scopeSignature,
            historyDays: snapshot.historyDays))
        #expect(retained.updatedAt == snapshot.updatedAt)
        #expect(retained.total == snapshot.total)
        #expect(try workspace.usageCache(roots: cache.roots ?? [:]).files[path]?.codexRows == [row])
    }
}
