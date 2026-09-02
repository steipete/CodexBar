import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

@Suite(.serialized)
struct CostUsageClaudeKimiAliasTests {
    private static let aliases = ["k3[1m]", "kimi-coding/k3[1m]", "kimi-for-coding/k3[1m]"]

    @Test(arguments: Self.aliases)
    func `documented Claude Kimi alias prices without entering Claude snapshot`(model: String) async throws {
        let fixture = try AliasFixture(model: model)
        defer { fixture.environment.cleanup() }
        let catalog = try Self.catalog(["kimi-for-coding": ["k3": Self.rates]])
        #expect(catalog.pricing(providerID: "kimi-for-coding", modelID: "k3") != nil)
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: fixture.day, cacheRoot: fixture.environment.cacheRoot))

        let report = fixture.report()
        let row = try #require(report.data.first?.modelBreakdowns?.first)
        #expect(row.modelName == model)
        #expect(row.totalTokens == 160)
        #expect(try abs(#require(row.costUSD) - 0.000385) < 1e-12)
        let snapshot = try await fixture.snapshot()
        #expect(snapshot.daily.isEmpty)
        #expect(CostUsagePricing.normalizeClaudeModel(model) == model)
    }

    @Test(arguments: Self.aliases)
    func `subscription catalog zero is priced while absent or null rates stay unknown`(model: String) throws {
        let fixture = try AliasFixture(model: model)
        defer { fixture.environment.cleanup() }
        let zero = try Self.catalog(["kimi-for-coding": ["k3": ["input": 0, "output": 0]]])
        #expect(ModelsDevCache.save(catalog: zero, fetchedAt: fixture.day, cacheRoot: fixture.environment.cacheRoot))
        let row = try #require(fixture.report().data.first?.modelBreakdowns?.first)
        #expect(row.totalTokens == 160)
        #expect(row.costUSD == 0)
        for cost in [["output": 0], ["input": NSNull(), "output": 0]] as [[String: Any]] {
            #expect(try Self.cost(model, catalog: Self.catalog(["kimi-for-coding": ["k3": cost]])) == nil)
        }
    }

    @Test
    func `alias expansion preserves exact rows and explicit provider routes`() throws {
        let catalog = try Self.catalog([
            "kimi-coding": ["k3": ["input": 91, "output": 92]],
            "kimi-for-coding": [
                "k3": Self.rates,
                "k3[1m]": ["input": 7, "output": 11],
                "k3-256k": ["input": 13, "output": 17],
            ],
            "openai": ["k3": ["input": 97, "output": 98], "k3[1m]": ["input": 19, "output": 23]],
        ])
        for model in Self.aliases {
            #expect(Self.cost(model, catalog: catalog) == 7e-6)
        }
        #expect(Self.cost("openai/k3[1m]", catalog: catalog) == 19e-6)
        #expect(Self.cost("k3-256k", catalog: catalog) == 13e-6)
        let exactRoute = try Self.catalog([
            "kimi-coding": ["k3[1m]": ["input": 29, "output": 31]],
            "kimi-for-coding": ["k3[1m]": ["input": 7, "output": 11], "k3": Self.rates],
        ])
        #expect(Self.cost("kimi-coding/k3[1m]", catalog: exactRoute) == 29e-6)
    }

    @Test
    func `alias never guesses a different vendor or context variant`() throws {
        let catalog = try Self.catalog([
            "kimi-for-coding": ["k3": Self.rates],
            "openai": ["k3": ["input": 97, "output": 98], "k3[1m]": ["input": 19, "output": 23]],
            "moonshotai": ["k3": ["input": 41, "output": 43]],
            "moonshotai-cn": ["k3": ["input": 47, "output": 53]],
        ])
        #expect(Self.cost("k3[1m]", catalog: catalog) == 2e-6)
        for model in ["k3[2m]", "k3-256k", "kimi-k3[1m]", "anthropic/k3[1m]", "unknown/k3[1m]"] {
            #expect(Self.cost(model, catalog: catalog) == nil)
        }
        let nonKimi = try Self.catalog([
            "openai": ["k3[1m]": ["input": 19, "output": 23]],
            "moonshot": ["k3": ["input": 41, "output": 43]],
            "moonshotai": ["k3": ["input": 47, "output": 53]],
        ])
        #expect(Self.cost("k3[1m]", catalog: nonKimi) == nil)
        let canonicalOnly = try Self.catalog(["openai": ["k3": Self.rates]])
        #expect(Self.cost("openai/k3[1m]", catalog: canonicalOnly) == nil)
        #expect(!CostUsagePricing.codexModelsDevPricingTargets(for: "kimi-coding/k3[1m]")
            .contains { $0.modelID == "k3" })
    }

    @Test(arguments: Self.aliases)
    func `unknown alias requests one catalog refresh and reprices persisted tokens`(model: String) async throws {
        let fixture = try AliasFixture(model: model)
        defer { fixture.environment.cleanup() }
        let old = try Self.catalog(["kimi-for-coding": ["kimi-test-old": Self.rates]])
        #expect(ModelsDevCache.save(
            catalog: old,
            fetchedAt: fixture.day.addingTimeInterval(-901),
            cacheRoot: fixture.environment.cacheRoot))
        let first = try #require(fixture.report().data.first?.modelBreakdowns?.first)
        #expect(first.costUSD == nil)
        #expect(first.totalTokens == 160)
        let transport = try AliasCatalogTransport(data: Self.catalogData(["kimi-for-coding": ["k3": Self.rates]]))
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            environment: [:],
            now: fixture.day,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: fixture.options,
            modelsDevClient: ModelsDevClient(transport: transport))

        #expect(snapshot.daily.isEmpty)
        #expect(await transport.requestCount == 1)
        let row = try #require(fixture.report().data.first?.modelBreakdowns?.first)
        #expect(row.modelName == model)
        #expect(row.totalTokens == 160)
        #expect(try abs(#require(row.costUSD) - 0.000385) < 1e-12)
    }

    @Test
    func `fresh unknown alias reprices on warm and cold loads without rewriting transcripts or cache`() throws {
        let fixture = try AliasFixture(model: "k3[1m]", refreshMinIntervalSeconds: 3600)
        defer { fixture.environment.cleanup() }
        #expect(try ModelsDevCache.save(
            catalog: Self.catalog([:]), fetchedAt: fixture.day, cacheRoot: fixture.environment.cacheRoot))
        let first = try #require(fixture.report().data.first?.modelBreakdowns?.first)
        #expect(first.costUSD == nil)
        let cacheURL = CostUsageClaudeCacheIO.cacheFileURL(provider: .claude, cacheRoot: fixture.environment.cacheRoot)
        let cacheBefore = try Data(contentsOf: cacheURL)
        #expect(try ModelsDevCache.save(
            catalog: Self.catalog(["kimi-for-coding": ["k3": Self.rates]]),
            fetchedAt: fixture.day.addingTimeInterval(1),
            cacheRoot: fixture.environment.cacheRoot))

        for cold in [false, true] {
            if cold {
                CostUsageScanner.evictClaudeReportMemoForTesting(
                    provider: .claude,
                    cacheRoot: fixture.environment.cacheRoot)
            }
            let recorder = CostUsageScanner.ClaudeScanWorkRecorder()
            let report = CostUsageScanner.withClaudeScanWorkRecorderForTesting(recorder) { fixture.report() }
            let row = try #require(report.data.first?.modelBreakdowns?.first)
            #expect(row.modelName == "k3[1m]")
            #expect(row.totalTokens == 160)
            #expect(try abs(#require(row.costUSD) - 0.000385) < 1e-12)
            let metrics = recorder.snapshot()
            #expect(metrics.cacheDecodes == 1)
            #expect(metrics.transcriptParses == 0)
            #expect(metrics.cacheEncodes == 0)
            #expect(metrics.repricedRows == 1)
            #expect(try Data(contentsOf: cacheURL) == cacheBefore)
        }
    }

    @Test(arguments: [199_950, 199_951])
    func `alias uses existing cache and long context arithmetic`(input: Int) throws {
        var rates = Self.rates
        rates["context_over_200k"] = ["input": 4, "output": 16, "cache_read": 1, "cache_write": 6]
        let catalog = try Self.catalog(["kimi-for-coding": ["k3": rates]])
        let cost = try #require(CostUsagePricing.claudeCostUSD(
            model: "k3[1m]",
            inputTokens: input,
            cacheReadInputTokens: 20,
            cacheCreationInputTokens: 30,
            cacheCreationInputTokens1h: 5,
            outputTokens: 10,
            modelsDevCatalog: catalog))
        let multiplier = input + 50 > 200_000 ? 2.0 : 1.0
        let expected = (Double(input) * 2 + 20 * 0.5 + 25 * 3 + 5 * 4 + 10 * 8) * multiplier / 1_000_000
        #expect(abs(cost - expected) < 1e-12)
    }

    private static var rates: [String: Any] {
        // Synthetic, deliberately distinct rates exercise routing and all token classes.
        ["input": 2, "output": 8, "cache_read": 0.5, "cache_write": 3]
    }

    private static func cost(_ model: String, catalog: ModelsDevCatalog) -> Double? {
        CostUsagePricing.claudeCostUSD(
            model: model,
            inputTokens: 1,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: catalog)
    }

    private static func catalog(_ rows: [String: [String: [String: Any]]]) throws -> ModelsDevCatalog {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: self.catalogData(rows))
    }

    private static func catalogData(_ rows: [String: [String: [String: Any]]]) throws -> Data {
        var providers = rows
        providers["anthropic", default: [:]]["claude-test-pricing"] = ["input": 3, "output": 15]
        providers["openai", default: [:]]["gpt-test-pricing"] = ["input": 1, "output": 4]
        var payload: [String: Any] = [:]
        for (providerID, models) in providers {
            let rows = Dictionary(uniqueKeysWithValues: models.map { modelID, cost in
                (modelID, ["id": modelID, "cost": cost] as [String: Any])
            })
            payload[providerID] = ["id": providerID, "models": rows]
        }
        return try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
    }
}

