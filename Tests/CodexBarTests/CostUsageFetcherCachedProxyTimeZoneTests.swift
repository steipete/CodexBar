import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherCachedProxyTimeZoneTests {
    @Test
    func `default fetcher cached calendar options retain the default proxy home`() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))

        let options = try #require(CostUsageFetcher().scannerOptions(calendar: calendar))

        #expect(options.calendar.timeZone == calendar.timeZone)
        #expect(options.cliProxyAPIHome?.lastPathComponent == ".cli-proxy-api")
    }

    @Test
    func `proxy snapshot uses the configured calendar at a day boundary`() async throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "Asia/Shanghai"))
        let day = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone,
            year: 2026,
            month: 7,
            day: 24,
            hour: 0,
            minute: 30)))
        _ = try env.writeClaudeProjectFile(
            relativePath: "proxy/day-boundary.jsonl",
            contents: env.jsonl([[
                "type": "assistant",
                "timestamp": env.isoString(for: day),
                "sessionId": "session-day-boundary",
                "requestId": "request-day-boundary",
                "message": [
                    "id": "message-day-boundary",
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
        X-Claude-Code-Session-Id: session-day-boundary
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
                    requestID: "proxy-day-boundary",
                    tokens: .init(input: 100, output: 5, total: 105)),
            ],
            cacheRoot: env.cacheRoot,
            now: day)

        var options = CostUsageScanner.Options(
            codexSessionsRoot: env.codexSessionsRoot,
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            cliProxyAPIHome: proxyHome)
        options.calendar = calendar
        let snapshot = try await CostUsageFetcher(scannerOptions: options).loadCodexProxyTokenSnapshot(
            now: day,
            forceRefresh: true,
            historyDays: 1,
            allowPricingRefresh: false,
            refreshPricingInBackground: false)

        #expect(snapshot.daily.map(\.date) == ["2026-07-24"])
        let cache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(cache.timeZoneIdentifier == calendar.timeZone.identifier)
    }

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

        let claudeCache = CostUsageClaudeCacheIO.load(provider: .claude, cacheRoot: env.cacheRoot)
        #expect(!claudeCache.days.isEmpty)
        var staleZoneCalendar = options.calendar
        staleZoneCalendar.timeZone = try #require(
            ["UTC", "Asia/Bangkok"]
                .compactMap(TimeZone.init(identifier:))
                .first { $0.identifier != options.calendar.timeZone.identifier })
        _ = try CostUsageClaudeCacheIO.save(
            provider: .claude,
            cache: claudeCache,
            cacheRoot: env.cacheRoot,
            calendar: staleZoneCalendar)

        let cachedSnapshot = await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            scannerOptions: options)

        #expect(cachedSnapshot?.daily.isEmpty == true)
        #expect(cachedSnapshot?.last30DaysTokens == 0)
    }
}
