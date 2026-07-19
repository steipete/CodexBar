import Foundation
import Testing
@testable import CodexBarCore

struct Issue2037ScannerIntegrationTests {
    /// Locks that `#1164` inherited-totals accounting matches parent-owns-prefix
    /// scanner units for the sanitized ordinary fork family when the parent file
    /// is present in the scan window. Missing-parent / interleaved Ultra shapes
    /// need separate goldens.
    @Test
    func `archived fork family scanner matches parent-owns-prefix oracle`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "archived-fork-33ce-3869")
        let sanitized = try SanitizedForkFamilyFixture.load(named: "archived-fork-33ce-3869")
        let oracle = sanitized.manifest.oracle
        let prefixLength = try #require(sanitized.manifest.copiedPrefixes.first).length

        let parentEvents = try sanitized.events(named: "parent")
        let childEvents = try sanitized.events(named: "child")
        let expectedScannerUnits = parentEvents.map(\.last.scannerUnits).reduce(0, +)
            + childEvents.dropFirst(prefixLength).map(\.last.scannerUnits).reduce(0, +)
        let naiveScannerUnits = parentEvents.map(\.last.scannerUnits).reduce(0, +)
            + childEvents.map(\.last.scannerUnits).reduce(0, +)

        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        try Issue2037FixtureHarness.install(fixture, into: env)

        let since = try env.makeLocalNoon(year: 2030, month: 1, day: 1)
        let until = try env.makeLocalNoon(year: 2030, month: 1, day: 2)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options)

        var scannedUnits = 0
        var dayKeys: [String] = []
        for day in report.data {
            dayKeys.append(day.date)
            scannedUnits += day.inputTokens ?? 0
            scannedUnits += day.cacheReadTokens ?? 0
            scannedUnits += day.outputTokens ?? 0
        }

        #expect(!report.data.isEmpty)
        #expect(naiveScannerUnits > expectedScannerUnits)
        #expect(oracle.naiveLastTokens > oracle.dedupedLastTokens)
        #expect(
            scannedUnits == expectedScannerUnits,
            """
            scanned=\(scannedUnits) expectedDeduped=\(expectedScannerUnits) \
            naive=\(naiveScannerUnits) days=\(dayKeys)
            """)
    }

    /// Second parent-present golden from a local Sol/Terra-adjacent fork
    /// (`4d90→52bf`). Parent is truncated to the copied prefix so `#1164`
    /// inheritance has a clean resolved-fork baseline.
    ///
    /// Scanner units follow `total_token_usage` deltas (not `sum(last)`): this
    /// corpus has a flat-total row with non-zero `last` at parent ordinal 120.
    @Test
    func `live fork 4d90 family scanner matches parent-owns-prefix oracle`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "live-fork-4d90-52bf")
        let sanitized = try SanitizedForkFamilyFixture.load(named: "live-fork-4d90-52bf")
        let scannerOracle = try #require(fixture.manifest.scannerOracle)
        let prefixLength = try #require(sanitized.manifest.copiedPrefixes.first).length

        let parentEvents = try sanitized.events(named: "parent")
        let childEvents = try sanitized.events(named: "child")
        let parentTotalUnits = try #require(parentEvents.last).total.scannerUnits
        let prefixEndTotalUnits = try #require(childEvents.dropFirst(prefixLength - 1).first).total.scannerUnits
        let childEndTotalUnits = try #require(childEvents.last).total.scannerUnits
        let expectedScannerUnits = parentTotalUnits + max(0, childEndTotalUnits - prefixEndTotalUnits)

        #expect(parentTotalUnits == prefixEndTotalUnits)
        #expect(expectedScannerUnits == childEndTotalUnits)
        #expect(expectedScannerUnits == scannerOracle.dedupedScannerUnits)
        #expect(scannerOracle.naiveScannerUnits > scannerOracle.dedupedScannerUnits)
        // Corpus anomaly: sum(last) overcounts vs total-delta scanner units.
        #expect(parentEvents.map(\.last.scannerUnits).reduce(0, +) > parentTotalUnits)

        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        try Issue2037FixtureHarness.install(fixture, into: env)

        let since = try env.makeLocalNoon(year: 2030, month: 1, day: 1)
        let until = try env.makeLocalNoon(year: 2030, month: 1, day: 2)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0

        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options)

        var scannedUnits = 0
        var dayKeys: [String] = []
        for day in report.data {
            dayKeys.append(day.date)
            scannedUnits += day.inputTokens ?? 0
            scannedUnits += day.cacheReadTokens ?? 0
            scannedUnits += day.outputTokens ?? 0
        }

        #expect(!report.data.isEmpty)
        #expect(
            scannedUnits == scannerOracle.dedupedScannerUnits,
            """
            scanned=\(scannedUnits) expectedDeduped=\(scannerOracle.dedupedScannerUnits) \
            naive=\(scannerOracle.naiveScannerUnits) days=\(dayKeys)
            """)
    }

    @Test
    func `missing parent equal counter siblings fail open`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2030, month: 7, day: 1)
        let firstTimestamp = env.isoString(for: day)
        let secondTimestamp = env.isoString(for: day.addingTimeInterval(3600))

        func siblingContents(id: String, model: String, timestamp: String) -> String {
            let metadata = "{\"type\":\"session_meta\",\"timestamp\":\"\(timestamp)\",\"payload\":{"
                + "\"id\":\"\(id)\",\"forked_from_id\":\"missing-parent\","
                + "\"timestamp\":\"\(timestamp)\"}}"
            let context = "{\"type\":\"turn_context\",\"timestamp\":\"\(timestamp)\","
                + "\"payload\":{\"model\":\"\(model)\"}}"
            let first = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{"
                + "\"type\":\"token_count\",\"info\":{"
                + "\"last_token_usage\":{\"input_tokens\":10,\"cached_input_tokens\":0,"
                + "\"output_tokens\":0},\"total_token_usage\":{\"input_tokens\":10,"
                + "\"cached_input_tokens\":0,\"output_tokens\":0}}}}"
            let second = "{\"type\":\"event_msg\",\"timestamp\":\"\(timestamp)\",\"payload\":{"
                + "\"type\":\"token_count\",\"info\":{"
                + "\"last_token_usage\":{\"input_tokens\":5,\"cached_input_tokens\":0,"
                + "\"output_tokens\":0},\"total_token_usage\":{\"input_tokens\":15,"
                + "\"cached_input_tokens\":0,\"output_tokens\":0}}}}"
            return [metadata, context, first, second].joined(separator: "\n") + "\n"
        }

        _ = try env.writeCodexArchivedSessionFile(
            filename: "sibling-a.jsonl",
            contents: siblingContents(id: "sibling-a", model: "fixture-model-a", timestamp: firstTimestamp))
        _ = try env.writeCodexArchivedSessionFile(
            filename: "sibling-b.jsonl",
            contents: siblingContents(id: "sibling-b", model: "fixture-model-b", timestamp: secondTimestamp))

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.forceRescan = true
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)
        let scannedUnits = report.data.reduce(0) { partial, row in
            partial + (row.inputTokens ?? 0) + (row.cacheReadTokens ?? 0) + (row.outputTokens ?? 0)
        }

        // Each unresolved child skips its first cumulative snapshot, then independently bills
        // five input tokens. Equal token vectors are not sufficient cross-file identity.
        #expect(scannedUnits == 10)
    }
}
