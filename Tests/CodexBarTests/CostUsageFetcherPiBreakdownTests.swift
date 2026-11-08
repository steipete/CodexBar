import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherPiBreakdownTests {
    @Test
    func `pi token snapshot publishes session and project breakdowns`() async throws {
        let fixture = try PiSessionCostBreakdownFixture()
        defer { fixture.env.cleanup() }
        try Self.writeSessions(fixture)

        let result = try await CostUsageFetcher.loadTokenResult(
            provider: .pi,
            environment: ["HOME": fixture.env.root.path],
            now: fixture.day,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            piScannerOptions: fixture.options)

        let snapshot = result.snapshot
        #expect(snapshot.last30DaysTokens == 45)
        #expect(snapshot.detailsAreComplete)
        #expect(Set(snapshot.sessions.map(\.sessionID)) == ["alpha-session", "beta-session"])
        #expect(snapshot.sessions.first { $0.sessionID == "alpha-session" }?.title == "Refactor parser")
        #expect(snapshot.projects.map(\.name) == ["beta", "alpha"])
        #expect(snapshot.projects.compactMap(\.totalTokens).reduce(0, +) == 45)
    }

    @Test
    func `codex token snapshot excluding pi sessions has no pi rows`() async throws {
        let fixture = try PiSessionCostBreakdownFixture()
        defer { fixture.env.cleanup() }
        try Self.writeSessions(fixture)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.env.codexSessionsRoot,
            cacheRoot: fixture.env.cacheRoot,
            codexTraceDatabaseURL: fixture.env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let result = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["HOME": fixture.env.root.path],
            now: fixture.day,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            piScannerOptions: fixture.options)

        #expect(result.accounting == .nativeOnly)
        #expect(result.snapshot.projects.isEmpty)
        #expect(result.snapshot.sessions.isEmpty)
        #expect(result.snapshot.daily.isEmpty)
    }

    @Test
    func `codex token snapshot including pi sessions folds its pi partition into one unknown project`() async throws {
        let fixture = try PiSessionCostBreakdownFixture()
        defer { fixture.env.cleanup() }
        try Self.writeSessions(fixture)
        // A non-Codex row keeps the Pi total distinct from its Codex partition.
        try fixture.write("2026-04-10T12-00-00-000Z_gamma.jsonl", [
            fixture.header(id: "gamma-session", cwd: "/Users/test/projects/gamma"),
            fixture.assistant(id: "g1", provider: "anthropic", model: "claude-sonnet-4-6", input: 7, output: 3),
        ])
        var options = CostUsageScanner.Options(
            codexSessionsRoot: fixture.env.codexSessionsRoot,
            cacheRoot: fixture.env.cacheRoot,
            codexTraceDatabaseURL: fixture.env.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = 0

        let result = try await CostUsageFetcher.loadTokenResult(
            provider: .codex,
            environment: ["HOME": fixture.env.root.path],
            now: fixture.day,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: true,
            scannerOptions: options,
            piScannerOptions: fixture.options)
        let piTotal = try fixture.scan().report.summary?.totalTokens
        let piCodex = try fixture.scan(provider: .codex).report.summary?.totalTokens

        guard case .includesPi = result.accounting else {
            Issue.record("Expected inclusive Pi accounting")
            return
        }
        #expect(piTotal == 55)
        #expect(piCodex == 45)
        #expect(result.snapshot.sessions.isEmpty)
        #expect(result.snapshot.projects.count == 1)
        let project = try #require(result.snapshot.projects.first)
        #expect(project.name == CostUsageProjectBreakdown.unknownProjectName)
        #expect(project.path == nil)
        #expect(project.totalTokens == piCodex)
        #expect(result.snapshot.last30DaysTokens == piCodex)
    }

    private static func writeSessions(_ fixture: PiSessionCostBreakdownFixture) throws {
        try fixture.write("2026-04-10T10-00-00-000Z_alpha.jsonl", [
            fixture.header(id: "alpha-session", cwd: "/Users/test/projects/alpha"),
            ["type": "session_info", "name": "Refactor parser"],
            fixture.assistant(id: "a1", provider: "openai-codex", model: "gpt-5.4", input: 10, output: 5),
        ])
        try fixture.write("2026-04-10T11-00-00-000Z_beta.jsonl", [
            fixture.header(id: "beta-session", cwd: "/Users/test/projects/beta"),
            fixture.assistant(id: "b1", provider: "openai-codex", model: "gpt-5.4", input: 20, output: 10),
        ])
    }
}
