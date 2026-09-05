import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageStoreCutoverTests {
    @Test
    func `legacy artifact cleanup deletes JSON and rebuilds SQLite from source`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 8)
        let timestamp = env.isoString(for: day)
        _ = try env.writeCodexSessionFile(
            day: day,
            filename: "current.jsonl",
            contents: Self.session(timestamp: timestamp, sessionID: "current", input: 7))

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.upsertFile(Self.staleStoreFile()))
        let directory = store.databaseURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let legacy = directory.appendingPathComponent("codex-v11.json")
        let temporary = directory.appendingPathComponent(".codex-v11.json.fixture.tmp")
        try Data("legacy".utf8).write(to: legacy)
        try Data("temporary".utf8).write(to: temporary)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        #expect(report.summary?.totalInputTokens == 7)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: temporary.path))
        #expect(FileManager.default.fileExists(atPath: store.databaseURL.path))
        let snapshot = await CostUsageStore(cacheRoot: env.cacheRoot).readSnapshot()
        #expect(snapshot.files.map(\.path).contains("/stale.jsonl") == false)
        #expect(snapshot.files.contains { $0.path.hasSuffix("current.jsonl") })
    }

    @Test
    func `fixture report remains identical through the store`() throws {
        let fixture = try Issue2037FixtureHarness.load(named: "archived-fork-33ce-3869")
        let sanitized = try SanitizedForkFamilyFixture.load(named: "archived-fork-33ce-3869")
        let prefixLength = try #require(sanitized.manifest.copiedPrefixes.first).length
        let expectedUnits = try sanitized.events(named: "parent").map(\.last.scannerUnits).reduce(0, +)
            + sanitized.events(named: "child").dropFirst(prefixLength).map(\.last.scannerUnits).reduce(0, +)
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        try Issue2037FixtureHarness.install(fixture, into: env)

        let since = try env.makeLocalNoon(year: 2030, month: 1, day: 1)
        let until = try env.makeLocalNoon(year: 2030, month: 1, day: 2)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        let scanned = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: since,
            until: until,
            now: until,
            options: options)
        let range = CostUsageScanner.CostUsageDayRange(
            since: since,
            until: until,
            calendar: options.calendar)
        let stored = CostUsageScanner.buildCodexReportFromCache(
            cache: CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: options.calendar),
            range: range,
            modelsDevCacheRoot: env.cacheRoot)
        let storedUnits = stored.data.reduce(0) {
            $0 + ($1.inputTokens ?? 0) + ($1.cacheReadTokens ?? 0) + ($1.outputTokens ?? 0)
        }

        #expect(stored.data == scanned.data)
        #expect(stored.summary == scanned.summary)
        #expect(storedUnits == expectedUnits)
    }

    @Test
    func `one appended row does one row of work and stable EOF does none`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 8)
        let timestamp = env.isoString(for: day)
        let prefixCount = 4096
        let prefix = Self.session(timestamp: timestamp, sessionID: "linear", input: 1)
            + (2...prefixCount).map { Self.tokenLine(timestamp: timestamp, input: $0) + "\n" }.joined()
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "linear.jsonl",
            contents: prefix)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day,
            options: options)

        try Self.append(Self.tokenLine(timestamp: timestamp, input: prefixCount + 1) + "\n", to: fileURL)
        let appendRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = appendRecorder
        let appended = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(1),
            options: options)
        #expect(appendRecorder.snapshot().usageRowsProcessed == 1)
        #expect(appendRecorder.snapshot().usageRowsRepriced == 1)
        #expect(appendRecorder.snapshot().tokenTimestampComparisons == 1)
        #expect(appended.summary?.totalInputTokens == prefixCount + 1)

        let cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot)
        let path = try #require(cache.files.keys.first { $0.hasSuffix("linear.jsonl") })
        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.fetchUsageRows(path: path).count == prefixCount + 1)
        #expect(await store.fetchAccumulator(path: path)?.eventCount == prefixCount + 1)

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = stableRecorder
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(stableRecorder.snapshot().usageRowsProcessed == 0)
        #expect(stableRecorder.snapshot().usageRowsRepriced == 0)
        #expect(stableRecorder.snapshot().tokenTimestampComparisons == 0)
        #expect(cache.files[path]?.codexTokenTimestampsMonotonic == true)
        #expect(stable.data == appended.data)
        #expect(stable.summary == appended.summary)
    }

    @Test(arguments: ["unknown", "false", "true"])
    func `reopened append preserves saved timestamp order state and checkpoints`(_ state: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 8, day: 8)
        let timestamp = env.isoString(for: day)
        let file = try env.writeCodexSessionFile(
            day: day,
            filename: "reopened.jsonl",
            contents: Self.session(timestamp: timestamp, sessionID: "reopened", input: 1)
                + Self.tokenLine(timestamp: timestamp, input: 2) + "\n")
        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot, cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        _ = CostUsageScanner.loadDailyReport(provider: .codex, since: day, until: day, now: day, options: options)
        var cache = CostUsageStoreAccess.read(cacheRoot: env.cacheRoot, calendar: options.calendar)
        let path = try #require(cache.files.keys.first { $0.hasSuffix("reopened.jsonl") })
        let prefixCheckpoints = try #require(cache.files[path]?.codexTokenCheckpoints)
        #expect(prefixCheckpoints.last?.state.countedTotals?.input == 2)
        cache.files[path]?.codexTokenTimestampsMonotonic = state == "unknown" ? nil : state == "true"
        let key = CostUsageScanner.CostUsageDayRange.dayKey(from: day, calendar: options.calendar)
        _ = CostUsageStore(cacheRoot: env.cacheRoot).syncSaveCodexCache(
            cache, calendar: options.calendar, requestedScanWindow: (key, key))
        let reopened = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: options.calendar)
        #expect(reopened.files[path]?.codexTokenTimestampsMonotonic == cache.files[path]?.codexTokenTimestampsMonotonic)
        try Self.append(Self.tokenLine(timestamp: timestamp, input: 3) + "\n", to: file)
        let recorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = recorder
        let report = CostUsageScanner.loadDailyReport(
            provider: .codex, since: day, until: day, now: day.addingTimeInterval(1), options: options)
        #expect(report.summary?.totalInputTokens == 3)
        #expect(recorder.snapshot().tokenTimestampComparisons == (state == "unknown" ? 2 : state == "true" ? 1 : 0))
        let final = CostUsageStore(cacheRoot: env.cacheRoot).syncLoadCodexCache(calendar: options.calendar)
        let usage = try #require(final.files[path])
        #expect(usage.codexTokenTimestampsMonotonic == (state != "false"))
        #expect(usage.codexTokenSnapshots?.count == 3)
        #expect(usage.codexTokenCheckpoints?.last?.endOffset == usage.parsedBytes)
        #expect(usage.codexTokenCheckpoints?.last?.eventIndex == 2)
        #expect(usage.codexTokenCheckpoints?.last?.state.countedTotals?.input == 3)
    }

    private static func staleStoreFile() -> CostUsageStoreFile {
        CostUsageStoreFile(
            path: "/stale.jsonl",
            inode: 1,
            mtimeUnixMs: 1,
            size: 1,
            parsedBytes: 1,
            anchor: nil,
            scanState: CostUsageStoreScanState(
                targetSize: 1,
                isComplete: true,
                resumePayload: nil,
                tokenTimestampsMonotonic: true,
                nextUsageRowIndex: 0,
                lastModel: nil,
                lastTurnID: nil,
                fileIdentity: "1:1",
                detailsPayload: Data()),
            sessionID: "stale",
            coverageSinceDay: "2020-01-01",
            coverageUntilDay: "2020-01-01",
            updatedAtUnixMs: 1)
    }

    private static func session(timestamp: String, sessionID: String, input: Int) -> String {
        [
            #"{"type":"session_meta","timestamp":"\#(timestamp)","payload":{"session_id":"\#(sessionID)"}}"#,
            #"{"type":"turn_context","timestamp":"\#(timestamp)","payload":{"model":"openai/gpt-5.4"}}"#,
            self.tokenLine(timestamp: timestamp, input: input),
        ].joined(separator: "\n") + "\n"
    }

    private static func tokenLine(timestamp: String, input: Int) -> String {
        #"{"type":"event_msg","timestamp":"\#(timestamp)","payload":{"#
            + #""type":"token_count","info":{"total_token_usage":{"input_tokens":"#
            + "\(input)"
            + #", "cached_input_tokens":0,"output_tokens":0},"model":"openai/gpt-5.4"}}}"#
    }

    private static func append(_ contents: String, to fileURL: URL) throws {
        let handle = try FileHandle(forWritingTo: fileURL)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(contents.utf8))
    }
}
