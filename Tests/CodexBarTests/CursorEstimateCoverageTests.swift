import Foundation
import Testing
@testable import CodexBarCore

#if os(macOS)
struct CursorEstimateCoverageTests {
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private static let emptyCatalog = ModelsDevCatalog(providers: [:])

    private static func event(
        model: String = "gpt-5",
        costField: String = "",
        tokens: String = #""inputTokens":100,"outputTokens":50,"cacheReadTokens":200,"cacheWriteTokens":300"#,
        timestamp: Int64 = 1_787_011_200_000) throws -> CursorUsageEvent
    {
        let json = """
        {"timestamp":"\(timestamp)","model":"\(model)","chargedCents":5,
         "tokenUsage":{\(tokens)\(costField)}}
        """
        return try JSONDecoder().decode(CursorUsageEvent.self, from: Data(json.utf8))
    }

    private static func catalog() throws -> ModelsDevCatalog {
        let json = """
        {"openai":{"id":"openai","models":{
          "gpt-5":{"id":"gpt-5","cost":{"input":4,"output":20,"cache_read":1,"cache_write":6}}}},
         "anthropic":{"models":{
           "claude-sonnet-4-5-20250929":{"id":"claude-sonnet-4-5-20250929",
             "cost":{"input":7,"output":30,"cache_read":2,"cache_write":9}},
           "claude-4.5-sonnet-20250929":{"id":"claude-4.5-sonnet-20250929",
             "cost":{"input":99,"output":99,"cache_read":99,"cache_write":99}}
         }}}
        """
        return try JSONDecoder().decode(ModelsDevCatalog.self, from: Data(json.utf8))
    }

    @Test(arguments: [false, true])
    func `large known and unknown reports resolve cached or absent catalog once`(catalogPresent: Bool) throws {
        let env = try CostUsageTestEnvironment()
        defer { env.cleanup() }
        if catalogPresent {
            #expect(try ModelsDevCache.save(catalog: Self.catalog(), cacheRoot: env.cacheRoot))
        }
        let known = try Self.event()
        let unknown = try Self.event(model: "fixture-unknown")
        let events = (0..<2000).map { $0.isMultiple(of: 2) ? known : unknown }
        let recorder = ModelsDevCache.MetadataReadRecorder()
        let report = ModelsDevCache.withMetadataReadRecorderForTesting(recorder) {
            CursorUsageEventsFetcher.makeDailyReport(
                from: events, calendar: Self.calendar, cacheRoot: env.cacheRoot)
        }
        #expect(recorder.snapshot() == 1)
        let day = try #require(report.data.first)
        #expect(day.coverageCounts.estimated == 1000)
        #expect(day.coverageCounts.unpriced == 1000)
        if catalogPresent {
            // Four disjoint buckets, at the fixture's rates, repeated 1,000 times.
            #expect(try abs(#require(day.costUSD) - 3.4) < 1e-9)
        }

        let injectedRecorder = ModelsDevCache.MetadataReadRecorder()
        let injected = ModelsDevCache.withMetadataReadRecorderForTesting(injectedRecorder) {
            CursorUsageEventsFetcher.makeDailyReport(
                from: events,
                calendar: Self.calendar,
                modelsDevCatalog: Self.emptyCatalog,
                cacheRoot: env.cacheRoot)
        }
        #expect(injectedRecorder.snapshot() == 0)
        #expect(injected.data.first?.coverageCounts.unpriced == 1000)
    }

