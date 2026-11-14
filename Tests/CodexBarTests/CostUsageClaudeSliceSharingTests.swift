import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageClaudeSliceSharingTests {
    @Test
    func `different requested windows publish one identical exact slice buffer`() throws {
        let fixture = try CostUsageClaudeWriteAmplificationTests.Fixture(rowCount: 4096)
        defer { fixture.env.cleanup() }
        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [fixture.env.claudeProjectsRoot], cacheRoot: fixture.env.cacheRoot)
        options.refreshMinIntervalSeconds = 0
        func load(_ context: CostUsageReportContext) throws -> ClaudeReportProjections {
            try CostUsageScanner.loadClaudeReportProjectionsCancellable(
                since: fixture.day.addingTimeInterval(context == .regular ? -364 * 86400 : -730 * 86400),
                until: fixture.day,
                now: fixture.day,
                options: options,
                reportContext: context,
                checkCancellation: nil)
        }
        let regularProjections = try load(.regular)
        let historyProjections = try load(.spendDashboard)
        let regular = regularProjections.daily
        let history = historyProjections.daily
        #expect(regularProjections.sessions.map(\.sessionID) == ["session"])
        #expect(historyProjections.sessions.map(\.sessionID) == ["session"])
        #expect(regularProjections.projects.map(\.totalTokens) == [4096 * 15])
        #expect(historyProjections.projects.map(\.totalTokens) == [4096 * 15])
        #expect(regular.quotaSlices.count == 4096)
        #expect(history.quotaSlices == regular.quotaSlices)
        let sharesPublishedBuffer = Self.sharesBuffer(regular.quotaSlices, history.quotaSlices)
        #expect(sharesPublishedBuffer)
        let buffers = sharesPublishedBuffer ? 1 : 2
        #expect(buffers * regular.quotaSlices.count == 4096)
        #expect(history.data == regular.data)
        #expect(history.hourly == regular.hourly)
        #expect(try load(.regular).daily.quotaSlices == regular.quotaSlices)
        #expect(try load(.spendDashboard).daily.quotaSlices == history.quotaSlices)
    }

    @Test
    func `persisted headers release duplicate arrays while unchanged saves reuse fragments`() throws {
        let fixture = try CostUsageClaudeWriteAmplificationTests.Fixture(rowCount: 128)
        defer { fixture.env.cleanup() }
        // Both windows contain every event; their distinct keys must survive storage sharing.
        _ = try fixture.load(context: .regular)
        _ = try fixture.load(context: .spendDashboard)
        let paths = [CostUsageReportContext.regular, .spendDashboard].map {
            fixture.cacheURL(context: $0).standardizedFileURL.resolvingSymlinksInPath().path
        }
        for path in paths {
            CostUsageClaudeFragments.shared.evict(at: CostUsageClaudeReportMemo.reportMemoFileURL(
                cacheFileURL: URL(fileURLWithPath: path)))
        }
        let memo = CostUsageClaudeReportMemo()
        let first = try #require(memo.entry(provider: .claude, canonicalCachePath: paths[0]))
        let second = try #require(memo.entry(provider: .claude, canonicalCachePath: paths[1]))
        let sharesPersistedBuffer = Self.sharesBuffer(first.report.quotaSlices, second.report.quotaSlices)
        #expect(sharesPersistedBuffer)
        #expect(first.reportKey != second.reportKey)
        #expect(CostUsageClaudeFragments.shared.retainedDecodedHeaderCountForTesting == 0)
        let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
        CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) {
            for (path, entry) in zip(paths, [first, second]) {
                memo.store(
                    provider: .claude,
                    canonicalCachePath: path,
                    sourceInventory: entry.sourceInventory,
                    reportKey: entry.reportKey,
                    report: entry.report,
                    hasWindowScopedRows: entry.hasWindowScopedRows)
            }
        }
        #expect(recorder.persistenceSnapshot().reads == 0)
        #expect(recorder.persistenceSnapshot().writes == 0)
    }

    @Test(arguments: ["window", "scan", "provider", "filter", "root", "zone", "inventory", "pricing", "value", "bits"])
    func `shared storage retains window certificates and rejects different source evidence`(difference: String) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let memo = CostUsageClaudeReportMemo()
        let time = Date(timeIntervalSince1970: 1_780_000_000)
        func key(changed: Bool) -> CostUsageClaudeReportMemoKey {
            CostUsageClaudeReportMemoKey(
                provider: changed && difference == "provider" ? .vertexai : .claude,
                providerFilter: changed && difference == "filter" ? "other" : "fixture",
                sinceKey: changed && difference == "window" ? "2026-02-01" : "2026-01-01",
                untilKey: "2026-06-01",
                scanSinceKey: changed && difference == "scan" ? "2026-02-01" : "2026-01-01",
                scanUntilKey: "2026-06-01",
                timeZoneIdentifier: changed && difference == "zone" ? "Europe/Rome" : "UTC",
                roots: [env.root.appendingPathComponent(changed && difference == "root" ? "other" : "source").path],
                cacheArtifactStamp: nil,
                pricingArtifactStamp: changed && difference == "pricing"
                    ? CostUsageClaudeFileStamp(fileID: "changed", size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0)
                    : nil)
        }
        let first = CostUsageDailyReport(data: [], summary: nil, quotaSlices: [
            .init(timestamp: time, totalTokens: 1, costUSD: 0.0),
        ])
        let second = CostUsageDailyReport(data: [], summary: nil, quotaSlices: [
            .init(
                timestamp: time,
                totalTokens: difference == "value" ? 2 : 1,
                costUSD: difference == "bits" ? -0.0 : 0.0),
        ])
        let firstPath = env.root.appendingPathComponent("first.json").path
        let secondPath = env.root.appendingPathComponent("second.json").path
        memo.store(
            provider: .claude,
            canonicalCachePath: firstPath,
            sourceInventory: [:],
            reportKey: key(changed: false),
            report: first)
        let inventory = difference == "inventory"
            ? ["source": CostUsageClaudeFileStamp(fileID: "new", size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0)]
            : [:]
        let provider: UsageProvider = difference == "provider" ? .vertexai : .claude
        memo.store(
            provider: provider,
            canonicalCachePath: secondPath,
            sourceInventory: inventory,
            reportKey: key(changed: true),
            report: second)
        let retained = try #require(memo.entry(provider: provider, canonicalCachePath: secondPath))
        let sharesRetainedBuffer = Self.sharesBuffer(first.quotaSlices, retained.report.quotaSlices)
        #expect(sharesRetainedBuffer == (difference == "window" || difference == "scan"))
        #expect(retained.reportKey == key(changed: true))
        #expect(retained.report.quotaSlices == second.quotaSlices)
        #expect(retained.report.quotaSlices[0].costUSD?.bitPattern == second.quotaSlices[0].costUSD?.bitPattern)
    }

    private static func sharesBuffer(_ lhs: [CostUsageTimedEntry], _ rhs: [CostUsageTimedEntry]) -> Bool {
        lhs.withUnsafeBufferPointer { left in
            rhs.withUnsafeBufferPointer { left.baseAddress == $0.baseAddress }
        }
    }
}
