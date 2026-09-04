import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCLI
@testable import CodexBarCore

struct AntigravityCostEstimateLinuxTests {
    private static func catalog() throws -> ModelsDevCatalog {
        let json = """
        {"google":{"id":"google","models":{
          "gemini-test-flash":{"id":"gemini-test-flash",
            "cost":{"input":2,"output":8,"cache_read":0.5,"cache_write":3}}
        }}}
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    @Test
    func `concurrent catalog readers always observe a complete atomic replacement`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("models-dev-races-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = try Self.catalog()
        let base = Date(timeIntervalSince1970: 3_000_000)
        #expect(ModelsDevCache.save(catalog: catalog, fetchedAt: base, cacheRoot: root))
        let cacheURL = ModelsDevCache.cacheFileURL(cacheRoot: root)

        try await withThrowingTaskGroup(of: Void.self) { group in
            for writer in 0..<8 {
                group.addTask {
                    for write in 0..<16 {
                        await Task.yield()
                        let offset = writer * 16 + write + 1
                        guard ModelsDevCache.save(
                            catalog: catalog,
                            fetchedAt: base.addingTimeInterval(TimeInterval(offset)),
                            cacheRoot: root)
                        else {
                            throw ConcurrentCatalogSaveError.saveFailed
                        }
                    }
                }
            }
            group.addTask {
                for _ in 0..<2048 {
                    await Task.yield()
                    let data = try Data(contentsOf: cacheURL)
                    let decoder = JSONDecoder()
                    decoder.dateDecodingStrategy = .iso8601
                    let artifact = try decoder.decode(ModelsDevCacheArtifact.self, from: data)
                    guard artifact.version == ModelsDevCache.artifactVersion,
                          artifact.catalog.providers["google"]?.models["gemini-test-flash"] != nil
                    else {
                        throw ConcurrentCatalogSaveError.incompleteArtifact
                    }
                }
            }
            try await group.waitForAll()
        }

        let leftovers = try FileManager.default.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasPrefix(".tmp-") || $0.hasPrefix(".bak-") }
        #expect(leftovers.isEmpty)
    }

    @Test
    func `catalog only pricing does not use bundled Claude fallback`() {
        let resolver = CostUsagePricing.AntigravityResolver(catalog: ModelsDevCatalog(providers: [:]))

        #expect(resolver.costUSD(
            model: "claude-sonnet-4-5",
            inputTokens: 100,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 10) == nil)
    }

    @Test
    func `mixed local history preserves estimate and unpriced coverage`() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-cost-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let lines = [
            #"{"type":"usage","sessionId":"cost-fixture","modelId":"gemini-test-flash","#
                + #""input":100,"output":10,"timestamp":1787832000000}"#,
            #"{"type":"usage","sessionId":"cost-fixture","modelId":"unknown-model-zzz","#
                + #""input":200,"output":20,"timestamp":1787832000000}"#,
        ]
        try (lines.joined(separator: "\n") + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)

        let result = try AntigravityLocalReader.makeDailyReportWithStatus(
            context: context,
            calendar: CostUsageBucketTimeZone.calendar(identifier: "UTC"),
            modelsDevCatalog: Self.catalog())

        let entry = try #require(result.report.data.first)
        #expect(result.coverage == .complete)
        #expect(entry.requestCount == 2)
        #expect(entry.coverageCounts == CostUsageCoverageCounts(unpriced: 1, estimated: 1))
        #expect(try abs(#require(entry.costUSD) - 0.00028) < 1e-12)
    }

    @Test
    func `mixed coverage renders disclosure line in text output`() {
        let now = Date(timeIntervalSince1970: 1_787_832_000)
        let calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let todayKey = CostUsageLocalDay.key(from: now, calendar: calendar)
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
            updatedAt: now)

        let output = CodexBarCLI.renderCostText(
            provider: .antigravity,
            snapshot: snapshot,
            useColor: false)

        #expect(output.contains("Coverage: 1 estimated · 1 unpriced"))
        #expect(output.contains("Antigravity API-equivalent estimate (not billed)"))
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
            provider: .antigravity,
            snapshot: snapshot,
            useColor: false)

        #expect(output.contains("Antigravity Token History"))
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
    func `reasoning tokens are billed at output rates`() throws {
        let catalog = try Self.catalog()
        let resolver = CostUsagePricing.AntigravityResolver(catalog: catalog)
        let cost = resolver.costUSD(
            model: "gemini-test-flash",
            inputTokens: 100,
            cacheReadInputTokens: 50,
            cacheCreationInputTokens: 20,
            outputTokens: 10 + 5)
        let expected: Double = (200.0 + 25.0 + 60.0 + 120.0) / 1_000_000.0
        #expect(try abs(#require(cost) - expected) < 1e-12)
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
    func `snapshot end to end prices from seeded cache and flips provenance`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-cost-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let line = #"{"type":"usage","sessionId":"cost-fixture","modelId":"gemini-test-flash","#
            + #""input":100,"output":10,"timestamp":1787832000000}"#
        try (line + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("scanner-cache")
        #expect(try ModelsDevCache.save(catalog: Self.catalog(), cacheRoot: cacheRoot))

        var options = CostUsageScanner.Options()
        options.cacheRoot = cacheRoot
        options.calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")
        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": root.path],
            now: Date(timeIntervalSince1970: 1_787_832_000),
            forceRefresh: true,
            allowPricingRefresh: false,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options)

        let expected = (100.0 * 2 + 10.0 * 8) / 1_000_000.0
        #expect(try abs(#require(snapshot.last30DaysCostUSD) - expected) < 1e-12)
        #expect(snapshot.costProvenance == .listPriceEstimate)
    }

    @Test
    func `model candidate normalizer strips thinking and effort suffixes`() {
        let claude = CostUsagePricing.antigravityModelIDCandidates(for: "claude-opus-4-6-thinking")
        #expect(claude.contains("claude-opus-4-6"))

        let geminiLow = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-3-pro-low")
        #expect(geminiLow.contains("gemini-3-pro"))

        let geminiHyphen = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-2-5-pro")
        #expect(geminiHyphen.contains("gemini-2.5-pro"))

        let geminiCombined = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-2-5-pro-low")
        #expect(geminiCombined.contains("gemini-2.5-pro"))

        let geminiPNotation = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-3p7-flash-exp-c")
        #expect(geminiPNotation.contains("gemini-3.7-flash-exp-c"))

        let unknown = CostUsagePricing.antigravityModelIDCandidates(for: "gemini-model-customsuffix")
        #expect(!unknown.contains("gemini-model"))
    }

    @Test
    func `representative antigravity model IDs resolve against standard catalog entries`() throws {
        let json = """
        {
          "anthropic": {
            "id": "anthropic",
            "models": {
              "claude-opus-4-6": { "id": "claude-opus-4-6", "cost": { "input": 5, "output": 25 } }
            }
          },
          "google": {
            "id": "google",
            "models": {
              "gemini-3-pro": { "id": "gemini-3-pro", "cost": { "input": 2, "output": 10 } },
              "gemini-2.5-pro": { "id": "gemini-2.5-pro", "cost": { "input": 1.25, "output": 10 } }
            }
          }
        }
        """
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
        let resolver = CostUsagePricing.AntigravityResolver(catalog: catalog)

        let claudeCost = resolver.costUSD(
            model: "claude-opus-4-6-thinking",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100)
        #expect(claudeCost != nil)

        let geminiLowCost = resolver.costUSD(
            model: "gemini-3-pro-low",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100)
        #expect(geminiLowCost != nil)

        let geminiHyphenCost = resolver.costUSD(
            model: "gemini-2-5-pro",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100)
        #expect(geminiHyphenCost != nil)

        let geminiCombinedCost = resolver.costUSD(
            model: "gemini-2-5-pro-low",
            inputTokens: 1000,
            cacheReadInputTokens: 0,
            cacheCreationInputTokens: 0,
            outputTokens: 100)
        #expect(geminiCombinedCost != nil)
    }

    private static func response(status: Int) -> HTTPURLResponse {
        HTTPURLResponse(
            url: URL(string: "https://models.dev/api.json")!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: [:] as [String: String])!
    }

    private static func refreshableCatalogData(
        googleModel: String = "gemini-test-flash",
        inputRate: Double = 2.0) -> Data
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
    func `missing catalog refreshes and enables pricing`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-refresh-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let line = #"{"type":"usage","sessionId":"refresh-fixture","modelId":"gemini-test-flash","#
            + #""input":100,"output":10,"timestamp":1787832000000}"#
        try (line + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("scanner-cache")

        var options = CostUsageScanner.Options()
        options.cacheRoot = cacheRoot
        options.calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": root.path],
            now: Date(timeIntervalSince1970: 1_787_832_000),
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-stale-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let line = #"{"type":"usage","sessionId":"stale-fixture","modelId":"gemini-test-flash","#
            + #""input":100,"output":10,"timestamp":1787832000000}"#
        try (line + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("scanner-cache")

        // Pre-seed stale cache with old rate (1.0) and ancient timestamp
        let oldCatalog = try JSONDecoder().decode(
            ModelsDevCatalog.self, from: Self.refreshableCatalogData(inputRate: 1.0))
        #expect(ModelsDevCache.save(
            catalog: oldCatalog,
            fetchedAt: Date(timeIntervalSince1970: 0),
            cacheRoot: cacheRoot))

        var options = CostUsageScanner.Options()
        options.cacheRoot = cacheRoot
        options.calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

        // Mock transport returns fresh catalog with updated rate (5.0)
        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(inputRate: 5.0), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": root.path],
            now: Date(timeIntervalSince1970: 1_787_832_000),
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        let expected = (100.0 * 5 + 10.0 * 8) / 1_000_000.0
        #expect(try abs(#require(snapshot.last30DaysCostUSD) - expected) < 1e-12)
    }

    @Test
    func `failed refresh preserves existing prices and tokens without throwing`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-fail-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let line = #"{"type":"usage","sessionId":"fail-fixture","modelId":"gemini-test-flash","#
            + #""input":100,"output":10,"timestamp":1787832000000}"#
        try (line + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("scanner-cache")

        let existingCatalog = try Self.catalog()
        #expect(ModelsDevCache.save(
            catalog: existingCatalog,
            fetchedAt: Date(timeIntervalSince1970: 1_787_830_000),
            cacheRoot: cacheRoot))

        var options = CostUsageScanner.Options()
        options.cacheRoot = cacheRoot
        options.calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

        enum FakeError: Error { case networkDown }
        let client = ModelsDevClient(transport: MockTransport(result: .failure(FakeError.networkDown)))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": root.path],
            now: Date(timeIntervalSince1970: 1_787_832_000),
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: false,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        let expected = (100.0 * 2 + 10.0 * 8) / 1_000_000.0
        #expect(try abs(#require(snapshot.last30DaysCostUSD) - expected) < 1e-12)
        #expect(snapshot.last30DaysTokens == 110)
    }

    @Test
    func `unknown model triggers retry refresh and becomes priced`() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-retry-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let line = #"{"type":"usage","sessionId":"retry-fixture","modelId":"gemini-test-flash","#
            + #""input":100,"output":10,"timestamp":1787832000000}"#
        try (line + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("scanner-cache")

        // Initial catalog only has gpt-4o-mini (gemini-test-flash is unknown)
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
        options.cacheRoot = cacheRoot
        options.calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

        // Refreshed catalog contains gemini-test-flash
        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": root.path],
            now: Date(timeIntervalSince1970: 1_787_832_000),
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
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("antigravity-bg-linux-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let context = AntigravityLocalReader.Context(environment: ["HOME": root.path])
        try FileManager.default.createDirectory(at: context.cacheRoot, withIntermediateDirectories: true)
        let line = #"{"type":"usage","sessionId":"bg-fixture","modelId":"gemini-test-flash","#
            + #""input":100,"output":10,"timestamp":1787832000000}"#
        try (line + "\n").write(
            to: context.cacheRoot.appendingPathComponent("session.jsonl"),
            atomically: true,
            encoding: .utf8)
        let cacheRoot = root.appendingPathComponent("scanner-cache")

        var options = CostUsageScanner.Options()
        options.cacheRoot = cacheRoot
        options.calendar = CostUsageBucketTimeZone.calendar(identifier: "UTC")

        let client = ModelsDevClient(transport: MockTransport(
            result: .success((Self.refreshableCatalogData(), Self.response(status: 200)))))

        let snapshot = try await CostUsageFetcher.loadTokenSnapshot(
            provider: .antigravity,
            environment: ["HOME": root.path],
            now: Date(timeIntervalSince1970: 1_787_832_000),
            forceRefresh: true,
            allowPricingRefresh: true,
            refreshPricingInBackground: true,
            includePiSessions: false,
            scannerOptions: options,
            modelsDevClient: client)

        // With background refresh, local reading completes first without awaiting network
        #expect(snapshot.last30DaysTokens == 110)
        #expect(snapshot.historyCoverageIsEstablished)
    }
}

private enum ConcurrentCatalogSaveError: Error {
    case saveFailed
    case incompleteArtifact
}

private struct MockTransport: ModelsDevHTTPTransport {
    var result: Result<(Data, URLResponse), Error>

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try self.result.get()
    }
}
