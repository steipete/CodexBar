import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherCachedProxyTimeZoneTests {
    @Test
    func `cached codex snapshot rejects claude proxy cache from another time zone`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        _ = try env.writeClaudeProjectFile(
            relativePath: "proxy/session.jsonl",
            contents: env.jsonl([[
                "type": "assistant",
                "timestamp": env.isoString(for: day),
                "sessionId": "session-proxy",
                "requestId": "request-proxy",
                "message": [
                    "id": "message-proxy",
                    "model": "claude-sonnet-4-6",
                    "usage": ["input_tokens": 100, "output_tokens": 5],
                ],
            ]]))

        let proxyHome = env.root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        let proxyLogs = proxyHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: proxyLogs, withIntermediateDirectories: true)
        try Data(#"{"type":"codex"}"#.utf8)
            .write(to: proxyHome.appendingPathComponent("codex-auth.json"))
        let proxyLog = """
        === REQUEST INFO ===
        URL: /v1/messages
        Timestamp: \(env.isoString(for: day))
        === HEADERS ===
        X-Claude-Code-Session-Id: session-proxy
        === REQUEST BODY ===
        {"model":"claude-sonnet-4-6"}
        === API RESPONSE ===
        """
        try Data(proxyLog.utf8).write(to: proxyLogs.appendingPathComponent("request.log"))
        CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: day,
                    provider: "codex",
                    executorType: "CodexExecutor",
                    model: "gpt-5.5",
                    alias: "claude-sonnet-4-6",
                    endpoint: "/v1/messages",
                    authType: "oauth",
                    requestID: "proxy-request",
                    tokens: .init(input: 100, output: 5, total: 105)),
            ],
            cacheRoot: env.cacheRoot,
            now: day)

        let options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            cliProxyAPIHome: proxyHome)
        _ = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)

        let claudeCache = CostUsageCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(!claudeCache.days.isEmpty)
        var staleZoneCalendar = options.calendar
        staleZoneCalendar.timeZone = try #require(
            ["UTC", "Asia/Bangkok"]
                .compactMap(TimeZone.init(identifier:))
                .first { $0.identifier != options.calendar.timeZone.identifier })
        CostUsageCacheIO.save(
            provider: .claude,
            cache: claudeCache,
            cacheRoot: env.cacheRoot,
            calendar: staleZoneCalendar)

        let cachedSnapshot = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            scannerOptions: options)

        #expect(cachedSnapshot == nil)
    }
}
