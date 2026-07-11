import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

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

        let lines = MenuCardTokenDetailsModel.lines(for: request)

        #expect(lines.contains("Request cost: 2"))
        #expect(lines.contains(where: { $0.hasPrefix("Model: ") }))
        #expect(lines.contains(where: { $0.contains("cache read") }))
        #expect(lines.contains(where: { $0.hasPrefix("Approx.") || $0.hasPrefix("Est.") }))
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
