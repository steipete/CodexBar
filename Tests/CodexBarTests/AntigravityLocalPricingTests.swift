import Foundation
import Testing
@testable import CodexBarCore

struct AntigravityLocalPricingTests {
    @Test(arguments: ["claude-opus-4-6-thinking", "gemini-3.8-flash"], [0, 200])
    func `JSONL cache writes without a duration retain tokens but remain unpriced`(model: String, writes: Int) throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.jsonl([
            #"{"type":"session_meta","sessionId":"fixture-cache-write"}"#,
            """
            {"type":"usage","modelId":"\(model)","input":100,"output":30,"cacheRead":50,
             "cacheWrite":\(writes),"reasoning":0,"timestamp":1787832000250}
            """.replacingOccurrences(of: "\n", with: ""),
        ])
        let report = try fixture.report()
        let entry = try #require(report.report.data.first)
        #expect(report.isComplete)
        #expect(entry.totalTokens == 180 + writes)
        #expect((entry.costUSD != nil) == (writes == 0))
        #expect(entry.unpricedRequestCount == (writes == 0 ? 0 : 1))
        #expect(entry.estimatedRequestCount == (writes == 0 ? 1 : 0))
    }

    @Test(arguments: [UInt64(1_798_761_599), UInt64(1_798_761_600)])
    func `Gemini estimates each disjoint token bucket and honors the published cutoff`(seconds: UInt64) throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [AntigravityLocalFixture.blob(
            model: "gemini-3.8-flash",
            system: 100,
            input: 900,
            output: 20,
            cacheRead: 2000,
            reasoning: 80,
            seconds: seconds)])
        let report = try fixture.report()
        let entry = try #require(report.report.data.first)
        let expected = (1000 * 0.75 + 2000 * 0.075 + 100 * 3.75) / 1_000_000
            * (seconds < 1_798_761_600 ? 1.0 : 2.0)
        #expect(report.isComplete)
        #expect(try abs(#require(entry.costUSD) - expected) < 1e-12)
        #expect(entry.totalTokens == 3100)
        #expect(entry.estimatedRequestCount == 1)
        #expect(entry.pricedRequestCount == 0)
    }

    @Test(arguments: ["claude-opus-4-6-thinking", "claude-opus-4.6-thinking", "claude-opus-4.6"])
    func `Claude spellings price reasoning as output and preserve the recorded model`(model: String) throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [AntigravityLocalFixture.blob(
            model: model, system: 100, input: 900, output: 20, cacheRead: 2000, reasoning: 80)])
        let entry = try #require(fixture.report().report.data.first)
        let expected = (1000 * 5.0 + 2000 * 0.5 + 100 * 25.0) / 1_000_000
        #expect(try abs(#require(entry.costUSD) - expected) < 1e-12)
        #expect(entry.totalTokens == 3100)
        #expect(entry.estimatedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 0)
        #expect(entry.modelBreakdowns?.first?.modelName == model)
    }

    @Test(arguments: ["gemini-3.5-flash-mid", "gemini-3-flash-agent"])
    func `retired picker redirects do not establish historical model prices`(model: String) throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [AntigravityLocalFixture.blob(model: model)])
        let entry = try #require(fixture.report().report.data.first)
        #expect(entry.costUSD == nil)
        #expect(entry.totalTokens == 198)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.estimatedRequestCount == 0)
    }

    @Test
    func `unknown models retain tokens and explicit unpriced coverage beside an estimate`() throws {
        let fixture = try AntigravityLocalFixture()
        try fixture.database(blobs: [
            AntigravityLocalFixture.blob(model: "gemini-3.8-flash"),
            AntigravityLocalFixture.blob(model: "fixture-unpriced-model"),
        ])
        let report = try fixture.report()
        let entry = try #require(report.report.data.first)
        #expect(report.isComplete)
        #expect(entry.requestCount == 2)
        #expect(entry.totalTokens == 396)
        #expect(entry.costUSD != nil)
        #expect(entry.estimatedRequestCount == 1)
        #expect(entry.unpricedRequestCount == 1)
        #expect(entry.modelBreakdowns?.first(where: { $0.modelName == "fixture-unpriced-model" })?.costUSD == nil)
    }
}