    @Test
    func `reported invalid and rejected token events do not resolve a catalog`() throws {
        let events = try [
            Self.event(costField: #", "totalCents":0"#),
            Self.event(costField: #", "totalCents":"0""#),
            Self.event(costField: #", "totalCents":"NaN""#),
            Self.event(tokens: #""inputTokens":-1,"outputTokens":50"#),
            Self.event(tokens: #""inputTokens":\#(Int.max),"outputTokens":1"#),
        ]
        let recorder = ModelsDevCache.MetadataReadRecorder()
        let report = ModelsDevCache.withMetadataReadRecorderForTesting(recorder) {
            CursorUsageEventsFetcher.makeDailyReport(from: events, calendar: Self.calendar)
        }
        #expect(recorder.snapshot() == 0)
        #expect(report.data.first?.requestCount == 3)
        #expect(report.data.first?.coverageCounts.priced == 2)
        #expect(report.data.first?.coverageCounts.unpriced == 1)
        #expect(report.data.first?.costUSD == nil)
    }

    @Test(arguments: [
        #""NaN""#,
        #""Infinity""#,
        #""-Infinity""#,
        #""bad""#,
        "-1",
        "true",
        "{}",
        "[]",
        #""1e999""#,
        "1e999",
    ])
    func `invalid decoded costs cannot become estimates in either same model order`(value: String) throws {
        let invalid = try Self.event(costField: ",\"totalCents\":\(value)")
        #expect(invalid.tokenUsage?.cost == .invalid)
        let estimated = try Self.event()
        let valid = try Self.event(costField: #", "totalCents":100"#)
        let missing = try Self.event(model: "fixture-unknown")
        for events in [
            [estimated, invalid], [invalid, estimated],
            [valid, estimated, invalid, missing], [missing, invalid, estimated, valid],
        ] {
            let report = CursorUsageEventsFetcher.makeDailyReport(
                from: events, calendar: Self.calendar, modelsDevCatalog: Self.emptyCatalog)
            let day = try #require(report.data.first)
            #expect(day.costUSD == nil)
            #expect(day.requestCount == events.count)
            #expect(day.coverageCounts.priced == (events.count == 4 ? 1 : 0))
            #expect(day.coverageCounts.estimated == 1)
            #expect(day.coverageCounts.unpriced == (events.count == 4 ? 2 : 1))
            #expect(day.coverageCounts.unmetered == 0)
            #expect(CursorUsageEventsFetcher.meteredCostUSD(from: events) == Double(events.count) * 0.05)
        }
    }

    @Test(arguments: [
        "claude-4.5-sonnet-20250929",
        "claude-sonnet-4-5-20250929",
        "anthropic/claude-sonnet-4-5-20250929",
    ])
    func `dated aliases preserve canonical routing and raw display`(model: String) throws {
        let report = try CursorUsageEventsFetcher.makeDailyReport(
            from: [Self.event(model: model)], calendar: Self.calendar, modelsDevCatalog: Self.catalog())
        let day = try #require(report.data.first)
        #expect(day.modelsUsed == [model])
        #expect(day.modelBreakdowns?.first?.modelName == model)
        #expect(day.coverageCounts.estimated == 1)
        #expect(try abs(#require(day.costUSD) - 0.0053) < 1e-12)
    }

    @Test
    func `historical events use their own effective price date`() throws {
        let cutoff = Int64(CostUsagePricing.codexGPT56PricingCutoff.timeIntervalSince1970 * 1000)
        let events = try [cutoff - 1, cutoff].map {
            try Self.event(model: "gpt-5.6-terra", tokens: #""inputTokens":1000"#, timestamp: $0)
        }
        let report = CursorUsageEventsFetcher.makeDailyReport(
            from: events, calendar: Self.calendar, modelsDevCatalog: Self.emptyCatalog)
        #expect(report.data.count == 2)
        #expect(try abs(#require(report.data.first?.costUSD) - 0.0025) < 1e-12)
        #expect(try abs(#require(report.data.last?.costUSD) - 0.002) < 1e-12)
    }

    @Test
    func `cursor catalog pricing is independent of an explicit native codex overlay`() throws {
        let catalog = try Self.catalog()
        let overlay = CostUsageCustomPricing.parse(Data(#"{"gpt-5":{"input":900,"output":900}}"#.utf8))
        let native = CostUsagePricing.codexCostUSD(
            model: "gpt-5",
            inputTokens: 100,
            cachedInputTokens: 0,
            outputTokens: 0,
            modelsDevCatalog: catalog,
            customPricing: overlay)
        #expect(native == 0.09)
        let report = try CursorUsageEventsFetcher.makeDailyReport(
            from: [Self.event(tokens: #""inputTokens":100"#)], calendar: Self.calendar, modelsDevCatalog: catalog)
        let cost = try #require(report.data.first?.costUSD)
        #expect(abs(cost - 0.0004) < 1e-12)
    }
}
#endif
