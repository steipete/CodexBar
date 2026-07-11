import Foundation
import Testing
@testable import CodexBarCore

struct CursorRequestCostReplayTests {
    @Test
    func `normalizes gpt55 extra high to the priced base model`() {
        let model = CursorModelNormalizer.normalize("gpt-5.5-extra-high")

        #expect(model.displayName == "GPT-5.5")
        #expect(model.effort == "extra-high")
        #expect(model.pricingKey == "gpt-5.5")
    }

    @Test
    func `estimates total only gpt55 as a conservative lower bound`() {
        let request = CursorRecentRequest(
            timestamp: Date(timeIntervalSince1970: 1_770_201_720),
            model: "gpt-5.5-extra-high",
            tokens: 1_000_000,
            requests: 1)

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .approximateLowerBound)
        #expect(estimate.pricingKey == "gpt-5.5")
        #expect(estimate.lowerBoundUSD == Decimal(5))
        #expect(estimate.upperBoundUSD == nil)
    }

    @Test
    func `prices an exact Fable token breakdown with the verified local rate`() {
        let breakdown = CursorRecentRequestTokenBreakdown(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 0,
            cacheWriteTokens: 0,
            totalTokens: 2_000_000,
            confidence: .exactBreakdown)
        let request = CursorRecentRequest(
            timestamp: Date(timeIntervalSince1970: 1_770_201_720),
            model: "claude-fable-5",
            tokens: 2_000_000,
            requests: 1,
            tokenBreakdown: breakdown)

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .exactBreakdown)
        #expect(estimate.pricingKey == "claude-fable-5")
        #expect(estimate.usd == Decimal(60))
    }

    @Test
    func `prices OpenAI input output and cache read tokens without cache write metadata`() {
        let breakdown = CursorRecentRequestTokenBreakdown(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: 1_000_000,
            cacheWriteTokens: nil,
            totalTokens: 3_000_000,
            confidence: .partialBreakdown)
        let request = CursorRecentRequest(
            timestamp: Date(timeIntervalSince1970: 1_770_201_720),
            model: "gpt-5.5",
            tokens: 3_000_000,
            requests: 1,
            tokenBreakdown: breakdown)

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .exactBreakdown)
        #expect(estimate.usd == Decimal(30.5))
    }

    @Test
    func `keeps OpenAI pricing approximate when cache read metadata is absent`() {
        let breakdown = CursorRecentRequestTokenBreakdown(
            inputTokens: 1_000_000,
            outputTokens: 1_000_000,
            cacheReadTokens: nil,
            cacheWriteTokens: nil,
            totalTokens: 2_000_000,
            confidence: .partialBreakdown)
        let request = CursorRecentRequest(
            timestamp: Date(timeIntervalSince1970: 1_770_201_720),
            model: "gpt-5.5",
            tokens: 2_000_000,
            requests: 1,
            tokenBreakdown: breakdown)

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .approximateLowerBound)
        #expect(estimate.usd == nil)
    }

    @Test
    func `weighted request cost remains separate from the one request row label`() {
        let request = CursorRecentRequest(
            timestamp: Date(timeIntervalSince1970: 1_770_201_720),
            model: "gpt-5.5",
            tokens: 1000,
            requests: 1,
            requestCost: 2)
        let summary = CursorRangeUsageSummary(
            rangeKind: .billingCycle,
            range: CursorRecentRequestRange(start: request.timestamp, end: request.timestamp),
            tokens: request.tokens,
            requests: request.requests,
            weightedRequestCost: request.requestCost,
            requestCostSummary: nil,
            recentRequests: [request])

        #expect(summary.weightedRequestCost == 2)
        #expect(UsageFormatter
            .cursorRequestCountLabel(requests: request.requests, requestCost: request.requestCost) == "Req 1")
        #expect(UsageFormatter.cursorRequestCostDetail(requestCost: request.requestCost) == "Request cost: 2")
    }
}
