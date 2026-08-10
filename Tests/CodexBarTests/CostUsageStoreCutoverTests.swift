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
        let fileURL = try env.writeCodexSessionFile(
            day: day,
            filename: "linear.jsonl",
            contents: Self.session(timestamp: timestamp, sessionID: "linear", input: 1))
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

        let storedPath = try #require(CostUsageStoreAccess.read(cacheRoot: env.cacheRoot).files.keys.first {
            $0.hasSuffix("linear.jsonl")
        })
        let conversionCounter = StoreSnapshotConversionCounter()
        CostUsageStore.tokenSnapshotConversionForTesting = { path, _ in
            guard path == storedPath else { return }
            conversionCounter.increment()
        }
        defer { CostUsageStore.tokenSnapshotConversionForTesting = nil }

        try Self.append(Self.tokenLine(timestamp: timestamp, input: 2) + "\n", to: fileURL)
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
        #expect(conversionCounter.value == 1)

        let store = CostUsageStore(cacheRoot: env.cacheRoot)
        #expect(await store.fetchUsageRows(path: storedPath).count == 2)
        #expect(await store.fetchAccumulator(path: storedPath)?.eventCount == 2)

        let stableRecorder = CostUsageScanner.CodexScanWorkRecorder()
        options.codexScanWorkRecorderForTesting = stableRecorder
        conversionCounter.reset()
        let stable = CostUsageScanner.loadDailyReport(
            provider: .codex,
            since: day,
            until: day,
            now: day.addingTimeInterval(2),
            options: options)
        #expect(stableRecorder.snapshot().usageRowsProcessed == 0)
        #expect(stableRecorder.snapshot().usageRowsRepriced == 0)
        #expect(conversionCounter.value == 0)
        #expect(stable.data == appended.data)
        #expect(stable.summary == appended.summary)
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

private final class StoreSnapshotConversionCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    var value: Int {
        self.lock.withLock { self.count }
    }

    func increment() {
        self.lock.withLock { self.count += 1 }
    }

    func reset() {
        self.lock.withLock { self.count = 0 }
    }
}
