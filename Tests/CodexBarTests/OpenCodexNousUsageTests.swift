import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

struct OpenCodexNousUsageTests {
    /// Verbatim sanitized samples from #4008, issuecomment-5843400899. Their redacted request IDs collide,
    /// so aggregation tests consume each row independently; the producer hashes session/model/time for unique IDs.
    private static func entries() throws -> [OpenCodexUsageEntry] {
        let url = try #require(Bundle.module.url(
            forResource: "usage",
            withExtension: "jsonl",
            subdirectory: "Fixtures/Providers/Nous"))
        return try OpenCodexUsageParser.parse(fileURL: url)
    }

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    @Test
    func `sanitized Hermes extractor rows preserve the OpenCodex schema`() throws {
        let entries = try Self.entries()
        #expect(entries.map(\.provider) == ["nous", "nous", "nous"])
        #expect(entries.map(\.requestID) == Array(repeating: "nous-XXXXXXXXXXXXXXXX", count: 3))
        #expect(entries.map(\.model) == [
            "anthropic/claude-sonnet-4.6", "z-ai/glm-5.3-flash", "deepseek/deepseek-v4-flash-0731",
        ])
        #expect(entries.map(\.timestamp) == [1_777_362_346.46, 1_788_143_082.41, 1_785_982_323.12].map {
            Date(timeIntervalSince1970: $0)
        })
        #expect(entries.map(\.usageStatus) == [.estimated, .estimated, .estimated])
        #expect(entries.map(\.surface) == Array(repeating: "hermes-gateway", count: 3))
        #expect(entries.map(\.usage) == [
            OpenCodexTokenUsage(
                inputTokens: 22411,
                outputTokens: 5,
                cacheReadInputTokens: 0,
                cacheCreationInputTokens: 0,
                reasoningOutputTokens: 0,
                totalTokens: 22416),
            OpenCodexTokenUsage(
                inputTokens: 28341,
                outputTokens: 77,
                cacheReadInputTokens: 3520,
                cacheCreationInputTokens: 0,
                reasoningOutputTokens: 66,
                totalTokens: 31998),
            OpenCodexTokenUsage(
                inputTokens: 754_741,
                outputTokens: 28710,
                cacheReadInputTokens: 7_528_192,
                cacheCreationInputTokens: 0,
                reasoningOutputTokens: 17239,
                totalTokens: 8_303_882),
        ])
        #expect(entries.allSatisfy { $0.totalTokens == nil && $0.conversationID == nil })
    }

    @Test(arguments: [0, 1, 2])
    func `Nous fan-out keeps the billing provider and token totals`(index: Int) throws {
        let entry = try Self.entries()[index]
        let pricing = CostUsageCustomPricing(entries: [
            "nous/\(entry.model)": .init(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3),
        ], fingerprint: "nous-fixture")
        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: [entry],
            now: entry.timestamp,
            historyDays: 7,
            calendar: Self.calendar,
            customPricing: pricing)
        #expect(Set(snapshots.keys) == [.nous])
        let snapshot = try #require(snapshots[.nous])
        #expect(snapshot.last30DaysTokens == entry.resolvedTotalTokens)
        let cost = try #require(snapshot.last30DaysCostUSD)
        let expected = [0.044862, 0.059058, 5.503258][index]
        #expect(abs(cost - expected) < 1e-10)
        #expect(snapshot.daily.first?.estimatedRequestCount == 1)
        #expect((snapshot.daily.first?.pricedRequestCount ?? 0) == 0)
        #expect(snapshot.daily.first?.modelBreakdowns?.first?.modelName == entry.model)
    }

    @Test(arguments: [false, true])
    func `Nous estimates require exact Nous catalog prices and ignore Hermes metadata`(hasNousPrice: Bool) throws {
        let entry = try Self.entries()[0]
        let nousModels = hasNousPrice
            ? #""anthropic/claude-sonnet-4.6":{"id":"anthropic/claude-sonnet-4.6","cost":{"input":2,"output":8}}"#
            : #""claude-sonnet-4.6":{"id":"claude-sonnet-4.6","cost":{"input":20,"output":80}}"#
        let catalog = try JSONDecoder().decode(ModelsDevCatalog.self, from: Data("""
        {
          "nous":{"models":{\(nousModels)}},
          "anthropic":{"models":{"claude-sonnet-4.6":{
            "id":"claude-sonnet-4.6","cost":{"input":20,"output":80}
          }}}
        }
        """.utf8))
        let snapshot = OpenCodexUsageAggregator.snapshot(
            entries: [entry],
            now: entry.timestamp,
            historyDays: 7,
            calendar: Self.calendar,
            modelsDevCatalog: catalog,
            customPricingOverlay: .empty)
        #expect(snapshot.last30DaysTokens == 22416)
        #expect(snapshot.last30DaysCostUSD == (hasNousPrice ? 0.044862 : nil))
        #expect(snapshot.daily.first?.estimatedRequestCount == (hasNousPrice ? 1 : 0))
        #expect(snapshot.daily.first?.unpricedRequestCount == (hasNousPrice ? 0 : 1))
        #expect((snapshot.daily.first?.pricedRequestCount ?? 0) == 0)
        #expect(snapshot.meteredCostUSD == nil)
    }

    @Test
    func `extractor unreported rows keep tokens without inventing spend`() throws {
        let entry = try #require(OpenCodexUsageParser.parseLine("""
        {"requestId":"nous-synthetic-unreported","timestamp":1777362346.46,"provider":"nous",\
        "model":"fixture-model","usageStatus":"unreported","usage":{"inputTokens":10,"outputTokens":2,\
        "cacheReadInputTokens":3,"cacheCreationInputTokens":4,"reasoningOutputTokens":1,"totalTokens":15},\
        "surface":"hermes-gateway","conversationID":"synthetic-session",\
        "_meta":{"apiCalls":1,"hermesEstimatedCostUSD":0,"costSource":null}}
        """))
        let snapshots = OpenCodexUsageFanOut.snapshotsBySubscription(
            entries: [entry],
            now: entry.timestamp,
            historyDays: 7,
            calendar: Self.calendar,
            customPricing: CostUsageCustomPricing(entries: [
                "nous/fixture-model": .init(input: 2, output: 8, cacheRead: 0.5, cacheWrite: 3),
            ], fingerprint: "nous-unreported-fixture"))
        let snapshot = try #require(snapshots[.nous])
        #expect(snapshot.last30DaysTokens == 15)
        #expect(snapshot.last30DaysCostUSD == nil)
        #expect(snapshot.daily.first?.unpricedRequestCount == 1)
        // The producer's uppercase ID extension is not the schema's conversationId.
        #expect(entry.conversationID == nil)
    }

    @MainActor
    @Test(arguments: [true, false])
    func `Nous dashboard attribution uses the opt-in OpenCodex source without native cost support`(
        enabled: Bool) throws
    {
        let entry = try Self.entries()[0]
        let request = SpendDashboardLoadRequest(
            configuration: SpendDashboardConfiguration(
                costUsageEnabled: true,
                providerIDs: [],
                codexAccountIdentities: [],
                openCodexUsageLogsEnabled: enabled),
            capturedInputs: [],
            unavailableSourceIDs: [],
            codexRequests: [],
            now: entry.timestamp,
            force: false)
        let result = SpendDashboardSource.mergingOpenCodexInputsWithObservation(
            [],
            request: request,
            environment: ["OPENCODEX_HOME": "/synthetic/opencodex"],
            entryLoader: { _ in
                #expect(enabled)
                return [entry]
            })
        #expect(!NousProviderDescriptor.descriptor.tokenCost.supportsTokenCost)
        #expect(result.observation == (enabled ? .available : .disabled))
        #expect(result.inputs.count == (enabled ? 1 : 0))
        if enabled {
            let input = try #require(result.inputs.first)
            #expect(input.provider == .nous)
            #expect(input.sourceKind == .openCodex)
            #expect(input.displayName == "Nous Portal")
            #expect(input.snapshot.last30DaysTokens == 22416)
            #expect(input.snapshot.meteredCostUSD == nil)
            let model = SpendDashboardModel.build(
                inputs: result.inputs, requestedDays: 7, now: entry.timestamp, calendar: Self.calendar)
            let row = try #require(model.groups.first?.providers.first)
            #expect(row.provider == .nous)
            #expect(row.sourceKind == .openCodex)
            #expect(row.totalTokens == 22416)
        }
    }
}
