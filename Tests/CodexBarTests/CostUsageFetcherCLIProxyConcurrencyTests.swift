import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherCLIProxyConcurrencyTests {
    @Test
    func `concurrent proxy requests retain distinct token matched upstreams`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        func assistant(
            sessionID: String,
            requestID: String,
            seconds: TimeInterval,
            input: Int,
            output: Int) -> [String: Any]
        {
            [
                "type": "assistant",
                "timestamp": env.isoString(for: day.addingTimeInterval(seconds)),
                "sessionId": sessionID,
                "requestId": requestID,
                "message": [
                    "id": "message-\(requestID)",
                    "model": "gpt-5.5",
                    "usage": ["input_tokens": input, "output_tokens": output],
                ],
            ]
        }
        _ = try env.writeClaudeProjectFile(
            relativePath: "concurrent-proxy/session.jsonl",
            contents: env.jsonl([
                assistant(
                    sessionID: "session-codex",
                    requestID: "codex",
                    seconds: 0,
                    input: 10,
                    output: 2),
                assistant(
                    sessionID: "session-openrouter",
                    requestID: "openrouter",
                    seconds: 2,
                    input: 100,
                    output: 20),
            ]))

        let cliProxyHome = env.root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        let logs = cliProxyHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        for (name, sessionID, seconds) in [
            ("codex", "session-codex", 0.0),
            ("openrouter", "session-openrouter", 2.0),
        ] {
            let log = """
            === REQUEST INFO ===
            URL: /v1/messages
            Timestamp: \(env.isoString(for: day.addingTimeInterval(seconds)))
            === HEADERS ===
            X-Claude-Code-Session-Id: \(sessionID)
            === REQUEST BODY ===
            {"model":"gpt-5.5"}
            === API RESPONSE ===
            """
            try Data(log.utf8).write(to: logs.appendingPathComponent("\(name).log"))
        }
        CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: day,
                    provider: "codex",
                    executorType: "CodexExecutor",
                    model: "gpt-5.5",
                    alias: "gpt-5.5",
                    endpoint: "/v1/messages",
                    authType: "oauth",
                    requestID: "cliproxy-codex",
                    tokens: .init(input: 10, output: 2, total: 12)),
                CLIProxyAPIUsageRecord(
                    timestamp: day.addingTimeInterval(2),
                    provider: "openrouter",
                    executorType: "OpenAICompatExecutor",
                    model: "gpt-5.5",
                    alias: "gpt-5.5",
                    endpoint: "/v1/messages",
                    authType: "api_key",
                    requestID: "cliproxy-openrouter",
                    tokens: .init(input: 100, output: 20, total: 120)),
            ],
            cacheRoot: env.cacheRoot,
            now: day.addingTimeInterval(2))
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

        let codexBreakdown = try #require(codex.daily.first?.modelBreakdowns?.first)
        let claudeBreakdown = try #require(claude.daily.first?.modelBreakdowns?.first)
        #expect(codex.daily.first?.totalTokens == 12)
        #expect(codexBreakdown.attribution?.upstream?.provider == "codex")
        #expect(claude.daily.first?.totalTokens == 120)
        #expect(claudeBreakdown.attribution?.upstream?.provider == "openrouter")
    }
}
