import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import Testing
@testable import CodexBarCore

struct OpenCodexProviderPricingTests {
    private static let now = Date(timeIntervalSince1970: 2_000_000_000)

    @Test
    func `same model is priced by its recorded provider across every snapshot breakdown`() throws {
        let catalog = try Self.catalog()
        let direct = Self.snapshot([Self.entry(provider: "openai", model: "gpt-5.4")], catalog: catalog)
        let router = Self.snapshot([Self.entry(provider: "openrouter", model: "openai/gpt-5.4")], catalog: catalog)
        #expect(abs((direct.last30DaysCostUSD ?? 0) - 0.000244) < 1e-10)
        #expect(abs((router.last30DaysCostUSD ?? 0) - 0.00142) < 1e-10)
        #expect(router.daily.first?.costUSD == router.last30DaysCostUSD)
        #expect(router.daily.first?.modelBreakdowns?.first?.costUSD == router.last30DaysCostUSD)
        #expect(router.sessions.first?.costUSD == router.last30DaysCostUSD)
        #expect(router.hourly.first?.costUSD == router.last30DaysCostUSD)
        #expect(router.costProvenance == .listPriceEstimate)
    }

    @Test
    func `unqualified subscription model uses its own catalog and legacy route still works`() throws {
        let catalog = try Self.catalog()
        let bare = Self.snapshot([Self.entry(provider: "opencode-go", model: "gpt-5.4")], catalog: catalog)
        let legacy = Self.snapshot(
            [Self.entry(provider: "openai", model: "opencode-go/gpt-5.4")], catalog: catalog)
        #expect(abs((bare.last30DaysCostUSD ?? 0) - 0.00284) < 1e-10)
        #expect(bare.last30DaysCostUSD == legacy.last30DaysCostUSD)
    }

