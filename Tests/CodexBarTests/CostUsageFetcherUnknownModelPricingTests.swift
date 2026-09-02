import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct CostUsageFetcherUnknownModelPricingTests {
    @Test
    func `resolved upstream model does not reuse a cached alias price`() {
        #expect(CostUsageScanner.resolvedClaudeRowCost(
            wasPriced: true,
            cachedCostNanos: 1_000_000_000,
            cachedPricingModel: "claude-priced-alias",
            pricingModel: "unpriced-upstream",
            currentCost: nil) == nil)
        #expect(CostUsageScanner.resolvedClaudeRowCost(
            wasPriced: true,
            cachedCostNanos: 1_000_000_000,
            cachedPricingModel: "claude-priced-alias",
            pricingModel: "claude-priced-alias",
            currentCost: nil) == 1)
        #expect(CostUsageScanner.resolvedClaudeRowCost(
            wasPriced: true,
            cachedCostNanos: 1_000_000_000,
            cachedPricingModel: "claude-priced-alias",
            pricingModel: "priced-upstream",
            currentCost: 2) == 2)
    }

    @Test
    func `fetcher reprices an unknown model after an on demand catalog refresh`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: fixture.options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-new")
        #expect(abs((breakdown.costUSD ?? 0) - 0.00028) < 0.0000001)
    }

    @Test
    func `fetcher excludes routed opencode go models from the Codex snapshot`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let qualifiedTurnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "payload": ["model": "opencode-go/deepseek-v4-flash"],
        ]
        let qualifiedTokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": fixture.environment.isoString(for: fixture.day.addingTimeInterval(1)),
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try fixture.environment.writeCodexSessionFile(
            day: fixture.day,
            filename: "unknown-qualified-model.jsonl",
            contents: fixture.environment.jsonl([qualifiedTurnContext, qualifiedTokenCount]))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: fixture.options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        #expect(!(snapshot.daily
                .flatMap { $0.modelBreakdowns ?? [] }
                .contains { $0.modelName == "opencode-go/deepseek-v4-flash" }))
    }

    @Test
    func `claude snapshot excludes a bare foreign provider model after catalog refresh`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "message": [
                "model": "deepseek-v4-flash",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]
        _ = try fixture.environment.writeClaudeProjectFile(
            relativePath: "project-a/unknown-vendor-model.jsonl",
            contents: fixture.environment.jsonl([assistant]))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: fixture.options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        #expect(!(snapshot.daily
                .flatMap { $0.modelBreakdowns ?? [] }
                .contains { $0.modelName == "deepseek-v4-flash" }))
    }

    @Test
    func `claude snapshot retains a bare model with ambiguous catalog ownership`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "message": [
                "model": "shared-model",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]
        _ = try fixture.environment.writeClaudeProjectFile(
            relativePath: "project-a/ambiguous-provider-model.jsonl",
            contents: fixture.environment.jsonl([assistant]))
        var options = fixture.options
        options.claudeAttributionFilter = .excludeCodexBackend
        let ambiguousCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "shared-model": { "id": "shared-model", "cost": { "input": 2, "output": 8 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "shared-model": { "id": "shared-model", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: ambiguousCatalog)))

        #expect(snapshot.daily
            .flatMap { $0.modelBreakdowns ?? [] }
            .contains { $0.modelName == "shared-model" })
    }

    @Test
    func `claude cached ownership follows catalog ambiguity changes`() throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let model = "shared-cached-model"
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "message": [
                "model": model,
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]
        _ = try fixture.environment.writeClaudeProjectFile(
            relativePath: "project-a/cached-ambiguous-provider-model.jsonl",
            contents: fixture.environment.jsonl([assistant]))
        var options = fixture.options
        options.claudeAttributionFilter = .excludeCodexBackend
        options.refreshMinIntervalSeconds = 0
        let openAICatalog = try Self.catalog(model: model, providerIDs: ["openai"])
        #expect(ModelsDevCache.save(
            catalog: openAICatalog,
            fetchedAt: fixture.day,
            cacheRoot: fixture.environment.cacheRoot))

        let foreign = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: fixture.day,
            until: fixture.day,
            now: fixture.day,
            options: options)
        #expect(!foreign.data.contains { $0.modelBreakdowns?.contains { $0.modelName == model } == true })

        let ambiguousCatalog = try Self.catalog(model: model, providerIDs: ["openai", "anthropic"])
        #expect(ModelsDevCache.save(
            catalog: ambiguousCatalog,
            fetchedAt: fixture.day.addingTimeInterval(1),
            cacheRoot: fixture.environment.cacheRoot))
        options.refreshMinIntervalSeconds = 3600

        let ambiguous = CostUsageScanner.loadDailyReport(
            provider: .claude,
            since: fixture.day,
            until: fixture.day,
            now: fixture.day.addingTimeInterval(1),
            options: options)
        #expect(ambiguous.data.contains { $0.modelBreakdowns?.contains { $0.modelName == model } == true })
    }

    @Test
    func `claude snapshot excludes a resolved foreign provider model`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let assistant: [String: Any] = [
            "type": "assistant",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "message": [
                "model": "deepseek/deepseek-v4-flash",
                "usage": [
                    "input_tokens": 100,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 0,
                    "output_tokens": 10,
                ],
            ],
        ]
        _ = try fixture.environment.writeClaudeProjectFile(
            relativePath: "project-a/foreign-provider-model.jsonl",
            contents: fixture.environment.jsonl([assistant]))
        var options = fixture.options
        options.claudeAttributionFilter = .excludeCodexBackend

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        #expect(!(snapshot.daily
                .flatMap { $0.modelBreakdowns ?? [] }
                .contains { $0.modelName == "deepseek/deepseek-v4-flash" }))
    }

    @Test
    func `pricing retry preserves disabled pi session merging`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let piAssistant: [String: Any] = [
            "type": "message",
            "timestamp": fixture.environment.isoString(for: fixture.day),
            "message": [
                "role": "assistant",
                "provider": "openai-codex",
                "model": "openai/gpt-5.4",
                "timestamp": Int(fixture.day.timeIntervalSince1970 * 1000),
                "usage": ["input": 50, "output": 10, "totalTokens": 60],
            ],
        ]
        _ = try fixture.environment.writePiSessionFile(
            relativePath: "2026-04-12T12-00-00-000Z_retry.jsonl",
            contents: fixture.environment.jsonl([piAssistant]))
        let piOptions = PiSessionCostScanner.Options(
            piSessionsRoot: fixture.environment.piSessionsRoot,
            cacheRoot: fixture.environment.cacheRoot,
            refreshMinIntervalSeconds: 0)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: fixture.options,
            piScannerOptions: piOptions,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: fixture.refreshedCatalog)))

        #expect(snapshot.daily.first?.totalTokens == 110)
        #expect(snapshot.daily.first?.modelBreakdowns?.map(\.modelName) == ["gpt-new"])
    }

    private static func catalog(model: String, providerIDs: [String]) throws -> ModelsDevCatalog {
        let providers = providerIDs.map { providerID in
            """
            "\(providerID)": {
              "id": "\(providerID)",
              "models": { "\(model)": { "id": "\(model)", "cost": { "input": 2, "output": 8 } } }
            }
            """
        }.joined(separator: ",")
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("{\(providers)}".utf8))
    }

    @Test
    func `background pricing refresh returns unpriced usage before catalog download finishes`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        let gate = UnknownModelPricingTransportGate()
        let completion = UnknownModelPricingCompletionProbe()
        let task = Task {
            let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
                provider: .codex,
                now: fixture.day,
                refreshPricingInBackground: true,
                includePiSessions: false,
                scannerOptions: fixture.options,
                modelsDevClient: ModelsDevClient(transport: CostUsageFetcherGatedModelsDevTransport(
                    data: fixture.refreshedCatalog,
                    gate: gate)))
            await completion.markCompleted()
            return snapshot
        }

        await gate.waitUntilStarted()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(1))
        while await !(completion.isCompleted), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let returnedBeforeRelease = await completion.isCompleted
        await gate.release()
        let snapshot = try await task.value

        #expect(returnedBeforeRelease)
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-new")
        #expect(breakdown.totalTokens == 110)
        #expect(breakdown.costUSD == nil)

        let refreshDeadline = clock.now.advanced(by: .seconds(1))
        while ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-new",
            cacheRoot: fixture.environment.cacheRoot) == nil,
            clock.now < refreshDeadline
        {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(ModelsDevPricingPipeline.lookup(
            providerID: "openai",
            modelID: "gpt-new",
            cacheRoot: fixture.environment.cacheRoot) != nil)
    }

    @Test
    func `unattributed codex usage does not request a pricing refresh`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 4, day: 12)
        let staleCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "known-test-model": { "id": "known-test-model", "cost": { "input": 1, "output": 4 } } }
          }
        }
        """.utf8))
        ModelsDevCache.save(
            catalog: staleCatalog,
            fetchedAt: day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": environment.isoString(for: day),
            "payload": [
                "type": "token_count",
                "info": [
                    "last_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try environment.writeCodexSessionFile(
            day: day,
            filename: "unattributed-model.jsonl",
            contents: environment.jsonl([tokenCount]))
        let options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot,
            codexTraceDatabaseURL: environment.root.appendingPathComponent("missing-traces.sqlite"))
        let counter = UnknownModelPricingRequestCounter()

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherCountingModelsDevTransport(counter: counter)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        let requestCount = await counter.requestCount
        #expect(breakdown.modelName == CostUsagePricing.codexUnattributedModel)
        #expect(breakdown.totalTokens == 110)
        #expect(breakdown.costUSD == nil)
        #expect(requestCount == 0)
    }

    @Test(arguments: [false, true])
    func `local only fetch skips every pricing network refresh`(includePiSessions: Bool) async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        try fixture.writePiSession()
        let counter = UnknownModelPricingRequestCounter()

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: fixture.day,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: includePiSessions,
            scannerOptions: fixture.options,
            piScannerOptions: fixture.piOptions,
            modelsDevClient: ModelsDevClient(
                transport: CostUsageFetcherCountingModelsDevTransport(counter: counter)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gpt-new")
        #expect(breakdown.costUSD == nil)
        #expect(snapshot.sessionTokens == (includePiSessions ? 170 : 110))
        #expect(snapshot.last30DaysTokens == (includePiSessions ? 170 : 110))
        #expect(await counter.requestCount == 0)
    }

    @Test
    func `proxy-only fetcher refreshes pricing for the resolved upstream model`() async throws {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 7, day: 24)
        let alias = "claude-proxy-alias"
        let freshCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-old": { "id": "gpt-old", "cost": { "input": 1, "output": 4 } } }
          }
        }
        """.utf8))
        ModelsDevCache.save(
            catalog: freshCatalog,
            fetchedAt: day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)

        _ = try environment.writeClaudeProjectFile(
            relativePath: "proxy/unknown-model.jsonl",
            contents: environment.jsonl([[
                "type": "assistant",
                "timestamp": environment.isoString(for: day),
                "sessionId": "session-proxy",
                "requestId": "request-proxy",
                "message": [
                    "id": "message-proxy",
                    "model": "\(alias)",
                    "usage": ["input_tokens": 100, "output_tokens": 10],
                ],
            ]]))
        let cliProxyHome = environment.root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        let cliProxyLogs = cliProxyHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: cliProxyLogs, withIntermediateDirectories: true)
        try Data(#"{"type":"codex"}"#.utf8)
            .write(to: cliProxyHome.appendingPathComponent("codex-auth.json"))
        let proxyLog = """
        === REQUEST INFO ===
        URL: /v1/messages
        Timestamp: \(environment.isoString(for: day))
        === HEADERS ===
        X-Claude-Code-Session-Id: session-proxy
        === REQUEST BODY ===
        {"model":"\(alias)"}
        === API RESPONSE ===
        """
        try Data(proxyLog.utf8).write(to: cliProxyLogs.appendingPathComponent("request.log"))
        CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: day,
                    provider: "codex",
                    executorType: "CodexExecutor",
                    model: "gpt-new",
                    alias: alias,
                    endpoint: "/v1/messages",
                    authType: "oauth",
                    requestID: "cliproxy-request",
                    tokens: .init(input: 100, output: 10, total: 110)),
            ],
            cacheRoot: environment.cacheRoot,
            now: day)
        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot,
            cliProxyAPIHome: cliProxyHome)
        let refreshedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)

        let snapshot = try await CostUsageFetcher(scannerOptions: options).loadCodexProxyTokenSnapshot(
            now: day,
            forceRefresh: true,
            refreshPricingInBackground: false,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: refreshedCatalog)))

        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == alias)
        #expect(breakdown.attribution?.upstream?.model == "gpt-new")
        #expect(abs((breakdown.costUSD ?? 0) - 0.00028) < 0.0000001)
    }

    @Test(arguments: [
        ("claude-new", "claude", "ClaudeExecutor", 0.00045, true),
        ("gpt-new", "openrouter", "OpenAICompatExecutor", 0.00028, false),
        ("gemma-new", "gemini", nil, 0.00036, false),
    ])
    func `claude fetch retains only anthropic proxy upstreams`(
        upstreamModel: String,
        upstreamProvider: String,
        executorType: String?,
        expectedCost: Double,
        shouldInclude: Bool) async throws
    {
        let environment = try CostUsageTestEnvironment()
        defer { environment.cleanup() }
        let day = try environment.makeLocalNoon(year: 2026, month: 7, day: 24)
        let alias = "claude-proxy-alias"
        let staleCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-old": { "id": "gpt-old", "cost": { "input": 1, "output": 4 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-old": { "id": "claude-old", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8))
        ModelsDevCache.save(
            catalog: staleCatalog,
            fetchedAt: day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)

        _ = try environment.writeClaudeProjectFile(
            relativePath: "proxy/openrouter-unknown-model.jsonl",
            contents: environment.jsonl([[
                "type": "assistant",
                "timestamp": environment.isoString(for: day),
                "sessionId": "session-openrouter",
                "requestId": "request-openrouter",
                "message": [
                    "id": "message-openrouter",
                    "model": "\(alias)",
                    "usage": ["input_tokens": 100, "output_tokens": 10],
                ],
            ]]))
        let cliProxyHome = environment.root.appendingPathComponent("cli-proxy-api", isDirectory: true)
        let cliProxyLogs = cliProxyHome.appendingPathComponent("logs", isDirectory: true)
        try FileManager.default.createDirectory(at: cliProxyLogs, withIntermediateDirectories: true)
        let proxyLog = """
        === REQUEST INFO ===
        URL: /v1/messages
        Timestamp: \(environment.isoString(for: day))
        === HEADERS ===
        X-Claude-Code-Session-Id: session-openrouter
        === REQUEST BODY ===
        {"model":"\(alias)"}
        === API RESPONSE ===
        """
        try Data(proxyLog.utf8).write(to: cliProxyLogs.appendingPathComponent("request.log"))
        CLIProxyAPIUsageCacheIO.merge(
            [
                CLIProxyAPIUsageRecord(
                    timestamp: day,
                    provider: upstreamProvider,
                    executorType: executorType,
                    model: upstreamModel,
                    alias: alias,
                    endpoint: "/v1/messages",
                    authType: "api_key",
                    requestID: "cliproxy-openrouter-\(upstreamModel)",
                    tokens: .init(input: 100, output: 10, total: 110)),
            ],
            cacheRoot: environment.cacheRoot,
            now: day)
        let options = CostUsageScanner.Options(
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot,
            cliProxyAPIHome: cliProxyHome)
        let refreshedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          },
          "google": {
            "id": "google",
            "models": { "gemma-new": { "id": "gemma-new", "cost": { "input": 2.5, "output": 11 } } }
          }
        }
        """.utf8)

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            now: day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: ModelsDevClient(transport: CostUsageFetcherModelsDevTransport(
                data: refreshedCatalog)))

        guard shouldInclude else {
            #expect(snapshot.daily.isEmpty)
            return
        }
        let breakdown = try #require(snapshot.daily.first?.modelBreakdowns?.first)
        #expect(breakdown.modelName == alias)
        #expect(breakdown.attribution?.upstream?.provider == upstreamProvider)
        #expect(breakdown.attribution?.upstream?.model == upstreamModel)
        #expect(abs((breakdown.costUSD ?? 0) - expectedCost) < 0.0000001)
    }

    @Test
    func `foreground pricing scheduling still requests a catalog for native plus pi usage`() async throws {
        let fixture = try UnknownModelPricingFixture()
        defer { fixture.environment.cleanup() }
        try fixture.writePiSession()
        let counter = UnknownModelPricingRequestCounter()

        // This was the timestamp fixtures' old configuration: foreground is not an opt-out.
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .codex,
            now: fixture.day,
            refreshPricingInBackground: false,
            scannerOptions: fixture.options,
            piScannerOptions: fixture.piOptions,
            modelsDevClient: ModelsDevClient(
                transport: CostUsageFetcherCountingModelsDevTransport(counter: counter)))

        #expect(snapshot.sessionTokens == 170)
        #expect(await counter.requestCount == 1)
    }
}

private struct UnknownModelPricingFixture {
    let environment: CostUsageTestEnvironment
    let day: Date
    let options: CostUsageScanner.Options
    let refreshedCatalog: Data

    var piOptions: PiSessionCostScanner.Options {
        PiSessionCostScanner.Options(
            piSessionsRoot: self.environment.piSessionsRoot,
            cacheRoot: self.environment.cacheRoot,
            refreshMinIntervalSeconds: 0)
    }

    func writePiSession() throws {
        _ = try self.environment.writePiSessionFile(
            relativePath: "2026-04-12T12-00-00-000Z_pricing.jsonl",
            contents: self.environment.jsonl([[
                "type": "message",
                "timestamp": self.environment.isoString(for: self.day),
                "message": [
                    "role": "assistant",
                    "provider": "openai-codex",
                    "model": "gpt-new",
                    "timestamp": Int(self.day.timeIntervalSince1970 * 1000),
                    "usage": ["input": 50, "output": 10, "totalTokens": 60],
                ],
            ]]))
    }

    init() throws {
        let environment = try CostUsageTestEnvironment()
        self.environment = environment
        self.day = try environment.makeLocalNoon(year: 2026, month: 4, day: 12)
        let oldCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-old": { "id": "gpt-old", "cost": { "input": 1, "output": 4 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-old": { "id": "claude-old", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8))
        ModelsDevCache.save(
            catalog: oldCatalog,
            fetchedAt: self.day.addingTimeInterval(-901),
            cacheRoot: environment.cacheRoot)

        self.refreshedCatalog = Data("""
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-new": { "id": "gpt-new", "cost": { "input": 2, "output": 8 } } }
          },
          "opencode-go": {
            "id": "opencode-go",
            "models": {
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 0.07, "output": 0.14 }
              }
            }
          },
          "deepseek": {
            "id": "deepseek",
            "models": {
              "deepseek-v4-flash": {
                "id": "deepseek-v4-flash",
                "cost": { "input": 0.14, "output": 0.28 }
              }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-new": { "id": "claude-new", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """.utf8)
        let turnContext: [String: Any] = [
            "type": "turn_context",
            "timestamp": environment.isoString(for: self.day),
            "payload": ["model": "gpt-new"],
        ]
        let tokenCount: [String: Any] = [
            "type": "event_msg",
            "timestamp": environment.isoString(for: self.day.addingTimeInterval(1)),
            "payload": [
                "type": "token_count",
                "info": [
                    "total_token_usage": [
                        "input_tokens": 100,
                        "cached_input_tokens": 20,
                        "output_tokens": 10,
                    ],
                ],
            ],
        ]
        _ = try environment.writeCodexSessionFile(
            day: self.day,
            filename: "unknown-model.jsonl",
            contents: environment.jsonl([turnContext, tokenCount]))
        self.options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot,
            codexTraceDatabaseURL: environment.root.appendingPathComponent("missing-traces.sqlite"))
    }
}

