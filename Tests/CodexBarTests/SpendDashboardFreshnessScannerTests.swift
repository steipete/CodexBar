import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct SpendDashboardFreshnessScannerTests {
    @Test
    func `JSONL append and midnight update shared spend without losing older history`() async throws {
        let fixture = try SpendDashboardFreshnessFixture()
        defer { fixture.cleanup() }
        let scanner = try ClaudeSpendScannerFixture(env: fixture.env)
        let oldDay = try #require(ISO8601DateFormatter().date(from: "2026-01-01T12:00:00Z"))
        let recentDay = try #require(ISO8601DateFormatter().date(from: "2026-07-15T12:00:00Z"))
        scanner.now = recentDay
        try scanner.append(day: oldDay, id: "old", input: 100)
        try scanner.append(day: recentDay, id: "recent", input: 20)
        fixture.store._test_tokenUsageSnapshotLoaderOverride = { provider, _, _, _, days in
            #expect(provider == .claude)
            fixture.requests.append(days)
            // Count requests separately: changing between 30 and 365 days can legitimately reparse a transcript.
            return try await scanner.load(days: days)
        }
        await fixture.store.refreshSpendDashboardTokenUsageNow(for: .claude, force: true)
        fixture.store.startSharedSpendDashboardPublication()
        try await fixture.waitForSharedCost(0.0012)
        let seeded = try #require(fixture.store.spendDashboardPublication.inputs.first?.snapshot)
        #expect(seeded.daily.compactMap(\.totalTokens).reduce(0, +) == 120)
        #expect(seeded.daily.first?.date == "2026-01-01")

        try scanner.append(day: recentDay, id: "appended", input: 30)
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        try await fixture.waitForSharedCost(0.0015)
        #expect(fixture.requests == [365, 30, 365])
        try Self.expectShared(fixture, tokens: [100, 50], costs: [0.001, 0.0005], now: recentDay)
        #expect(fixture.store.tokenSnapshot(for: .claude)?.daily.map(\.date) == ["2026-07-15"])
        #expect(fixture.store.tokenSnapshot(for: .claude)?.historyDays == 30)

        // Claude persists JSON. Evict its memo and prove a cold read reuses that file without parsing transcripts.
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        #expect(FileManager.default.fileExists(atPath: cacheURL.path))
        CostUsageScanner.evictClaudeReportMemoForTesting(provider: .claude, cacheRoot: fixture.env.cacheRoot)
        let beforeCold = scanner.recorder.snapshot()
        let cold = try await scanner.load(days: 365)
        #expect(cold.daily == fixture.store.spendDashboardPublication.inputs.first?.snapshot.daily)
        #expect(scanner.recorder.snapshot().cacheDecodes == beforeCold.cacheDecodes + 1)
        #expect(scanner.recorder.snapshot().transcriptParses == beforeCold.transcriptParses)

        let tomorrow = try #require(ISO8601DateFormatter().date(from: "2026-07-16T00:01:00Z"))
        scanner.now = tomorrow
        try scanner.append(day: tomorrow, id: "midnight", input: 40)
        let beforeRollover = fixture.store.spendDashboardPublication.revision
        fixture.store.sharedSpendDashboardController().refreshDateWindow(now: tomorrow)
        try await SpendDashboardFreshnessSignal.waitUntil {
            !fixture.store.spendDashboardPublication.isRefreshing &&
                fixture.store.spendDashboardPublication.revision > beforeRollover
        }
        #expect(fixture.requests == [365, 30, 365])
        await fixture.store.refreshTokenUsageNow(for: .claude, force: true)
        try await fixture.waitForSharedCost(0.0019)
        try Self.expectShared(fixture, tokens: [100, 50, 40], costs: [0.001, 0.0005, 0.0004], now: tomorrow)
        #expect(fixture.requests == [365, 30, 365, 30, 365])
        #expect(fixture.store.tokenSnapshot(for: .claude)?.sessionTokens == 40)
        #expect(fixture.store.tokenSnapshot(for: .claude)?.last30DaysTokens == 90)
        #expect(fixture.store.tokenSnapshot(for: .claude)?.historyDays == 30)
        #expect(scanner.recorder.snapshot().transcriptParses > 0)
        let beforeIdle = scanner.recorder.snapshot()
        for _ in 0..<3 {
            fixture.store.sharedSpendDashboardController().update(configuration: fixture.configuration)
            _ = await fixture.request()
        }
        #expect(fixture.requests == [365, 30, 365, 30, 365])
        #expect(scanner.recorder.snapshot() == beforeIdle)
    }

    private static func expectShared(
        _ fixture: SpendDashboardFreshnessFixture,
        tokens: [Int],
        costs: [Double],
        now: Date) throws
    {
        let publication = fixture.store.spendDashboardPublication
        let snapshot = try #require(publication.inputs.first?.snapshot)
        #expect(snapshot.historyDays == 365)
        #expect(snapshot.daily.compactMap(\.totalTokens) == tokens)
        #expect(snapshot.daily.count == costs.count)
        for (row, cost) in zip(snapshot.daily, costs) {
            #expect(abs((row.costUSD ?? -1) - cost) < 0.000000001)
        }
        #expect(snapshot.daily.first?.date == "2026-01-01")
        let model = publication.model(
            requestedDays: 365,
            now: now,
            calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"),
            preferredCurrencyCode: "USD")
        #expect(abs((model.groups.first?.totalCost ?? -1) - costs.reduce(0, +)) < 0.000000001)
    }
}

@MainActor
private final class ClaudeSpendScannerFixture {
    let env: CostUsageTestEnvironment
    let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
    var now = Date.distantPast

    init(env: CostUsageTestEnvironment) throws {
        self.env = env
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"anthropic":{"id":"anthropic","models":{"claude-test-dashboard":{
          "id":"claude-test-dashboard","cost":{"input":10,"output":1}
        }}}}
        """.utf8))
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: Date(), cacheRoot: env.cacheRoot))
    }

    func load(days: Int) async throws -> CostUsageTokenSnapshot {
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [self.env.claudeProjectsRoot],
            cacheRoot: self.env.cacheRoot,
            calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"))
        options.refreshMinIntervalSeconds = 0
        let scanOptions = options
        let now = self.now
        let recorder = self.recorder
        return try await CostUsageScanExecutor.run { checkCancellation in
            try CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
                // Match the fetcher's local Claude scan and projection, with only the temporary pricing catalog.
                // No pricing refresh, remote provider transport, or Pi source participates in this fixture.
                let since = scanOptions.calendar.date(byAdding: .day, value: -(days - 1), to: now)!
                let report = try CostUsageScanner.loadDailyReportCancellable(
                    provider: .claude,
                    since: since,
                    until: now,
                    now: now,
                    options: scanOptions,
                    checkCancellation: checkCancellation)
                return CostUsageFetcher.tokenSnapshot(
                    from: report, now: now, historyDays: days, calendar: scanOptions.calendar)
            }
        }
    }

    func append(day: Date, id: String, input: Int) throws {
        let row: [String: Any] = [
            "type": "assistant", "timestamp": self.env.isoString(for: day),
            "sessionId": "fixture-session", "requestId": "request-\(id)",
            "message": [
                "id": "message-\(id)",
                "model": "claude-test-dashboard",
                "usage": [
                    "input_tokens": input,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                ],
            ],
        ]
        let file = self.env.claudeProjectsRoot.appendingPathComponent("fixture.jsonl")
        if !FileManager.default.fileExists(atPath: file.path) {
            try Data().write(to: file)
        }
        let handle = try FileHandle(forWritingTo: file)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(self.env.jsonl([row]).utf8))
    }
}
