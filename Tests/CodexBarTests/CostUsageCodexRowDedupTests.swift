import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageCodexRowDedupTests {
    private func row(
        day: String = "2026-09-13",
        model: String = "gpt-6-astra",
        turnID: String? = "turn-1",
        eventIndex: Int?,
        timestampUnixMs: Int64? = 1_700_000_000_000,
        input: Int = 1000,
        cached: Int = 900,
        output: Int = 100,
        reasoning: Int? = nil,
        knownCostNanos: Int64? = nil,
        pricingMode: String? = nil) -> CostUsageScanner.CodexUsageRow
    {
        CostUsageScanner.CodexUsageRow(
            day: day,
            model: model,
            turnID: turnID,
            eventIndex: eventIndex,
            timestampUnixMs: timestampUnixMs,
            input: input,
            cached: cached,
            output: output,
            reasoning: reasoning,
            knownCostNanos: knownCostNanos,
            pricingMode: pricingMode)
    }

    @Test
    func `re-emitted copies deduplicate only when canonical totals prove them redundant`() {
        let day = "2026-09-13"
        let events = [
            self.row(day: day, eventIndex: 0, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: day, eventIndex: 1, timestampUnixMs: 2000, input: 600, cached: 500, output: 60),
        ]
        var duplicated: [CostUsageScanner.CodexUsageRow] = []
        var eventIndex = 0
        // Three incremental passes each re-emit the accumulated prefix under fresh indexes.
        for _ in 0..<3 {
            for event in events {
                duplicated.append(self.row(
                    day: day,
                    eventIndex: eventIndex,
                    timestampUnixMs: event.timestampUnixMs,
                    input: event.input,
                    cached: event.cached,
                    output: event.output))
                eventIndex += 1
            }
        }
        let canonical = [day: ["gpt-6-astra": [1100, 900, 110]]]

        let deduplicated = CostUsageScanner.deduplicatedCodexUsageRows(duplicated, canonicalDays: canonical)

        #expect(deduplicated.count == 2)
        #expect(Set(deduplicated.map(\.timestampUnixMs)) == [1000, 2000])
    }

    @Test
    func `distinct events sharing content are kept when canonical totals count them all`() {
        let day = "2026-09-13"
        // Two genuinely separate requests in the same millisecond with identical usage.
        let rows = [
            self.row(day: day, eventIndex: 0),
            self.row(day: day, eventIndex: 1),
        ]
        let canonical = [day: ["gpt-6-astra": [2000, 1800, 200]]]

        let deduplicated = CostUsageScanner.deduplicatedCodexUsageRows(rows, canonicalDays: canonical)

        #expect(deduplicated == rows)
    }

    @Test
    func `groups that cannot land on canonical totals stay verbatim`() {
        let day = "2026-09-13"
        let rows = [
            self.row(day: day, eventIndex: 0, timestampUnixMs: 1000),
            self.row(day: day, eventIndex: 1, timestampUnixMs: 1000),
            self.row(day: day, eventIndex: 2, timestampUnixMs: 2000),
        ]
        // Canonical counts more than one copy but fewer than three: dropping extras
        // would undershoot, so the rows are left for fail-closed reconciliation.
        let canonical = [day: ["gpt-6-astra": [1500, 1350, 150]]]

        let deduplicated = CostUsageScanner.deduplicatedCodexUsageRows(rows, canonicalDays: canonical)

        #expect(deduplicated == rows)
    }

    @Test
    func `deduplication keeps the copy with the most pricing evidence`() throws {
        let day = "2026-09-13"
        let rows = [
            self.row(day: day, eventIndex: 0),
            self.row(day: day, eventIndex: 7, knownCostNanos: 42, pricingMode: "priority"),
        ]
        let canonical = [day: ["gpt-6-astra": [1000, 900, 100]]]

        let deduplicated = CostUsageScanner.deduplicatedCodexUsageRows(rows, canonicalDays: canonical)

        let kept = try #require(deduplicated.first)
        #expect(deduplicated.count == 1)
        #expect(kept.knownCostNanos == 42)
        #expect(kept.pricingMode == "priority")
    }

    @Test
    func `canonical pricing rows resolve a group inflated by re-emitted copies`() {
        let day = "2026-09-13"
        // Interleaved copies (A, A', B, B') defeat the existing suffix trim: any
        // contiguous suffix overshoots the target, so only event-level dedup resolves.
        let rows = [
            self.row(day: day, eventIndex: 0, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: day, eventIndex: 5, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: day, eventIndex: 6, timestampUnixMs: 2000, input: 1000, cached: 800, output: 100),
            self.row(day: day, eventIndex: 9, timestampUnixMs: 2000, input: 1000, cached: 800, output: 100),
        ]
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [day: ["gpt-6-astra": [1500, 1200, 150]]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)

        let reconciled = CostUsageScanner.codexCanonicalPricingRows(usage)

        #expect(reconciled.unresolvedGroups.isEmpty)
        #expect(reconciled.rows.count == 2)
    }

    @Test
    func `canonical pricing rows still reject groups the canonical totals cannot explain`() {
        let day = "2026-09-13"
        let rows = [
            self.row(day: day, eventIndex: 0, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: day, eventIndex: 1, timestampUnixMs: 2000, input: 600, cached: 500, output: 60),
            self.row(day: day, eventIndex: 2, timestampUnixMs: 3000, input: 700, cached: 600, output: 70),
        ]
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: [day: ["gpt-6-astra": [1100, 900, 110]]],
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)

        let reconciled = CostUsageScanner.codexCanonicalPricingRows(usage)

        #expect(reconciled.unresolvedGroups == [CostUsageScanner.CodexDayModelKey(day: day, model: "gpt-6-astra")])
    }

    @Test
    func `store reload drops persisted re-emitted rows and the day keeps its cost`() throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 9, day: 13)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let unique = [
            self.row(day: range.sinceKey, eventIndex: 0, timestampUnixMs: 1000),
            self.row(day: range.sinceKey, eventIndex: 1, timestampUnixMs: 2000),
        ]
        var persisted = unique
        for copy in 0..<2 {
            for event in unique {
                persisted.append(self.row(
                    day: range.sinceKey,
                    eventIndex: 10 + copy * 10 + (event.eventIndex ?? 0),
                    timestampUnixMs: event.timestampUnixMs))
            }
        }
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: Int64(day.timeIntervalSince1970 * 1000),
            size: 1,
            days: [range.sinceKey: ["gpt-6-astra": [2000, 1800, 200]]],
            parsedBytes: 1,
            codexRows: persisted,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files[environment.codexSessionsRoot.appendingPathComponent("session.jsonl").path] = usage
        cache.days = usage.days
        cache.scanSinceKey = range.sinceKey
        cache.scanUntilKey = range.untilKey
        cache.timeZoneIdentifier = range.calendar.timeZone.identifier
        _ = CostUsageStoreAccess.replace(cacheRoot: environment.cacheRoot, cache: cache, calendar: range.calendar)

        let restored = CostUsageStoreAccess.read(cacheRoot: environment.cacheRoot, calendar: range.calendar)
        let restoredRows = try #require(restored.files.values.first?.codexRows)
        #expect(restoredRows.count == 2)

        let emptyCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("{}".utf8))
        let report = CostUsageScanner.buildCodexReportFromCache(
            cache: restored, range: range, modelsDevCatalog: emptyCatalog)
        #expect(report.data.first?.costUSD != nil)
        #expect(report.summary?.totalCostUSD != nil)
    }

    @Test
    func `repaired rows persist even when the unchanged-content shortcut applies`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 9, day: 13)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let path = environment.codexSessionsRoot.appendingPathComponent("session.jsonl").path
        let persisted = [
            self.row(day: range.sinceKey, eventIndex: 0, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: range.sinceKey, eventIndex: 4, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: range.sinceKey, eventIndex: 1, timestampUnixMs: 2000, input: 1000, cached: 800, output: 100),
            self.row(day: range.sinceKey, eventIndex: 7, timestampUnixMs: 2000, input: 1000, cached: 800, output: 100),
        ]
        var cache = Self.dedupSeedCache(
            path: path,
            rows: persisted,
            days: [range.sinceKey: ["gpt-6-astra": [1500, 1200, 150]]],
            range: range)
        _ = CostUsageStoreAccess.replace(cacheRoot: environment.cacheRoot, cache: cache, calendar: range.calendar)

        let loaded = CostUsageStoreAccess.load(cacheRoot: environment.cacheRoot, calendar: range.calendar)
        defer { loaded.release() }
        #expect(loaded.cache.files[path]?.codexRows?.count == 2)

        // Without repair tracking the healed cache compares equal to the decoded baseline and
        // the save is skipped, leaving the duplicated persisted rows in place forever.
        cache = loaded.cache
        _ = CostUsageStoreAccess.save(
            store: loaded.store,
            cache: cache,
            calendar: range.calendar,
            requestedScanWindow: (sinceKey: range.sinceKey, untilKey: range.untilKey),
            skipIdenticalContent: true,
            receipt: loaded.receipt)

        let stored = await loaded.store.fetchUsageRows(path: path)
        #expect(stored.count == 2)
    }

    @Test
    func `rows appended after a repair survive save and reload`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 9, day: 13)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)
        let path = environment.codexSessionsRoot.appendingPathComponent("session.jsonl").path
        let persisted = [
            self.row(day: range.sinceKey, eventIndex: 0, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: range.sinceKey, eventIndex: 4, timestampUnixMs: 1000, input: 500, cached: 400, output: 50),
            self.row(day: range.sinceKey, eventIndex: 1, timestampUnixMs: 2000, input: 1000, cached: 800, output: 100),
            self.row(day: range.sinceKey, eventIndex: 7, timestampUnixMs: 2000, input: 1000, cached: 800, output: 100),
        ]
        let cache = Self.dedupSeedCache(
            path: path,
            rows: persisted,
            days: [range.sinceKey: ["gpt-6-astra": [1500, 1200, 150]]],
            range: range)
        _ = CostUsageStoreAccess.replace(cacheRoot: environment.cacheRoot, cache: cache, calendar: range.calendar)

        let loaded = CostUsageStoreAccess.load(cacheRoot: environment.cacheRoot, calendar: range.calendar)
        defer { loaded.release() }
        var usage = try #require(loaded.cache.files[path])
        #expect(usage.codexRows?.count == 2)

        // Simulate an incremental scan: the file grew and two distinct new events arrived.
        // Without repair tracking the persistence planner would still see the pre-repair row
        // count (4) and choose .append(startingAt: 4), silently dropping both new rows.
        var rows = usage.codexRows ?? []
        rows.append(self.row(
            day: range.sinceKey, eventIndex: 2, timestampUnixMs: 3000, input: 300, cached: 200, output: 30))
        rows.append(self.row(
            day: range.sinceKey, eventIndex: 3, timestampUnixMs: 4000, input: 200, cached: 100, output: 20))
        usage.codexRows = rows
        usage.days = [range.sinceKey: ["gpt-6-astra": [2000, 1500, 200]]]
        usage.parsedBytes = (usage.parsedBytes ?? 0) + 50
        usage.size += 50
        var appended = loaded.cache
        appended.files[path] = usage
        appended.days = usage.days
        _ = CostUsageStoreAccess.save(
            store: loaded.store,
            cache: appended,
            calendar: range.calendar,
            requestedScanWindow: (sinceKey: range.sinceKey, untilKey: range.untilKey),
            skipIdenticalContent: true,
            receipt: loaded.receipt)

        let stored = await loaded.store.fetchUsageRows(path: path)
        #expect(stored.count == 4)

        let reread = CostUsageStoreAccess.read(cacheRoot: environment.cacheRoot, calendar: range.calendar)
        let rereadRows = try #require(reread.files[path]?.codexRows)
        #expect(Set(rereadRows.compactMap(\.timestampUnixMs)) == [1000, 2000, 3000, 4000])
    }

    private static func dedupSeedCache(
        path: String,
        rows: [CostUsageScanner.CodexUsageRow],
        days: [String: [String: [Int]]],
        range: CostUsageScanner.CostUsageDayRange) -> CostUsageCache
    {
        let usage = CostUsageScanner.makeFileUsage(
            mtimeUnixMs: 1,
            size: 1,
            days: days,
            parsedBytes: 1,
            codexRows: rows,
            codexScanComplete: true)
        var cache = CostUsageCache()
        cache.files[path] = usage
        cache.days = days
        cache.scanSinceKey = range.sinceKey
        cache.scanUntilKey = range.untilKey
        cache.timeZoneIdentifier = range.calendar.timeZone.identifier
        return cache
    }
}