private struct CostUsageFetcherModelsDevTransport: ModelsDevHTTPTransport {
    let data: Data

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (self.data, response)
    }
}

private struct CostUsageFetcherGatedModelsDevTransport: ModelsDevHTTPTransport {
    let data: Data
    let gate: UnknownModelPricingTransportGate

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await self.gate.markStartedAndWaitForRelease()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (self.data, response)
    }
}

private actor UnknownModelPricingTransportGate {
    private var started = false
    private var released = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiters: [CheckedContinuation<Void, Never>] = []

    func markStartedAndWaitForRelease() async {
        self.started = true
        let startWaiters = self.startWaiters
        self.startWaiters.removeAll()
        startWaiters.forEach { $0.resume() }
        guard !self.released else { return }
        await withCheckedContinuation { continuation in
            self.releaseWaiters.append(continuation)
        }
    }

    func waitUntilStarted() async {
        guard !self.started else { return }
        await withCheckedContinuation { continuation in
            self.startWaiters.append(continuation)
        }
    }

    func release() {
        self.released = true
        let releaseWaiters = self.releaseWaiters
        self.releaseWaiters.removeAll()
        releaseWaiters.forEach { $0.resume() }
    }
}

private actor UnknownModelPricingCompletionProbe {
    private(set) var isCompleted = false

    func markCompleted() {
        self.isCompleted = true
    }
}

private actor UnknownModelPricingRequestCounter {
    private(set) var requestCount = 0

    func recordRequest() {
        self.requestCount += 1
    }
}

private struct CostUsageFetcherCountingModelsDevTransport: ModelsDevHTTPTransport {
    let counter: UnknownModelPricingRequestCounter

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        await self.counter.recordRequest()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: 200,
            httpVersion: nil,
            headerFields: nil)!
        return (Data(#"{"openai":{"id":"openai","models":{}}}"#.utf8), response)
    }
}