    @Test
    func `unknown route cannot borrow OpenAI prices or subscription attribution`() {
        for provider in ["openrouter", "private-proxy", "xai", "google"] {
            let entry = Self.entry(provider: provider, model: "openai/gpt-5.4")
            let snapshot = Self.snapshot([entry], catalog: ModelsDevCatalog(providers: [:]))
            #expect(snapshot.last30DaysCostUSD == nil)
            #expect(snapshot.sessionCostUSD == nil)
            #expect(snapshot.daily.first?.unpricedRequestCount == 1)
            #expect(OpenCodexUsageFanOut.snapshotsBySubscription(
                entries: [entry], now: Self.now, historyDays: 7, calendar: Self.calendar).isEmpty)
        }
    }

    @Test
    func `router namespace does not fall through to a bare model in the same catalog`() throws {
        let catalog = try Self.catalog(routerModel: "gpt-5.4")
        let snapshot = Self.snapshot(
            [Self.entry(provider: "openrouter", model: "openai/gpt-5.4")], catalog: catalog)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test
    func `partial custom price remains unknown instead of silently falling through`() throws {
        let custom = CostUsageCustomPricing.parse(Data("""
        {"openrouter/openai/gpt-5.4":{"input":1}}
        """.utf8))
        let snapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [Self.entry(provider: "openrouter", model: "openai/gpt-5.4")],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            customPricing: custom,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: .empty)
        #expect(snapshot.last30DaysCostUSD == nil)
    }

    @Test
    func `custom pricing counts cached tokens once and partial usage remains unknown`() throws {
        let overlay = CostUsageCustomPricing.parse(Data("""
        {"openrouter/openai/gpt-5.4":{"input":10,"output":40,"cacheRead":1}}
        """.utf8))
        let snapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [Self.entry(provider: "openrouter", model: "openai/gpt-5.4")],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            customPricing: overlay,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: .empty)
        #expect(abs((snapshot.last30DaysCostUSD ?? 0) - 0.00142) < 1e-10)
        let partial = OpenCodexUsageEntry(
            requestID: "partial",
            timestamp: Self.now,
            provider: "openrouter",
            model: "openai/gpt-5.4",
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(totalTokens: 500))
        let unpriced = try Self.snapshot([partial], catalog: Self.catalog())
        #expect(unpriced.last30DaysTokens == 500)
        #expect(unpriced.last30DaysCostUSD == nil)
        #expect(unpriced.sessionCostUSD == nil)
    }

    @Test
    func `custom pricing follows canonical provider alias after explicit observed override`() throws {
        let entry = Self.entry(provider: "kimi-coding", model: "kimi-coding/k3")
        let canonical = CostUsageCustomPricing.parse(Data("""
        {"kimi-for-coding/k3":{"input":3,"output":6,"cacheRead":0.3}}
        """.utf8))
        let canonicalSnapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: canonical)
        #expect(abs((canonicalSnapshot.last30DaysCostUSD ?? 0) - 0.000306) < 1e-10)

        let explicit = CostUsageCustomPricing.parse(Data("""
        {
          "kimi-coding/k3":{"input":1,"output":2,"cacheRead":0.1},
          "kimi-for-coding/k3":{"input":3,"output":6,"cacheRead":0.3}
        }
        """.utf8))
        let explicitSnapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: explicit)
        #expect(abs((explicitSnapshot.last30DaysCostUSD ?? 0) - 0.000102) < 1e-10)
    }

    @Test
    func `raw provider custom pricing wins before normalized targets without filling missing rates`() throws {
        let entry = Self.entry(provider: "x-ai", model: "x-ai/grok-fixture")
        let explicit = CostUsageCustomPricing.parse(Data("""
        {
          "x-ai/grok-fixture":{"input":1,"output":2,"cacheRead":0.1},
          "xai/grok-fixture":{"input":3,"output":6,"cacheRead":0.3}
        }
        """.utf8))
        let explicitSnapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: explicit)
        #expect(abs((explicitSnapshot.last30DaysCostUSD ?? 0) - 0.000102) < 1e-10)

        let free = CostUsageCustomPricing.parse(Data("""
        {"x-ai/grok-fixture":{"input":0,"output":0,"cacheRead":0}}
        """.utf8))
        let freeSnapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: free)
        #expect(freeSnapshot.last30DaysCostUSD == 0)

        let incomplete = CostUsageCustomPricing.parse(Data("""
        {
          "x-ai/grok-fixture":{"input":1},
          "xai/grok-fixture":{"input":3,"output":6,"cacheRead":0.3}
        }
        """.utf8))
        let incompleteSnapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: incomplete)
        #expect(incompleteSnapshot.last30DaysCostUSD == nil)
    }

    @Test
    func `legacy OpenAI transport keeps recorded application price before routed price`() throws {
        let entry = Self.entry(provider: "openai", model: "opencode-go/gpt-5.4")
        let application = CostUsageCustomPricing.parse(Data("""
        {
          "openai/opencode-go/gpt-5.4":{"input":1,"output":2,"cacheRead":0.1},
          "gpt-5.4":{"input":3,"output":6,"cacheRead":0.3}
        }
        """.utf8))
        let snapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: application)
        #expect(abs((snapshot.last30DaysCostUSD ?? 0) - 0.000102) < 1e-10)

        let caller = CostUsageCustomPricing.parse(Data("""
        {"openai/opencode-go/gpt-5.4":{"input":4,"output":8,"cacheRead":0.4}}
        """.utf8))
        let callerSnapshot = try OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            customPricing: caller,
            modelsDevCatalog: Self.catalog(),
            customPricingOverlay: application)
        #expect(abs((callerSnapshot.last30DaysCostUSD ?? 0) - 0.000488) < 1e-10)
    }

    @Test
    func `legacy recorded application zero and incomplete rates block routed fallback`() throws {
        let entry = Self.entry(provider: "openai", model: "opencode-go/gpt-5.4")
        let catalog = try Self.catalog()
        let free = CostUsageCustomPricing.parse(Data("""
        {
          "openai/opencode-go/gpt-5.4":{"input":0,"output":0,"cacheRead":0},
          "gpt-5.4":{"input":3,"output":6,"cacheRead":0.3}
        }
        """.utf8))
        let freeSnapshot = OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: catalog,
            customPricingOverlay: free)
        #expect(freeSnapshot.last30DaysCostUSD == 0)

        let incomplete = CostUsageCustomPricing.parse(Data("""
        {
          "openai/opencode-go/gpt-5.4":{"input":1},
          "gpt-5.4":{"input":3,"output":6,"cacheRead":0.3}
        }
        """.utf8))
        let incompleteSnapshot = OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: catalog,
            customPricingOverlay: incomplete)
        #expect(incompleteSnapshot.last30DaysCostUSD == nil)
        #expect(incompleteSnapshot.daily.first?.unpricedRequestCount == 1)
    }

    @Test
    func `bare application overrides retain precedence over provider qualified overrides`() throws {
        for (provider, model) in [("openai", "gpt-5.4"), ("openai", "opencode-go/gpt-5.4")] {
            let application = CostUsageCustomPricing.parse(Data("""
            {
              "\(model)":{"input":0,"output":0,"cacheRead":0},
              "\(provider)/\(model)":{"input":3,"output":6,"cacheRead":0.3}
            }
            """.utf8))
            let snapshot = try OpenCodexUsageAggregator.snapshot(
                entries: [Self.entry(provider: provider, model: model)],
                now: Self.now,
                historyDays: 7,
                calendar: Self.calendar,
                modelsDevCatalog: Self.catalog(),
                customPricingOverlay: application)
            #expect(snapshot.last30DaysCostUSD == 0)
        }
    }

    @Test
    func `generic catalog row with consumed cache tokens and no cache rate stays unpriced`() throws {
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "anthropic":{"models":{"fixture":{"id":"fixture","cost":{"input":1,"output":2}}}},
          "openai":{"models":{"fixture":{"id":"fixture","cost":{"input":1,"output":2}}}},
          "xai":{"models":{"grok-fixture":{"id":"grok-fixture","cost":{"input":2,"output":8}}}}
        }
        """.utf8))
        let snapshot = Self.snapshot([Self.entry(provider: "xai", model: "grok-fixture")], catalog: catalog)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.first?.unpricedRequestCount == 1)
    }

    @Test
    func `cache creation is priced once and requires an explicit rate`() throws {
        let entry = OpenCodexUsageEntry(
            requestID: "cache-creation",
            timestamp: Self.now,
            provider: "openrouter",
            model: "openai/gpt-5.4",
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(
                inputTokens: 100,
                outputTokens: 10,
                cachedInputTokens: 20,
                cacheCreationInputTokens: 30,
                totalTokens: 160))
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {"openrouter":{"models":{"openai/gpt-5.4":{"id":"openai/gpt-5.4",\
        "cost":{"input":10,"output":40,"cache_read":1,"cache_write":5}}}}}
        """.utf8))
        let overlay = CostUsageCustomPricing.parse(Data("""
        {"openrouter/openai/gpt-5.4":{"input":10,"output":40,"cacheRead":1,"cacheWrite":5}}
        """.utf8))
        let catalogSnapshot = Self.snapshot([entry], catalog: catalog)
        let overlaySnapshot = OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: Self.now,
            historyDays: 7,
            calendar: Self.calendar,
            customPricing: overlay,
            modelsDevCatalog: catalog,
            customPricingOverlay: .empty)
        for snapshot in [catalogSnapshot, overlaySnapshot] {
            let cost = try #require(snapshot.last30DaysCostUSD)
            #expect(abs(cost - 0.00157) < 1e-10)
            #expect(snapshot.sessionCostUSD == cost)
            #expect(snapshot.daily.first?.costUSD == cost)
            #expect(snapshot.sessions.first?.costUSD == cost)
            #expect(snapshot.hourly.first?.costUSD == cost)
        }

        let unpriced = try Self.snapshot([entry], catalog: Self.catalog())
        #expect(unpriced.last30DaysTokens == 160)
        #expect(unpriced.last30DaysCostUSD == nil)
        #expect(unpriced.sessionCostUSD == nil)
        #expect(unpriced.daily.first?.unpricedRequestCount == 1)
    }

    @Test
    func `cache-only rows preserve complete free and missing cache prices`() throws {
        let entry = OpenCodexUsageEntry(
            requestID: "cache-only",
            timestamp: Self.now,
            provider: "openrouter",
            model: "openai/gpt-5.4",
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(inputTokens: 0, outputTokens: 0, cacheCreationInputTokens: 30))
        let cases: [(Double?, Double?)] = [(5, 0.00015), (0, 0), (nil, nil)]
        for (rate, expected) in cases {
            let catalog = try Self.catalog(cacheWrite: rate)
            let overlay = CostUsageCustomPricing(entries: [
                "openrouter/openai/gpt-5.4": .init(input: 10, output: 40, cacheRead: 1, cacheWrite: rate),
            ], fingerprint: "cache-only-fixture")
            var snapshots = [Self.snapshot([entry], catalog: catalog)]
            for callerOverride in [true, false] {
                snapshots.append(OpenCodexUsageAggregator.snapshot(
                    entries: [entry],
                    now: Self.now,
                    historyDays: 7,
                    calendar: Self.calendar,
                    customPricing: callerOverride ? overlay : .empty,
                    modelsDevCatalog: catalog,
                    customPricingOverlay: callerOverride ? .empty : overlay))
            }
            for snapshot in snapshots {
                #expect(snapshot.last30DaysTokens == 30)
                if let expected {
                    let cost = try #require(snapshot.last30DaysCostUSD)
                    #expect(abs(cost - expected) < 1e-10)
                    #expect(snapshot.sessionCostUSD == cost)
                } else {
                    #expect(snapshot.last30DaysCostUSD == nil)
                    #expect(snapshot.sessionCostUSD == nil)
                }
                #expect(snapshot.daily.first?.unpricedRequestCount == (expected == nil ? 1 : 0))
            }
        }
    }

    @Test
    func `independent cache conversion overflow stays unpriced`() throws {
        let entry = OpenCodexUsageEntry(
            requestID: "cache-overflow",
            timestamp: Self.now,
            provider: "openrouter",
            model: "openai/gpt-5.4",
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(inputTokens: Int.max, outputTokens: 0, cacheCreationInputTokens: 1))
        let snapshot = try Self.snapshot([entry], catalog: Self.catalog(cacheWrite: 5))
        #expect(snapshot.last30DaysTokens == nil)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.sessionCostUSD == nil)
        #expect(snapshot.daily.first?.unpricedRequestCount == 1)
    }

    @Test
    func `direct and legacy routed rows keep historical application and independent caller conventions`() throws {
        for model in ["gpt-5.4", "opencode-go/gpt-5.4"] {
            let overlay = CostUsageCustomPricing(entries: [
                model: .init(input: 10, output: 40, cacheRead: 1),
            ], fingerprint: "historical-openai-fixture")
            let entry = Self.entry(provider: "openai", model: model)
            let application = try OpenCodexUsageAggregator.snapshot(
                entries: [entry],
                now: Self.now,
                historyDays: 7,
                calendar: Self.calendar,
                modelsDevCatalog: Self.catalog(),
                customPricingOverlay: overlay)
            let caller = try OpenCodexUsageAggregator.snapshot(
                entries: [entry],
                now: Self.now,
                historyDays: 7,
                calendar: Self.calendar,
                customPricing: overlay,
                modelsDevCatalog: Self.catalog(),
                customPricingOverlay: .empty)
            let applicationCost = try #require(application.last30DaysCostUSD)
            let callerCost = try #require(caller.last30DaysCostUSD)
            #expect(abs(applicationCost - 0.00122) < 1e-10)
            #expect(abs(callerCost - 0.00142) < 1e-10)
        }
    }

    @Test
    func `fresh catalog miss refreshes router namespace and reprices without reparsing usage`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try Self.catalog(routerModel: "gpt-5.4")
        #expect(ModelsDevCache.save(catalog: before, fetchedAt: Self.now.addingTimeInterval(-901), cacheRoot: root))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let log = root.appendingPathComponent("usage.jsonl")
        try Data("""
        {"requestId":"persisted","timestamp":2000000000,"provider":"openrouter","model":"openai/gpt-5.4",\
        "usageStatus":"reported","usage":{"inputTokens":100,"outputTokens":10,"cachedInputTokens":20,"totalTokens":110}}

        """.utf8).write(to: log)
        let store = OpenCodexUsageStore(cacheRoot: root)
        let entries = try store.loadEntries(logURL: log)
        #expect(Self.snapshot(entries, catalog: before).last30DaysCostUSD == nil)
        let transport = try PricingTransport(catalog: Self.catalog())
        await OpenCodexUsageStore.refreshPricingIfNeeded(
            entries: entries, now: Self.now, cacheRoot: root, client: ModelsDevClient(transport: transport))
        let refreshed = try #require(ModelsDevCache.load(now: Self.now, cacheRoot: root).artifact?.catalog)
        #expect(abs((Self.snapshot(entries, catalog: refreshed).last30DaysCostUSD ?? 0) - 0.00142) < 1e-10)
        #expect(await transport.calls == 1)
        let recorder = OpenCodexUsageParser.LogReadRecorder()
        let cachedEntries = try OpenCodexUsageStore.withLogReadRecorderForTesting(recorder) {
            try store.loadEntries(logURL: log)
        }
        #expect(cachedEntries == entries)
        #expect(recorder.snapshot().bytesRead == 0)
        await OpenCodexUsageStore.refreshPricingIfNeeded(
            entries: entries, now: Self.now, cacheRoot: root, client: ModelsDevClient(transport: transport))
        #expect(await transport.calls == 1)
    }

    @Test
    func `stale price refresh changes costs while failure preserves the last good rates`() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let old = try Self.catalog(routerInput: 5)
        #expect(ModelsDevCache.save(
            catalog: old, fetchedAt: Self.now.addingTimeInterval(-90000), cacheRoot: root))
        let entries = [Self.entry(provider: "openrouter", model: "openai/gpt-5.4")]
        let transport = try PricingTransport(catalog: Self.catalog())
        await OpenCodexUsageStore.refreshPricingIfNeeded(
            entries: entries, now: Self.now, cacheRoot: root, client: ModelsDevClient(transport: transport))
        let refreshed = try #require(ModelsDevCache.load(now: Self.now, cacheRoot: root).artifact?.catalog)
        #expect(Self.snapshot(entries, catalog: old).last30DaysCostUSD
            != Self.snapshot(entries, catalog: refreshed).last30DaysCostUSD)
        let failure = try PricingTransport(catalog: Self.catalog(), fail: true)
        await OpenCodexUsageStore.refreshPricingIfNeeded(
            entries: entries,
            now: Self.now.addingTimeInterval(90000),
            cacheRoot: root,
            client: ModelsDevClient(transport: failure))
        #expect(ModelsDevCache.load(cacheRoot: root).artifact?.catalog == refreshed)
        #expect(await failure.calls == 1)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static func entry(provider: String, model: String) -> OpenCodexUsageEntry {
        OpenCodexUsageEntry(
            requestID: "request",
            timestamp: self.now,
            provider: provider,
            model: model,
            usageStatus: .reported,
            usage: OpenCodexTokenUsage(inputTokens: 100, outputTokens: 10, cachedInputTokens: 20, totalTokens: 110))
    }

    private static func snapshot(
        _ entries: [OpenCodexUsageEntry], catalog: ModelsDevCatalog) -> CostUsageTokenSnapshot
    {
        OpenCodexUsageAggregator.snapshot(
            entries: entries,
            now: self.now,
            historyDays: 7,
            calendar: self.calendar,
            modelsDevCatalog: catalog,
            customPricingOverlay: .empty)
    }

    private static func catalog(
        routerModel: String = "openai/gpt-5.4",
        routerInput: Double = 10,
        cacheWrite: Double? = nil) throws -> ModelsDevCatalog
    {
        try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "openai":{"models":{"gpt-5.4":{"id":"gpt-5.4","cost":{"input":2,"output":8,"cache_read":0.2}}}},
          "anthropic":{"models":{"fixture":{"id":"fixture","cost":{"input":1,"output":2}}}},
          "opencode-go":{"models":{"gpt-5.4":{"id":"gpt-5.4","cost":{"input":20,"output":80,"cache_read":2}}}},
          "xai":{"models":{"grok-fixture":{
            "id":"grok-fixture","cost":{"input":30,"output":60,"cache_read":3}
          }}},
          "openrouter":{"models":{"\(routerModel)":{
            "id":"\(routerModel)","cost":{"input":\(routerInput),"output":40,"cache_read":1,\
            "cache_write":\(cacheWrite.map { String($0) } ?? "null")}
          }}}
        }
        """.utf8))
    }
}

private actor PricingTransport: ModelsDevHTTPTransport {
    private let data: Data
    private let fail: Bool
    private(set) var calls = 0

    init(catalog: ModelsDevCatalog, fail: Bool = false) throws {
        self.data = try JSONEncoder().encode(catalog)
        self.fail = fail
    }

    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        self.calls += 1
        if self.fail { throw URLError(.notConnectedToInternet) }
        return (self.data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }
}
