import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized, CostUsageClaudeCacheFixtures())
struct CostUsageFetcherClaudeBreakdownTests {
    @Test
    func `native Claude load carries projects and sessions`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try Self.writeClaudeSession(env: env, day: day)

        let result = try await Self.load(env: env, day: day, includePiSessions: false)

        let snapshot = result.snapshot
        #expect(result.accounting == .nativeOnly)
        #expect(snapshot.detailsAreComplete)
        #expect(snapshot.projects.map(\.path) == ["/Users/test/projects/alpha"])
        #expect(snapshot.sessions.map(\.sessionID) == ["session-alpha"])
        #expect(snapshot.sessions.first?.projectName == "alpha")
        #expect(snapshot.projects.compactMap(\.totalTokens).reduce(0, +) == snapshot.last30DaysTokens)
    }

    @Test
    func `inclusive Claude load folds Pi rows into an unknown project without sessions`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        let day = try env.makeLocalNoon(year: 2026, month: 3, day: 10)
        try Self.writeClaudeSession(env: env, day: day)
        _ = try env.writePiSessionFile(
            relativePath: "2026-03-10T10-00-00-000Z_mirror.jsonl",
            contents: env.jsonl([[
                "type": "message",
                "id": "pi-turn",
                "timestamp": env.isoString(for: day),
                "message": [
                    "role": "assistant",
                    "provider": "anthropic",
                    "model": "claude-sonnet-4-5",
                    "usage": ["input": 20, "output": 5, "totalTokens": 25],
                ],
            ]]))

        let result = try await Self.load(env: env, day: day, includePiSessions: true)

        let snapshot = result.snapshot
        #expect(snapshot.last30DaysTokens == 135)
        #expect(snapshot.sessions.isEmpty)
        #expect(!snapshot.detailsAreComplete)
        #expect(Set(snapshot.projects.map(\.name)) == ["alpha", CostUsageProjectBreakdown.unknownProjectName])
        #expect(snapshot.projects.compactMap(\.totalTokens).reduce(0, +) == 135)
        guard case let .includesPi(_, native) = result.accounting else {
            Issue.record("expected an inclusive Pi accounting result")
            return
        }
        #expect(native.last30DaysTokens == 110)
        #expect(native.sessions.map(\.sessionID) == ["session-alpha"])
        #expect(native.projects.map(\.path) == ["/Users/test/projects/alpha"])
    }

    private static func writeClaudeSession(env: CostUsageTestEnvironment, day: Date) throws {
        _ = try env.writeClaudeProjectFile(
            relativePath: "alpha/session-alpha.jsonl",
            contents: env.jsonl([[
                "type": "assistant",
                "timestamp": env.isoString(for: day),
                "sessionId": "session-alpha",
                "requestId": "request-alpha",
                "cwd": "/Users/test/projects/alpha",
                "message": [
                    "id": "message-alpha",
                    "model": "claude-sonnet-4-5",
                    "usage": ["input_tokens": 100, "output_tokens": 10],
                ],
            ]]))
    }

    private static func load(
        env: CostUsageTestEnvironment,
        day: Date,
        includePiSessions: Bool) async throws -> CostUsageTokenResult
    {
        var scannerOptions = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        scannerOptions.refreshMinIntervalSeconds = 0
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: env.piSessionsRoot,
            cacheRoot: env.cacheRoot,
            refreshMinIntervalSeconds: 0,
            environment: ["HOME": env.root.path])
        return try await CostUsageFetcher.loadTokenResult(
            provider: .claude,
            environment: ["HOME": env.root.path],
            now: day,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: includePiSessions,
            scannerOptions: scannerOptions,
            piScannerOptions: piOptions)
    }
}
