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
    func `missing parent siblings bill shared prefix only once`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "missing-parent-siblings")
        let scannerOracle = try #require(fixture.manifest.scannerOracle)

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
        for day in report.data {
            scannedUnits += day.inputTokens ?? 0
            scannedUnits += day.cacheReadTokens ?? 0
            scannedUnits += day.outputTokens ?? 0
        }

        #expect(!report.data.isEmpty)
        #expect(scannerOracle.naiveScannerUnits > scannerOracle.dedupedScannerUnits)
        #expect(
            scannedUnits == scannerOracle.dedupedScannerUnits,
            """
            scanned=\(scannedUnits) expectedDeduped=\(scannerOracle.dedupedScannerUnits) \
            naive=\(scannerOracle.naiveScannerUnits)
            """)
    }

    /// Billing suppression must advance counted baselines (state) while omitting rows (billing).
    /// Rolling `previousTotals` back after `commitDelta` falsely marks divergent totals and can
    /// re-include suppressed growth on later events.
    @Test
    func `billing suppression keeps counted baseline advanced without emitting`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2030, month: 6, day: 1)
        let iso = env.isoString(for: day)
        func tokenLine(lastIn: Int, lastOut: Int, totalIn: Int, totalOut: Int) -> String {
            let last =
                "{\"input_tokens\":\(lastIn),\"cached_input_tokens\":0,\"output_tokens\":\(lastOut),"
                    + "\"reasoning_output_tokens\":0,\"total_tokens\":\(lastIn + lastOut)}"
            let total =
                "{\"input_tokens\":\(totalIn),\"cached_input_tokens\":0,\"output_tokens\":\(totalOut),"
                    + "\"reasoning_output_tokens\":0,\"total_tokens\":\(totalIn + totalOut)}"
            return "{\"type\":\"event_msg\",\"timestamp\":\"\(iso)\",\"payload\":{"
                + "\"type\":\"token_count\",\"info\":{\"last_token_usage\":\(last),"
                + "\"total_token_usage\":\(total)}}}"
        }
        let contents = [
            "{\"type\":\"session_meta\",\"timestamp\":\"\(iso)\",\"payload\":{"
                + "\"id\":\"suppress-session\",\"timestamp\":\"\(iso)\"}}",
            "{\"type\":\"turn_context\",\"timestamp\":\"\(iso)\",\"payload\":{\"model\":\"fixture-model\"}}",
            tokenLine(lastIn: 10, lastOut: 1, totalIn: 10, totalOut: 1),
            tokenLine(lastIn: 20, lastOut: 2, totalIn: 30, totalOut: 3),
            tokenLine(lastIn: 40, lastOut: 4, totalIn: 70, totalOut: 7),
        ].joined(separator: "\n") + "\n"
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "suppress.jsonl", contents: contents)
        let range = CostUsageScanner.CostUsageDayRange(since: day, until: day)

        let parsed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: fileURL,
            range: range,
            billingSuppressedTokenOrdinals: [0, 1])

        let billedInput = parsed.rows.map(\.input).reduce(0, +)
        let billedOutput = parsed.rows.map(\.output).reduce(0, +)
        #expect(parsed.rows.count == 1)
        #expect(billedInput == 40)
        #expect(billedOutput == 4)
        #expect(parsed.lastCountedTotals?.input == 70)
        #expect(parsed.lastCountedTotals?.output == 7)
        #expect(parsed.hasDivergentTotals == false)
    }

    @Test
    func `token usage fingerprints skip truncated lines like the scan parser`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2030, month: 6, day: 2)
        let iso = env.isoString(for: day)
        let padding = String(repeating: "x", count: 300_000)
        let oversized =
            "{\"type\":\"event_msg\",\"timestamp\":\"\(iso)\",\"payload\":{"
                + "\"type\":\"token_count\",\"info\":{\"note\":\"\(padding)\","
                + "\"last_token_usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":0},"
                + "\"total_token_usage\":{\"input_tokens\":1,\"cached_input_tokens\":0,\"output_tokens\":0}}}}"
        let normal =
            "{\"type\":\"event_msg\",\"timestamp\":\"\(iso)\",\"payload\":{"
                + "\"type\":\"token_count\",\"info\":{"
                + "\"last_token_usage\":{\"input_tokens\":5,\"cached_input_tokens\":0,\"output_tokens\":1},"
                + "\"total_token_usage\":{\"input_tokens\":5,\"cached_input_tokens\":0,\"output_tokens\":1}}}}"
        let contents = [
            "{\"type\":\"session_meta\",\"timestamp\":\"\(iso)\",\"payload\":{"
                + "\"id\":\"fp-session\",\"timestamp\":\"\(iso)\"}}",
            "{\"type\":\"turn_context\",\"timestamp\":\"\(iso)\",\"payload\":{\"model\":\"fixture-model\"}}",
            oversized,
            normal,
        ].joined(separator: "\n") + "\n"
        let fileURL = try env.writeCodexSessionFile(day: day, filename: "fingerprints.jsonl", contents: contents)

        let fingerprints = try CostUsageScanner.parseCodexTokenUsageFingerprints(fileURL: fileURL)
        let parsed = try CostUsageScanner.parseCodexFileCancellable(
            fileURL: fileURL,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day))

        #expect(fingerprints.count == 1)
        #expect(parsed.rows.count == 1)
        #expect(fingerprints.count == parsed.rows.count)
    }

    @Test
    func `missing parent fingerprint pre scan honors cancellation`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "missing-parent-siblings")
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

        var checks = 0
        let checkCancellation: CostUsageScanner.CancellationCheck = {
            checks += 1
            if checks >= 2 {
                throw CancellationError()
            }
        }

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadDailyReportCancellable(
                provider: .codex,
                since: since,
                until: until,
                now: until,
                options: options,
                checkCancellation: checkCancellation)
        }
        #expect(checks >= 2)
    }

    @Test
    func `missing parent suppressions rescan cached siblings when family grows`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "missing-parent-siblings")
        let scannerOracle = try #require(fixture.manifest.scannerOracle)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let siblingB = fixture.manifest.files.first { $0.alias == "sibling-b" }
        let siblingBFile = try #require(siblingB)
        let siblingBSource = fixture.root.appendingPathComponent(siblingBFile.relativePath, isDirectory: false)
        let siblingBDestination = env.root.appendingPathComponent(siblingBFile.relativePath, isDirectory: false)
        try FileManager.default.createDirectory(
            at: siblingBDestination.deletingLastPathComponent(),
            withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: siblingBSource, to: siblingBDestination)

        let since = try env.makeLocalNoon(year: 2030, month: 1, day: 1)
        let until = try env.makeLocalNoon(year: 2030, month: 1, day: 2)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0

        // Warm the cache with only the non-owner sibling.
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options)

        // Introduce the earlier owner sibling without forceRescan.
        try Issue2037FixtureHarness.install(fixture, into: env)
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options)

        var scannedUnits = 0
        for day in report.data {
            scannedUnits += day.inputTokens ?? 0
            scannedUnits += day.cacheReadTokens ?? 0
            scannedUnits += day.outputTokens ?? 0
        }

        #expect(
            scannedUnits == scannerOracle.dedupedScannerUnits,
            """
            scanned=\(scannedUnits) expectedDeduped=\(scannerOracle.dedupedScannerUnits) \
            naive=\(scannerOracle.naiveScannerUnits)
            """)
    }
}
