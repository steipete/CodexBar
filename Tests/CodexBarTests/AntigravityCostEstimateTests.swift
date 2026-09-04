import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

/// API-equivalent cost estimates for Antigravity local token history (Codex-subscription
/// behavior: local usage × public API prices, never billed). All pricing flows through the
/// on-disk models.dev catalog; unknown models stay cost-less with tokens intact.
struct AntigravityCostEstimateTests {
    private typealias Fixture = AntigravityLocalFixture

    private static var rates: [String: Any] {
        // Synthetic, deliberately distinct rates exercise every token class.
        ["input": 2, "output": 8, "cache_read": 0.5, "cache_write": 3]
    }

    /// (111 × 2 + 50 × 0.5 + 37 × 8) / 1M; the fixture blob's token mix at synthetic rates.
    /// Split into steps: Swift 6.3.3 exceeds its type-check limit on the single expression.
    private static let expectedBlobCostUSD: Double = {
        let inputCost = 111.0 * 2
        let cacheReadCost = 50.0 * 0.5
        let outputCost = 37.0 * 8
        return (inputCost + cacheReadCost + outputCost) / 1_000_000
    }()

    private static func catalog(_ rows: [String: [String: [String: Any]]]) throws -> ModelsDevCatalog {
        var payload: [String: Any] = [:]
        for (providerID, models) in rows {
            let entries = Dictionary(uniqueKeysWithValues: models.map { modelID, cost in
                (modelID, ["id": modelID, "cost": cost] as [String: Any])
            })
            payload[providerID] = ["id": providerID, "models": entries]
        }
        return try JSONDecoder().decode(
            ModelsDevCatalog.self,
            from: JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys]))
    }

    private static func googleCatalog() throws -> ModelsDevCatalog {
        try self.catalog(["google": ["gemini-test-flash": self.rates]])
    }

    private static func anthropicCatalog() throws -> ModelsDevCatalog {
        try self.catalog(["anthropic": ["claude-sonnet-4-5": self.rates]])
    }

    @Test
    func `bare gemini model ID resolves through the google catalog`() throws {
        let catalog = try Self.googleCatalog()
        let resolver = CostUsagePricing.AntigravityResolver(catalog: catalog)
        let cost = resolver.costUSD(
            model: "gemini-test-flash",
            inputTokens: 111,
            cacheReadInputTokens: 50,
            cacheCreationInputTokens: 0,
            outputTokens: 37)
        // (111 × 2 + 50 × 0.5 + 37 × 8) / 1M; reasoning is folded into output by the caller.
        let expected = Self.expectedBlobCostUSD
        #expect(try abs(#require(cost) - expected) < 1e-12)
    }

    @Test
    func `priced turn carries estimate with reasoning folded into output`() throws {
        let fixture = try Fixture()
        let blob = Fixture.blob(
            model: "gemini-test-flash", system: 11, input: 100, output: 30, cacheRead: 50, reasoning: 7)
        try fixture.database(blobs: [blob])
        let report = try fixture.report(modelsDevCatalog: Self.googleCatalog())

        #expect(report.coverage == .complete)
        let entry = try #require(report.report.data.first)
        #expect(entry.inputTokens == 111)
        #expect(entry.outputTokens == 30)
        #expect(entry.reasoningTokens == 7)
        let expected = Self.expectedBlobCostUSD
        #expect(try abs(#require(entry.costUSD) - expected) < 1e-12)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(estimated: 1))
        let breakdown = try #require(entry.modelBreakdowns?.first)
        #expect(breakdown.modelName == "gemini-test-flash")
        #expect(try abs(#require(breakdown.costUSD) - expected) < 1e-12)
        #expect(try abs(#require(report.report.summary?.totalCostUSD) - expected) < 1e-12)
    }

    @Test
    func `unpriced model stays cost-less with tokens intact`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "gemini-test-flash")])
        let report = try fixture.report(modelsDevCatalog: ModelsDevCatalog(providers: [:]))

        #expect(report.coverage == .complete)
        let entry = try #require(report.report.data.first)
        #expect(entry.inputTokens == 111)
        #expect(entry.totalTokens == 198)
        #expect(entry.costUSD == nil)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(unpriced: 1))
        #expect(entry.modelBreakdowns?.first?.costUSD == nil)
        #expect(report.report.summary?.totalCostUSD == nil)
    }

    @Test
    func `catalog only pricing does not use bundled Claude fallback`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "claude-sonnet-4-5")])
        let report = try fixture.report(modelsDevCatalog: ModelsDevCatalog(providers: [:]))

        let entry = try #require(report.report.data.first)
        #expect(entry.costUSD == nil)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(unpriced: 1))
    }

    @Test
    func `models dev catalog overrides bundled Claude price`() throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "claude-sonnet-4-5")])
        let report = try fixture.report(modelsDevCatalog: Self.anthropicCatalog())

        let entry = try #require(report.report.data.first)
        let expected = Self.expectedBlobCostUSD
        #expect(try abs(#require(entry.costUSD) - expected) < 1e-12)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(estimated: 1))
    }

    @Test
    func `merged days sum costs with nil-aware breakdowns`() throws {
        let fixture = try Fixture()
        let priced = Fixture.blob(model: "gemini-test-flash", input: 100, output: 30)
        let unpriced = Fixture.blob(model: "unknown-model-zzz", input: 200, output: 10)
        try fixture.database(blobs: [priced, unpriced])
        let report = try fixture.report(modelsDevCatalog: Self.googleCatalog())

        #expect(report.coverage == .complete)
        let entry = try #require(report.report.data.first)
        // Only the priced turn contributes; the unpriced turn neither prices nor poisons.
        let pricedCost = Self.expectedBlobCostUSD
        #expect(try abs(#require(entry.costUSD) - pricedCost) < 1e-12)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(unpriced: 1, estimated: 1))
        #expect(entry.modelBreakdowns?.count == 2)
        #expect(entry.modelBreakdowns?.first(where: { $0.modelName == "unknown-model-zzz" })?.costUSD == nil)
        #expect(try abs(#require(report.report.summary?.totalCostUSD) - pricedCost) < 1e-12)
    }

    @Test
    func `snapshot end to end prices from seeded cache and flips provenance`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "gemini-test-flash")])
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")
        #expect(try ModelsDevCache.save(catalog: Self.googleCatalog(), cacheRoot: cacheRoot))

        let snapshot = try await fixture.snapshot()

        #expect(snapshot.historyCoverageIsEstablished)
        let expected = Self.expectedBlobCostUSD
        #expect(try abs(#require(snapshot.last30DaysCostUSD) - expected) < 1e-12)
        #expect(snapshot.costProvenance == .listPriceEstimate)
    }

    @Test
    func `snapshot without catalog stays unknown with tokens intact`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(model: "gemini-test-flash")])

        let snapshot = try await fixture.snapshot()

        #expect(snapshot.historyCoverageIsEstablished)
        #expect(snapshot.last30DaysTokens == 198)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.costProvenance == .unknown)
    }

    @Test
    func `priced snapshot renders estimate title and disclaimer`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: 1.25,
            last30DaysTokens: 9000,
            last30DaysCostUSD: 9.99,
            historyDays: 30,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(
            provider: .antigravity, snapshot: snapshot, useColor: false)

        #expect(output.contains("Antigravity API-equivalent estimate (not billed)"))
        #expect(output.contains("Not a subscription bill or plan value"))
        #expect(!output.contains("dollar costs unavailable"))
    }

    @Test
    func `unpriced snapshot keeps token history text`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 1200,
            sessionCostUSD: nil,
            last30DaysTokens: 9000,
            last30DaysCostUSD: nil,
            historyDays: 30,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(
            provider: .antigravity, snapshot: snapshot, useColor: false)

        #expect(output.contains("Token History"))
        #expect(output.contains("dollar costs unavailable"))
        #expect(!output.contains("not billed"))
    }

    @Test
    func `unknown provenance ignores placeholder zero costs`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 0,
            sessionCostUSD: 0,
            last30DaysTokens: 0,
            last30DaysCostUSD: 0,
            historyDays: 30,
            costProvenance: .unknown,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))
        let output = CodexBarCLI.renderCostText(
            provider: .antigravity, snapshot: snapshot, useColor: false)

        #expect(output.contains("Token History"))
        #expect(output.contains("dollar costs unavailable"))
        #expect(!output.contains("API-equivalent estimate"))
    }

    @Test
    func `antigravity pricing targets resolve model families and routes`() {
        let gemini = CostUsagePricing.antigravityModelsDevPricingTargets(for: "gemini-2.5-flash")
        #expect(gemini.first?.providerID == "google" && gemini.first?.modelID == "gemini-2.5-flash")

        let gemma = CostUsagePricing.antigravityModelsDevPricingTargets(for: "gemma-2-9b-it")
        #expect(gemma.isEmpty)

        let claude = CostUsagePricing.antigravityModelsDevPricingTargets(for: "claude-sonnet-4-5")
        #expect(claude.first?.providerID == "anthropic" && claude.first?.modelID == "claude-sonnet-4-5")

        let gpt = CostUsagePricing.antigravityModelsDevPricingTargets(for: "gpt-oss-120b")
        #expect(gpt.first?.providerID == "openai" && gpt.first?.modelID == "gpt-oss-120b")

        let gptEffort = CostUsagePricing.antigravityModelsDevPricingTargets(for: "gpt-oss-120b-medium")
        #expect(gptEffort.first?.providerID == "openai")
        #expect(gptEffort.contains(where: { $0.modelID == "gpt-oss-120b" }))

        let gpt4o = CostUsagePricing.antigravityModelsDevPricingTargets(for: "gpt-4o")
        #expect(gpt4o.isEmpty)

        let chatgpt = CostUsagePricing.antigravityModelsDevPricingTargets(for: "chatgpt-4o-latest")
        #expect(chatgpt.isEmpty)

        let o3 = CostUsagePricing.antigravityModelsDevPricingTargets(for: "o3-mini")
        #expect(o3.isEmpty)

        let deepseek = CostUsagePricing.antigravityModelsDevPricingTargets(for: "deepseek-chat")
        #expect(deepseek.isEmpty)

        let route = CostUsagePricing.antigravityModelsDevPricingTargets(for: "google / gemini-pro ")
        #expect(route.first?.providerID == "google" && route.first?.modelID == "gemini-pro")

        let unknownRoute = CostUsagePricing.antigravityModelsDevPricingTargets(for: "unknownroute/model")
        #expect(unknownRoute.isEmpty)

        let fallback = CostUsagePricing.antigravityModelsDevPricingTargets(for: "unknown-bare-model")
        #expect(fallback.isEmpty)

        let empty = CostUsagePricing.antigravityModelsDevPricingTargets(for: "   ")
        #expect(empty.isEmpty)
    }

    @Test
    func `single day window with estimate only renders Today once`() {
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 110,
            sessionCostUSD: 0.00028,
            last30DaysTokens: 110,
            last30DaysCostUSD: 0.00028,
            historyDays: 1,
            costProvenance: .listPriceEstimate,
            daily: [],
            updatedAt: Date(timeIntervalSince1970: 0))

        let output = CodexBarCLI.renderCostText(
            provider: .antigravity,
            snapshot: snapshot,
            useColor: false)

        let lines = output.split(separator: "\n")
        #expect(lines.count(where: { $0.hasPrefix("Today:") }) == 1)
        #expect(output.contains("Antigravity API-equivalent estimate (not billed)"))
    }

    @Test
    func `mixed coverage renders disclosure line in text output`() {
        let todayKey = CostUsageLocalDay.key(from: Fixture.now, calendar: Fixture.calendar)
        let entry = CostUsageDailyReport.Entry(
            date: todayKey,
            inputTokens: 100,
            outputTokens: 10,
            totalTokens: 110,
            costUSD: 0.00028,
            modelsUsed: nil,
            modelBreakdowns: nil,
            unpricedRequestCount: 1,
            estimatedRequestCount: 1)
        let snapshot = CostUsageTokenSnapshot(
            sessionTokens: 110,
            sessionCostUSD: 0.00028,
            last30DaysTokens: 110,
            last30DaysCostUSD: 0.00028,
            historyDays: 30,
            costProvenance: .listPriceEstimate,
            daily: [entry],
            updatedAt: Fixture.now)

        let output = CodexBarCLI.renderCostText(
            provider: .antigravity, snapshot: snapshot, useColor: false)

        #expect(output.contains("Coverage: 1 estimated · 1 unpriced"))
        #expect(output.contains("Antigravity API-equivalent estimate (not billed)"))
    }

    @Test
    func `no data message cites recognized database and cache paths`() {
        let msg = AntigravityProviderDescriptor.noDataMessage(env: ["HOME": "/mock/user"])
        #expect(msg.contains("/mock/user/.gemini/antigravity-cli/conversations"))
        #expect(msg.contains("/mock/user/.config/tokscale/antigravity-cache/sessions"))
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://models.dev/api.json")!,
            statusCode: status,
            httpVersion: nil,
            headerFields: nil)!
    }

    private static func refreshableCatalogData(
        inputRate: Double = 2.0,
        googleModel: String = "gemini-test-flash") -> Data
    {
        let json = """
        {
          "openai": {
            "id": "openai",
            "models": {
              "gpt-4o-mini": { "id": "gpt-4o-mini", "cost": { "input": 0.15, "output": 0.6 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-sonnet-4-5": { "id": "claude-sonnet-4-5", "cost": { "input": 3.0, "output": 15.0 } }
            }
          },
          "google": {
            "id": "google",
            "models": {
              "\(googleModel)": { "id": "\(googleModel)", "cost": { "input": \(inputRate), "output": 8.0 } }
            }
          }
        }
        """
        return Data(json.utf8)
    }

    @Test
    func `model candidate normalizer strips thinking and effort suffixes`() {
        let candidates1 = CostUsagePricing.antigravityModelIDCandidates(for: "claude-opus-4-6-thinking")
        #expect(candidates1 == ["claude-opus-4-6-thinking", "claude-opus-4-6"])

        let candidates2 = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-3-pro-low")
        #expect(candidates2 == ["gemini-3-pro-low", "gemini-3-pro"])

        let candidates3 = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-2-5-pro")
        #expect(candidates3.contains("gemini-2-5-pro"))
        #expect(candidates3.contains("gemini-2.5-pro"))

        let candidates4 = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-3p7-flash-high")
        #expect(candidates4.contains("gemini-3p7-flash-high"))
        #expect(candidates4.contains("gemini-3p7-flash"))
        #expect(candidates4.contains("gemini-3.7-flash"))
    }

    @Test
    func `representative antigravity model IDs resolve against standard catalog entries`() throws {
        let catalogData = """
        {
          "google": {
            "id": "google",
            "models": {
              "gemini-2.5-pro": { "id": "gemini-2.5-pro", "cost": { "input": 1.25, "output": 5.0 } },
              "gemini-3-pro": { "id": "gemini-3-pro", "cost": { "input": 2.0, "output": 8.0 } }
            }
          },
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-opus-4-6": { "id": "claude-opus-4-6", "cost": { "input": 15.0, "output": 75.0 } }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(catalogData.utf8))
        let resolver = CostUsagePricing.AntigravityResolver(catalog: catalog)

        let costClaude = resolver.costUSD(
            model: "claude-opus-4-6-thinking",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 200)
        let expectedClaude = (1000.0 * 15.0 + 200.0 * 75.0) / 1_000_000
        #expect(try abs(#require(costClaude) - expectedClaude) < 1e-12)

        let costGeminiEffort = resolver.costUSD(
            model: "gemini-3-pro-low",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100)
        let expectedGeminiEffort = (1000.0 * 2.0 + 100.0 * 8.0) / 1_000_000
        #expect(try abs(#require(costGeminiEffort) - expectedGeminiEffort) < 1e-12)

        let costGeminiHyphen = resolver.costUSD(
            model: "gemini-2-5-pro",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100)
        let expectedGeminiHyphen = (1000.0 * 1.25 + 100.0 * 5.0) / 1_000_000
        #expect(try abs(#require(costGeminiHyphen) - expectedGeminiHyphen) < 1e-12)
    }

    @Test
    func `missing catalog refreshes and enables pricing`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(
            model: "gemini-test-flash", system: 0, input: 100, output: 10, cacheRead: 0, reasoning: 0)])
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")

        var options = CostUsageScanner.Options()
        options.calendar = Fixture.calendar
        options.cacheRoot = cacheRoot

        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: fixture.environment,
            now: Fixture.now,
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.last30DaysCostUSD != nil)
        #expect(snapshot.daily.first?.coverageCounts.estimated == 1)
        #expect(snapshot.daily.first?.coverageCounts.unpriced == 0)
    }

    @Test
    func `stale catalog is replaced on refresh`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(
            model: "gemini-test-flash", system: 0, input: 100, output: 10, cacheRead: 0, reasoning: 0)])
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")

        let oldCatalog = try JSONDecoder().decode(
            ModelsDevCatalog.self, from: Self.refreshableCatalogData(inputRate: 1.0))
        #expect(ModelsDevCache.save(
            catalog: oldCatalog,
            fetchedAt: Date(timeIntervalSince1970: 0),
            cacheRoot: cacheRoot))

        var options = CostUsageScanner.Options()
        options.calendar = Fixture.calendar
        options.cacheRoot = cacheRoot

        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(inputRate: 5.0), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: fixture.environment,
            now: Fixture.now,
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        let expected = (100.0 * 5 + 10.0 * 8) / 1_000_000
        #expect(try abs(#require(snapshot.last30DaysCostUSD) - expected) < 1e-12)
    }

    @Test
    func `failed refresh preserves existing prices and tokens without throwing`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(
            model: "gemini-test-flash", system: 0, input: 100, output: 10, cacheRead: 0, reasoning: 0)])
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")

        let existingCatalog = try Self.catalog(["google": ["gemini-test-flash": ["input": 2, "output": 8]]])
        #expect(ModelsDevCache.save(
            catalog: existingCatalog,
            fetchedAt: Date(timeIntervalSince1970: 1_787_830_000),
            cacheRoot: cacheRoot))

        var options = CostUsageScanner.Options()
        options.calendar = Fixture.calendar
        options.cacheRoot = cacheRoot

        enum FakeError: Error { case networkDown }
        let client = ModelsDevClient(transport: MockTransport(result: .failure(FakeError.networkDown)))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: fixture.environment,
            now: Fixture.now,
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        let expected = (100.0 * 2 + 10.0 * 8) / 1_000_000
        #expect(try abs(#require(snapshot.last30DaysCostUSD) - expected) < 1e-12)
        #expect(snapshot.last30DaysTokens == 110)
    }

    @Test
    func `unknown model triggers retry refresh and becomes priced`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(
            model: "gemini-test-flash", system: 0, input: 100, output: 10, cacheRead: 0, reasoning: 0)])
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")

        let initialData = """
        {
          "openai": {
            "id": "openai",
            "models": { "gpt-4o-mini": { "id": "gpt-4o-mini", "cost": { "input": 0.15, "output": 0.6 } } }
          },
          "anthropic": {
            "id": "anthropic",
            "models": { "claude-sonnet-4-5": { "id": "claude-sonnet-4-5", "cost": { "input": 3, "output": 15 } } }
          }
        }
        """
        let initialCatalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(initialData.utf8))
        #expect(ModelsDevCache.save(
            catalog: initialCatalog,
            fetchedAt: Date(timeIntervalSince1970: 1_787_830_000),
            cacheRoot: cacheRoot))

        var options = CostUsageScanner.Options()
        options.calendar = Fixture.calendar
        options.cacheRoot = cacheRoot

        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: fixture.environment,
            now: Fixture.now,
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client,
            retryUnknownPricing: true)

        #expect(snapshot.costProvenance == .listPriceEstimate)
        #expect(snapshot.last30DaysCostUSD != nil)
    }

    @Test
    func `background refresh does not block initial offline snapshot`() async throws {
        let fixture = try Fixture()
        try fixture.database(blobs: [Fixture.blob(
            model: "gemini-test-flash", system: 0, input: 100, output: 10, cacheRead: 0, reasoning: 0)])
        let cacheRoot = fixture.root.appendingPathComponent("scanner-cache")

        var options = CostUsageScanner.Options()
        options.calendar = Fixture.calendar
        options.cacheRoot = cacheRoot

        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: fixture.environment,
            now: Fixture.now,
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: true,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        // With background refresh, local reading completes without awaiting network. The detached
        // refresh may or may not win the race to the shared cache, so only assert the offline-complete
        // portion (tokens); foreground tests prove refresh pricing, failure tests prove preservation.
        #expect(snapshot.last30DaysTokens == 110)
        #expect(snapshot.historyCoverageIsEstablished)
    }
}

private struct MockTransport: ModelsDevHTTPTransport {
    var result: Result<(Data, URLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try self.result.get()
    }
}
