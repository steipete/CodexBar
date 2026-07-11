import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
struct MenuCardCursorRequestDetailsTests {
    @Test
    func `expanded cursor details include weighted cost model cache breakdown and estimate`() {
        let request = CursorRecentRequest(
            timestamp: Date(timeIntervalSince1970: 1_773_000_000),
            model: "gpt-5.5-extra-high",
            tokens: 3_000_000,
            requests: 1,
            requestCost: 2,
            tokenBreakdown: CursorRecentRequestTokenBreakdown(
                inputTokens: 1_000_000,
                outputTokens: 1_000_000,
                cacheReadTokens: 1_000_000,
                cacheWriteTokens: nil,
                totalTokens: 3_000_000,
                confidence: .partialBreakdown))

        let detailsView = CursorRequestDetailsList(requests: [request])

        #expect(detailsView.requests.first?.model == request.model)
        #expect(detailsView.requests.first?.requestCost == 2)
        #expect(UsageFormatter.cursorRequestCostDetail(requestCost: request.requestCost) == "Request cost: 2")
        #expect(UsageFormatter.cursorEstimateText(CursorRequestCostEstimator.estimate(for: request)) != nil)
    }

    @Test
    func `compact cursor row keeps semantic request count separate from weighted cost`() {
        let request = CursorRecentRequest(
            timestamp: Date(),
            model: "gpt-5.5",
            tokens: 1000,
            requests: 1,
            requestCost: 2)

        #expect(UsageFormatter.cursorRequestCountLabel(requests: request.requests) == "Req 1")
        #expect(UsageFormatter.cursorRequestCostDetail(requestCost: request.requestCost) == "Request cost: 2")
    }
}
