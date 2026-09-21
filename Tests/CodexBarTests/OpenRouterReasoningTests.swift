import Foundation
import Testing
@testable import CodexBarCore

struct OpenRouterReasoningTests {
    @Test(arguments: BundledPluginTestSupport.engines)
    func `reasoning above completion preserves the complete window and independent counters`(
        engine: ProviderPluginEngineKind) async throws
    {
        let usage = try await OpenRouterReasoningTestSupport.snapshot(engine: engine)
        let cost = try #require(usage.costUsage)
        #expect(usage.primary?.usedPercent == 25)
        #expect(usage.detailRow(label: "Remaining")?.value == "$60.00")
        #expect(usage.detailRow(label: "Last 30 days")?.value != "Unavailable right now")
        #expect(cost.historyDays == 30)
        #expect(cost.historyCoverageIsEstablished)
        #expect(cost.costProvenance == .vendorMetered)
        #expect(cost.last30DaysCostUSD == 0.875)
        #expect(cost.last30DaysTokens == 923)
        #expect(cost.last30DaysRequests == 3)
        #expect(cost.daily.count == 2)

        let day = try #require(cost.daily.first { $0.date == "2026-08-17" })
        #expect(day.inputTokens == 500)
        #expect(day.outputTokens == 400)
        #expect(day.reasoningTokens == 412)
        #expect(day.totalTokens == 900)
        #expect(day.costUSD == 0.75)
        #expect(day.requestCount == 2)
        let model = try #require(day.modelBreakdowns?.first)
        #expect(day.modelBreakdowns?.count == 1)
        #expect(model.modelName == OpenRouterReasoningTestSupport.modelName)
        #expect(model.inputTokens == 500)
        #expect(model.outputTokens == 400)
        #expect(model.reasoningTokens == 412)
        #expect(model.totalTokens == 900)
        #expect(model.costUSD == 0.75)
        #expect(model.requestCount == 2)

        let zeroCompletion = try #require(cost.daily.first { $0.date == "2026-08-16" })
        #expect(zeroCompletion.inputTokens == 23)
        #expect(zeroCompletion.outputTokens == 0)
        #expect(zeroCompletion.reasoningTokens == 29)
        #expect(zeroCompletion.totalTokens == 23)
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `unreported reasoning stays distinct from reported zero`(engine: ProviderPluginEngineKind) async throws {
        for (field, expected) in [("", nil), (",\"reasoning_tokens\":null", nil), (",\"reasoning_tokens\":0", 0)] {
            let body = #"""
            {"data":[{"date":"2026-08-17","model":"example/reasoning-model","endpoint_id":"endpoint-a",
            "prompt_tokens":10,"completion_tokens":5,"requests":1,"usage":0.5\#(field)}]}
            """#
            let usage = try await OpenRouterReasoningTestSupport.snapshot(engine: engine, activityBody: body)
            let cost = try #require(usage.costUsage)
            #expect(cost.last30DaysTokens == 15)
            #expect(cost.daily.first?.reasoningTokens == expected)
            #expect(cost.daily.first?.modelBreakdowns?.first?.reasoningTokens == expected)
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `malformed reasoning cannot publish partial history or discard quota`(
        engine: ProviderPluginEngineKind) async throws
    {
        for value in ["-1", "0.5", #""3""#, "true", "1e400", "9007199254740992"] {
            let body = #"""
            {"data":[
            {"date":"2026-08-17","model":"example/reasoning-model","endpoint_id":"valid-endpoint",
             "prompt_tokens":2,"completion_tokens":1,"reasoning_tokens":0,"requests":1,"usage":0.25},
            {"date":"2026-08-17","model":"example/reasoning-model","endpoint_id":"invalid-endpoint",
             "prompt_tokens":10,"completion_tokens":5,"reasoning_tokens":\#(value),"requests":1,"usage":0.5}
            ]}
            """#
            let usage = try await OpenRouterReasoningTestSupport.snapshot(engine: engine, activityBody: body)
            #expect(usage.costUsage == nil)
            #expect(usage.primary?.usedPercent == 25)
            #expect(usage.detailRow(label: "Remaining")?.value == "$60.00")
            #expect(usage.detailRow(label: "Last 30 days")?.secondaryValue == "Response was invalid")
        }
    }

    @Test(arguments: BundledPluginTestSupport.engines)
    func `independent reasoning aggregation remains bounded`(engine: ProviderPluginEngineKind) async throws {
        let row = #"""
        {"date":"2026-08-17","model":"example/reasoning-model","endpoint_id":"endpoint-a",
        "prompt_tokens":1,"completion_tokens":0,"reasoning_tokens":5000000000000000,"requests":1,"usage":0.5}
        """#
        let single = try await OpenRouterReasoningTestSupport.snapshot(
            engine: engine, activityBody: "{\"data\":[\(row)]}")
        #expect(single.costUsage?.last30DaysTokens == 1)
        #expect(single.costUsage?.daily.first?.reasoningTokens == 5_000_000_000_000_000)
        let secondRow = row.replacingOccurrences(of: "endpoint-a", with: "endpoint-b")
        let overflow = try await OpenRouterReasoningTestSupport.snapshot(
            engine: engine, activityBody: "{\"data\":[\(row),\(secondRow)]}")
        #expect(overflow.costUsage == nil)
        #expect(overflow.primary?.usedPercent == 25)
        #expect(overflow.detailRow(label: "Remaining")?.value == "$60.00")
        #expect(overflow.detailRow(label: "Last 30 days")?.secondaryValue == "Response was invalid")
    }
}
