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
    func `codex token snapshot stays native when pi owns its source`() async throws {
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
