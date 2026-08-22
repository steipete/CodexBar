import Foundation
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageFetcherCLIProxyAttributionReconciliationTests {
    @Test
    func `batch reconciliation includes unkeyed legacy Claude rows`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        func assistant(seconds: TimeInterval) -> [String: Any] {
            [
                "type": "assistant",
                "timestamp": env.isoString(for: day.addingTimeInterval(seconds)),
                "sessionId": "legacy-session",
                "message": [
                    "model": "gpt-5.5",
                    "usage": ["input_tokens": 100, "output_tokens": 5],
                ],
            ]
        }
        _ = try env.writeClaudeProjectFile(
            relativePath: "legacy-proxy/session.jsonl",
            contents: env.jsonl([
                assistant(seconds: 0),
                assistant(seconds: 30),
            ]))

        let cliProxyHome = env.root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        let cliProxyLogs = cliProxyHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: cliProxyLogs, withIntermediateDirectories: true)
        try Data(#"{"type":"codex"}"#.utf8)
            .write(to: cliProxyHome.appendingPathComponent("codex-auth.json"))
        let proxyLog = """
        === REQUEST INFO ===
        URL: /v1/messages
        Timestamp: \(env.isoString(for: day))
        === HEADERS ===
        X-Claude-Code-Session-Id: legacy-session
        === REQUEST BODY ===
        {"model":"gpt-5.5"}
        === API RESPONSE ===
        """
        try Data(proxyLog.utf8).write(to: cliProxyLogs.appendingPathComponent("request.log"))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: day,
                    provider: "codex",
                    executorType: "CodexExecutor",
                    model: "gpt-5.5",
                    alias: "gpt-5.5",
                    endpoint: "/v1/messages",
                    authType: "oauth",
                    requestID: "legacy-proxy-request",
                    tokens: .init(input: 100, output: 5, total: 105)),
            ],
            cacheRoot: env.cacheRoot,
            now: day) == 1)
        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            cliProxyAPIHome: cliProxyHome)

        let codex = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        let claude = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)

        #expect(codex.daily.first?.totalTokens == 105)
        #expect(codex.daily.first?.modelBreakdowns?.first?.attribution?.route == .cliProxyAPI)
        #expect(claude.daily.isEmpty)
    }
}
