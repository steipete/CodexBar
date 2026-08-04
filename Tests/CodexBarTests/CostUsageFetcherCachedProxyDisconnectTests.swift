import Foundation
import Testing
@testable import CodexBarCore

struct CostUsageFetcherCachedProxyDisconnectTests {
    @Test
    func `configuration replacement rejects an in flight Claude cache publication`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        _ = try env.writeClaudeProjectFile(
            relativePath: "generation-race/session.jsonl",
            contents: env.jsonl([[
                "type": "assistant",
                "timestamp": env.isoString(for: day),
                "sessionId": "session-generation-race",
                "requestId": "request-generation-race",
                "message": [
                    "id": "message-generation-race",
                    "model": "claude-sonnet-4-6",
                    "usage": ["input_tokens": 100, "output_tokens": 5],
                ],
            ]]))

        let initialGeneration = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(
                stateRoot: env.cacheRoot,
                fileManager: .default))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(initialGeneration))

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot)
        options.forceRescan = true
        var replacedConfiguration = false

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadClaudeDaily(
                provider: .claude,
                range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
                now: day,
                options: options,
                checkCancellation: {
                    guard !replacedConfiguration else { return }
                    replacedConfiguration = true
                    let replacementGeneration = try #require(CostUsageCacheLocations
                        .prepareCLIProxyAPIConfigurationGenerationUpdate(
                            stateRoot: env.cacheRoot,
                            fileManager: .default))
                    #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
                        replacementGeneration))
                })
        }
        #expect(replacedConfiguration)
        #expect(CostUsageCacheIO.load(
            provider: .claude,
            cacheRoot: env.cacheRoot,
            calendar: options.calendar).lastScanUnixMs == 0)
    }

    @Test
    func `configuration replacement rejects a report built from the previous generation`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        let calendar = Calendar(identifier: .gregorian)
        var cache = CostUsageCache()
        cache.lastScanUnixMs = Int64(day.timeIntervalSince1970 * 1000)
        cache.scanSinceKey = "2026-07-24"
        cache.scanUntilKey = "2026-07-24"
        cache.days = ["2026-07-24": ["claude-sonnet-4-6": [100, 0, 0, 5, 0, 1]]]
        CostUsageCacheIO.save(
            provider: .claude,
            cache: cache,
            cacheRoot: env.cacheRoot,
            calendar: calendar)

        let initialGeneration = try #require(CostUsageCacheLocations
            .prepareCLIProxyAPIConfigurationGenerationUpdate(
                stateRoot: env.cacheRoot,
                fileManager: .default))
        #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(initialGeneration))

        var options = CostUsageScanner.Options(cacheRoot: env.cacheRoot)
        options.refreshMinIntervalSeconds = 3600
        var replacedConfiguration = false

        #expect(throws: CancellationError.self) {
            _ = try CostUsageScanner.loadClaudeDaily(
                provider: .claude,
                range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
                now: day,
                options: options,
                checkCancellation: {
                    guard !replacedConfiguration else { return }
                    replacedConfiguration = true
                    let replacementGeneration = try #require(CostUsageCacheLocations
                        .prepareCLIProxyAPIConfigurationGenerationUpdate(
                            stateRoot: env.cacheRoot,
                            fileManager: .default))
                    #expect(CostUsageCacheLocations.commitCLIProxyAPIConfigurationGenerationUpdate(
                        replacementGeneration))
                })
        }
        #expect(replacedConfiguration)
    }

    @Test
    func `disconnect during proxy scan excludes the stale Codex report`() throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }

        let day = try env.makeLocalNoon(year: 2026, month: 7, day: 24)
        _ = try env.writeClaudeProjectFile(
            relativePath: "proxy-race/session.jsonl",
            contents: env.jsonl([[
                "type": "assistant",
                "timestamp": env.isoString(for: day),
                "sessionId": "session-proxy-race",
                "requestId": "request-proxy-race",
                "message": [
                    "id": "message-proxy-race",
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
        X-Claude-Code-Session-Id: session-proxy-race
        === REQUEST BODY ===
        {"model":"claude-sonnet-4-6"}
        === API RESPONSE ===
        """
        try Data(proxyLog.utf8).write(to: proxyLogs.appendingPathComponent("request.log"))
        #expect(CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: day,
                    provider: "codex",
                    executorType: "CodexExecutor",
                    model: "gpt-5.5",
                    alias: "claude-sonnet-4-6",
                    endpoint: "/v1/messages",
                    authType: "oauth",
                    requestID: "request-proxy-race",
                    tokens: .init(input: 100, output: 5, total: 105)),
            ],
            cacheRoot: env.cacheRoot,
            now: day) == 1)

        var options = CostUsageScanner.Options(
            claudeProjectsRoots: [env.claudeProjectsRoot],
            cacheRoot: env.cacheRoot,
            claudeAttributionFilter: .codexBackendOnly,
            cliProxyAPIHome: proxyHome)
        options.forceRescan = true
        var didDisconnect = false
        let report = try CostUsageScanner.loadClaudeDaily(
            provider: .claude,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            now: day,
            options: options,
            checkCancellation: {
                guard !didDisconnect else { return }
                didDisconnect = true
                #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
                    true,
                    stateRoot: env.cacheRoot))
            })

        #expect(didDisconnect)
        #expect(report.data.isEmpty)

        options.forceRescan = false
        options.claudeAttributionFilter = .excludeCodexBackend
        let claudeReport = try CostUsageScanner.loadClaudeDaily(
            provider: .claude,
            range: CostUsageScanner.CostUsageDayRange(since: day, until: day),
            now: day,
            options: options,
            checkCancellation: nil)
        #expect(claudeReport.data.first?.totalTokens == 105)
        #expect(claudeReport.data.first?.modelBreakdowns?.first?.attribution == nil)
    }

    @Test(arguments: ["claude-sonnet-4-6", "gpt-5.5"])
    func `disconnect strips surviving cached proxy attribution`(model: String) async throws {
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
                    "model": model,
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
        {"model":"\(model)"}
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
                    alias: model,
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
        let attributedCodex = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(attributedCodex.daily.first?.totalTokens == 105)
        #expect(attributedCodex.daily.first?.modelBreakdowns?.first?.attribution?.route == .cliProxyAPI)

        try FileManager.default.removeItem(at: proxyLogs)
        try FileManager.default.removeItem(at: proxyHome.appendingPathComponent("codex-auth.json"))
        #expect(CostUsageCacheLocations.setCLIProxyAPIExplicitlyDisconnected(
            true,
            stateRoot: env.cacheRoot))

        let disconnectedClaude = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            allowPricingRefresh: false,
            includePiSessions: false,
            scannerOptions: options)
        #expect(disconnectedClaude.daily.first?.totalTokens == 105)
        #expect(disconnectedClaude.daily.first?.modelBreakdowns?.first?.attribution == nil)
        #expect(await CostUsageFetcher.loadCachedCodexTokenSnapshot(
            now: day,
            scannerOptions: options) == nil)
    }
}
