import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityLocalBreakdownsTests {
    private typealias Fixture = AntigravityLocalFixture

    @Test
    func `local report emits sorted hourly and quotaSlices and reconciles reset-split quota week exactly`()
        async throws
    {
        let fixture = try Fixture()
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(#"""
        {
            "google": {
                "id": "google",
                "name": "Google",
                "models": {
                    "gemini-fixture-a": {
                        "id": "gemini-fixture-a",
                        "cost": {"input": 1, "output": 2, "cache_read": 0.2}
                    }
                }
            }
        }
        """#.utf8))
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: Fixture.now, cacheRoot: cacheRoot))

        // Two turns on the same day separated by a weekly reset at 12:00 UTC, plus two turns at the exact same ms.
        let beforeResetSec: UInt64 = 1_787_824_800 // 2026-08-27 10:00:00 UTC
        let afterResetSec: UInt64 = 1_787_835_600 // 2026-08-27 13:00:00 UTC
        try fixture.database("session-split", blobs: [
            Fixture.blob(model: "gemini-fixture-a", seconds: beforeResetSec),
            Fixture.blob(model: "gemini-fixture-a", seconds: afterResetSec),
            Fixture.blob(model: "gemini-fixture-a", seconds: afterResetSec),
        ])

        let report = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: fixture.context,
            calendar: Fixture.calendar,
            estimateCost: true,
            pricingCacheRoot: cacheRoot)
        #expect(report.coverage == .complete)
        #expect(report.report.hourly.count == 2)
        #expect(report.report.quotaSlices.count == 2)
        #expect(report.report.quotaSlices[0].timestamp < report.report.quotaSlices[1].timestamp)
        #expect(report.report.quotaSlices[0].totalTokens == 187)
        #expect(report.report.quotaSlices[1].totalTokens == 374)
        #expect(report.report.quotaSlices.allSatisfy { $0.tokensAreComplete && $0.costIsComplete })

        let snapshot = try await fixture.snapshot()
        #expect(snapshot.hourly.count == 2)
        #expect(snapshot.quotaSlices.count == 2)
        #expect(snapshot.detailsAreComplete)

        let nextReset = Date(timeIntervalSince1970: 1_787_832_000 + 7 * 24 * 60 * 60)
        let weeks = snapshot.quotaWeekSummaries(
            resetAt: nextReset,
            weekCount: 2,
            calendar: Fixture.calendar)
        let currentWeek = try #require(weeks.first { $0.isCurrent })
        let priorWeek = try #require(weeks.first { $0.offset == 1 })
        #expect(currentWeek.tokensAreComplete)
        #expect(currentWeek.costIsComplete)
        #expect(currentWeek.totalTokens == 374)
        #expect(priorWeek.tokensAreComplete)
        #expect(priorWeek.costIsComplete)
        #expect(priorWeek.totalTokens == 187)
    }

    @Test
    func `windowedDailyReport filters and preserves hourly and quotaSlices`() {
        let now = Fixture.now
        let calendar = Fixture.calendar
        let inWindowDate = now.addingTimeInterval(-3600)
        let outOfWindowDate = now.addingTimeInterval(-40 * 24 * 3600)
        let inKey = CostUsageLocalDay.key(from: inWindowDate, calendar: calendar)
        let outKey = CostUsageLocalDay.key(from: outOfWindowDate, calendar: calendar)

        let report = CostUsageDailyReport(
            data: [
                .init(
                    date: outKey,
                    inputTokens: 10,
                    outputTokens: 5,
                    totalTokens: 15,
                    costUSD: 0.1,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
                .init(
                    date: inKey,
                    inputTokens: 20,
                    outputTokens: 10,
                    totalTokens: 30,
                    costUSD: 0.2,
                    modelsUsed: nil,
                    modelBreakdowns: nil),
            ],
            summary: nil,
            hourly: [
                CostUsageHourlyEntry(hour: outOfWindowDate, totalTokens: 15, costUSD: 0.1),
                CostUsageHourlyEntry(hour: inWindowDate, totalTokens: 30, costUSD: 0.2),
            ],
            quotaSlices: [
                CostUsageTimedEntry(timestamp: outOfWindowDate, totalTokens: 15, costUSD: 0.1),
                CostUsageTimedEntry(timestamp: inWindowDate, totalTokens: 30, costUSD: 0.2),
            ])

        let windowed = CostUsageFetcher.windowedDailyReport(report, historyDays: 30, now: now, calendar: calendar)
        #expect(windowed.data.map(\.date) == [inKey])
        #expect(windowed.hourly.map(\.hour) == [inWindowDate])
        #expect(windowed.quotaSlices.map(\.timestamp) == [inWindowDate])
    }

    @Test
    func `projects and sessions hydrate trajectory_metadata_blob and conversation_summaries in both grouping modes`()
        async throws
    {
        let fixture = try Fixture()
        let mainBlob = Fixture.trajectoryMetadataBlob(
            workspaces: [
                .init(
                    workspaceURI: "file:///Users/fixture/dev/my-repo",
                    gitRootURI: "file:///Users/fixture/dev/my-repo",
                    repoSlug: "owner/my-repo",
                    repoRemoteURL: "https://github.com/owner/my-repo.git",
                    branch: "main"),
            ],
            primaryWorkspaceURI: "file:///Users/fixture/dev/my-repo",
            projectID: "proj-1",
            opaqueField4Size: 65536)
        let worktreeBlob = Fixture.trajectoryMetadataBlob(
            workspaces: [
                .init(
                    workspaceURI: "file:///Users/fixture/.gemini/antigravity/worktrees/my-repo/wt-1",
                    gitRootURI: "file:///Users/fixture/.gemini/antigravity/worktrees/my-repo/wt-1",
                    repoSlug: "owner/my-repo",
                    repoRemoteURL: "https://github.com/owner/my-repo.git",
                    branch: "feat/wt"),
            ],
            parentCascadeID: "session-main",
            rootCascadeID: "session-main",
            primaryWorkspaceURI: "file:///Users/fixture/.gemini/antigravity/worktrees/my-repo/wt-1",
            projectID: "proj-1")

        try fixture.database(
            "session-main",
            rootIndex: 1,
            blobs: [Fixture.blob(input: 100, output: 30, cacheRead: 50, reasoning: 7, seconds: 1_787_832_000)],
            trajectoryMetadataBlob: mainBlob)
        try fixture.database(
            "session-wt",
            rootIndex: 1,
            blobs: [Fixture.blob(input: 200, output: 40, cacheRead: 60, reasoning: 10, seconds: 1_787_835_600)],
            trajectoryMetadataBlob: worktreeBlob)

        try fixture.conversationSummariesDatabase(
            rows: [
                .init(
                    conversationID: "session-main",
                    title: "Main Checkout Session",
                    workspaceURIsJSON: #"["file:///Users/fixture/dev/my-repo"]"#,
                    projectID: "proj-1",
                    parentConversationID: ""),
                .init(
                    conversationID: "session-wt",
                    title: "Worktree Feature Session",
                    workspaceURIsJSON: #"["file:///Users/fixture/.gemini/antigravity/worktrees/my-repo/wt-1"]"#,
                    projectID: "proj-1",
                    parentConversationID: "session-main"),
            ],
            walMode: true)

        let workspaceSnapshot = try await fixture.snapshot(scanOptions: AntigravityLocalScanOptions(
            projectGrouping: .workspace))
        #expect(workspaceSnapshot.detailsAreComplete)
        #expect(workspaceSnapshot.sessions.count == 2)
        #expect(workspaceSnapshot.projects.count == 2)

        let wtSession = try #require(workspaceSnapshot.sessions.first { $0.sessionID == "session-wt" })
        #expect(wtSession.title == "Worktree Feature Session")
        #expect(wtSession.inputTokens == 260) // newInput 200 + cacheRead 60 + cacheWrite 0
        #expect(wtSession.cachedInputTokens == 60)
        #expect(wtSession.outputTokens == 50) // output 40 + reasoning 10
        #expect(wtSession.reasoningTokens == 10)
        #expect(wtSession.totalTokens == 310)
        #expect(wtSession.projectPath == "/Users/fixture/.gemini/antigravity/worktrees/my-repo/wt-1")

        let repoSnapshot = try await fixture.snapshot(scanOptions: AntigravityLocalScanOptions(
            projectGrouping: .gitRepository))
        #expect(repoSnapshot.projects.count == 1)
        let repoProject = try #require(repoSnapshot.projects.first)
        #expect(repoProject.name == "owner/my-repo")
        #expect(repoProject.path == "/Users/fixture/dev/my-repo")
        #expect(repoProject.totalTokens == 497)
        #expect(repoProject.sources.count == 2)
        #expect(Set(repoProject.sources.compactMap(\.path)) == [
            "/Users/fixture/dev/my-repo",
            "/Users/fixture/.gemini/antigravity/worktrees/my-repo/wt-1",
        ])
    }

    @Test
    func `includeBreakdowns false does not spend schema budget on trajectory_metadata_blob`() throws {
        let fixture = try Fixture()
        let tmb = Fixture.trajectoryMetadataBlob(
            workspaces: [.init(workspaceURI: "file:///Users/fixture/dev/app")])
        try fixture.database("session-a", blobs: [Fixture.blob()], trajectoryMetadataBlob: tmb)

        var limits = AntigravityLocalReader.Limits()
        limits.schemaEntries = 1
        let report = try fixture.report(limits: limits, includeBreakdowns: false)
        #expect(report.coverage == .complete)
        #expect(report.statistics.schemaEntries == 1)
        #expect(report.projects.isEmpty)
        #expect(report.sessions.isEmpty)
    }

    @Test
    func `scan source toggles filter desktop CLI and tokscale fallback independently`() async throws {
        let fixture = try Fixture()
        // rootIndex 0 = antigravity-cli/conversations; rootIndex 1 = antigravity; plus tokscale jsonl.
        try fixture.database("cli-session", rootIndex: 0, blobs: [Fixture.blob(input: 100)])
        try fixture.database("desktop-session", rootIndex: 1, blobs: [Fixture.blob(input: 200)])
        try fixture.jsonl([Fixture.cacheUsage])

        let desktopOnly = try await fixture.snapshot(scanOptions: AntigravityLocalScanOptions(
            includeDesktopDatabases: true,
            includeCLIDatabases: false,
            includeTokscaleFallback: false))
        #expect(desktopOnly.last30DaysTokens == 287) // 200 + 30 + 50 + 7
        #expect(desktopOnly.sessions.map(\.sessionID) == ["desktop-session"])

        let cliOnly = try await fixture.snapshot(scanOptions: AntigravityLocalScanOptions(
            includeDesktopDatabases: false,
            includeCLIDatabases: true,
            includeTokscaleFallback: false))
        #expect(cliOnly.last30DaysTokens == 187)
        #expect(cliOnly.sessions.map(\.sessionID) == ["cli-session"])

        let tokscaleOnly = try await fixture.snapshot(scanOptions: AntigravityLocalScanOptions(
            includeDesktopDatabases: false,
            includeCLIDatabases: false,
            includeTokscaleFallback: true))
        #expect(tokscaleOnly.last30DaysTokens == 180)
        #expect(tokscaleOnly.sessions.map(\.sessionID) == ["cache-session"])
        #expect(tokscaleOnly.quotaSlices.count == 1)
        #expect(tokscaleOnly.hourly.count == 1)

        let none = try fixture.report(scanOptions: AntigravityLocalScanOptions(
            includeDesktopDatabases: false,
            includeCLIDatabases: false,
            includeTokscaleFallback: false))
        #expect(none.coverage == .unavailable)
    }
}
