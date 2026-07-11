import Foundation
import Testing
@testable import CodexBarCore

struct CursorRequestCostEstimatorTests {
    @Test
    func `total only priced GPT produces a conservative lower bound`() {
        let estimate = CursorRequestCostEstimator.estimate(for: .init(
            timestamp: Date(),
            model: "gpt-5.5",
            tokens: 2_000_000,
            requests: 1))

        #expect(estimate.confidence == .approximateLowerBound)
        #expect(UsageFormatter.cursorEstimateText(estimate)?.hasPrefix("Approx.") == true)
        #expect(estimate.usd == nil)
        #expect(estimate.lowerBoundUSD == Decimal(10))
    }

    @Test
    func `exact OpenAI cache fields contribute to the priced total`() {
        let request = CursorRecentRequest(
            timestamp: Date(),
            model: "gpt-5.5",
            tokens: 3_000_000,
            requests: 1,
            tokenBreakdown: CursorRecentRequestTokenBreakdown(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                cacheWriteTokens: nil,
                totalTokens: 3_000_000,
                confidence: .partialBreakdown))

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .exactBreakdown)
        #expect(estimate.usd == Decimal(30.5))
    }

    @Test
    func `exact Anthropic cache fields contribute to the priced total`() {
        let request = CursorRecentRequest(
            timestamp: Date(),
            model: "claude-opus-4-1",
            tokens: 4_000_000,
            requests: 1,
            tokenBreakdown: CursorRecentRequestTokenBreakdown(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                cacheWriteTokens: 1_000_000,
                totalTokens: 4_000_000,
                confidence: .exactBreakdown))

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .exactBreakdown)
        #expect(estimate.usd == Decimal(110.25))
    }

    @Test
    func `exact Composer cache fields count as input equivalent`() {
        let request = CursorRecentRequest(
            timestamp: Date(),
            model: "composer-2.5-fast",
            tokens: 3_000_000,
            requests: 1,
            tokenBreakdown: CursorRecentRequestTokenBreakdown(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                cacheWriteTokens: 0,
                totalTokens: 3_000_000,
                confidence: .exactBreakdown))

        let estimate = CursorRequestCostEstimator.estimate(for: request)

        #expect(estimate.confidence == .exactBreakdown)
        #expect(estimate.usd == Decimal(21))
        #expect(estimate.explanation.contains("Composer cache") == false)
    }

    @Test
    func `partial Anthropic breakdown stays a visible range`() {
        let estimate = CursorRequestCostEstimator.estimate(for: .init(
            timestamp: Date(),
            model: "claude-opus-4-1",
            tokens: 1_000_000,
            requests: 1,
            tokenBreakdown: .init(
                inputTokens: nil,
                outputTokens: nil,
                cacheReadTokens: nil,
                cacheWriteTokens: nil,
                totalTokens: 1_000_000,
                confidence: .totalOnly)))

        #expect(estimate.confidence == .approximateTotalOnly)
        #expect(estimate.usd == nil)
        #expect(estimate.lowerBoundUSD == Decimal(15))
        #expect(estimate.upperBoundUSD == Decimal(75))
    }

    @Test
    func `unknown rows do not create a fabricated aggregate contribution`() {
        let request = CursorRecentRequest(
            timestamp: Date(),
            model: "future-model",
            tokens: 1_000_000,
            requests: 1)

        #expect(CursorRequestCostEstimator.estimate(for: request).confidence == .unknownModel)
        #expect(CursorRequestCostEstimator.summarizedEstimate(for: [request]) == nil)
    }

    @Test
    func `aggregate formatter distinguishes exact bounded and lower bound summaries`() {
        let exact = CursorRequestCostSummary(
            exactUSD: Decimal(string: "12.34"),
            lowerBoundUSD: Decimal(string: "12.34"),
            upperBoundUSD: Decimal(string: "12.34"),
            containsApproximation: false)
        let bounded = CursorRequestCostSummary(
            exactUSD: nil,
            lowerBoundUSD: Decimal(string: "4.10"),
            upperBoundUSD: Decimal(string: "18.70"),
            containsApproximation: true)
        let lowerBound = CursorRequestCostSummary(
            exactUSD: nil,
            lowerBoundUSD: Decimal(string: "4.10"),
            upperBoundUSD: nil,
            containsApproximation: true)

        #expect(UsageFormatter.cursorEstimatedTotalText(exact) == "Est. $12.34")
        #expect(UsageFormatter.cursorEstimatedTotalText(bounded) == "Approx. $4.10-$18.70")
        #expect(UsageFormatter.cursorEstimatedTotalText(lowerBound) == "Approx. $4.10+")
    }
}