private struct AliasFixture {
    let environment: CostUsageTestEnvironment
    let day: Date
    let options: CostUsageScanner.Options

    init(model: String, refreshMinIntervalSeconds: TimeInterval = 0) throws {
        let environment = try CostUsageTestEnvironment()
        self.environment = environment
        self.day = try environment.makeLocalNoon(year: 2026, month: 8, day: 28)
        var options = CostUsageScanner.Options(
            codexSessionsRoot: environment.codexSessionsRoot,
            claudeProjectsRoots: [environment.claudeProjectsRoot],
            cacheRoot: environment.cacheRoot,
            codexTraceDatabaseURL: environment.root.appendingPathComponent("missing-traces.sqlite"))
        options.refreshMinIntervalSeconds = refreshMinIntervalSeconds
        self.options = options
        _ = try environment.writeClaudeProjectFile(
            relativePath: "synthetic/alias.jsonl",
            contents: environment.jsonl([[
                "type": "assistant", "timestamp": environment.isoString(for: self.day),
                "sessionId": "synthetic-alias", "requestId": "synthetic-request",
                "message": [
                    "id": "synthetic-message", "model": model,
                    "usage": [
                        "input_tokens": 100, "output_tokens": 10,
                        "cache_read_input_tokens": 20, "cache_creation_input_tokens": 30,
                        "cache_creation": ["ephemeral_1h_input_tokens": 5, "ephemeral_5m_input_tokens": 25],
                    ],
                ],
            ]]))
    }

    func report() -> CostUsageDailyReport {
        CostUsageScanner.loadDailyReport(
            provider: .claude, since: self.day, until: self.day, now: self.day, options: self.options)
    }

    func snapshot() async throws -> CostUsageTokenSnapshot {
        try await CostUsageFetcher.loadTokenSnapshot(
            provider: .claude,
            environment: [:],
            now: self.day,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: self.options)
    }
}

private actor AliasCatalogTransport: ModelsDevHTTPTransport {
    let catalogData: Data
    private(set) var requestCount = 0

    init(data: Data) {
        self.catalogData = data
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.requestCount += 1
        let url = try #require(request.url)
        let response = try #require(HTTPURLResponse(
            url: url, statusCode: 200, httpVersion: nil, headerFields: nil))
        return (self.catalogData, response)
    }
}
