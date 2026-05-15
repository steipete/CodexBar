import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuCostMenuCardTests {
    @Test
    func `cost menu fallback keeps visible details in attributed title`() {
        let tokenUsage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "Today: $74.83 - 87M tokens",
            monthLine: "Last 30 days: $4,279.64 - 5.7B tokens",
            hintLine: "Costs are estimated from local usage.",
            errorLine: "Cost refresh failed.",
            errorCopyText: nil)

        let visibleLines = StatusItemController.costMenuVisibleDetailLines(tokenUsage: tokenUsage)
        #expect(visibleLines == [
            "Today: $74.83 - 87M tokens",
            "Last 30 days: $4,279.64 - 5.7B tokens",
            "Cost refresh failed.",
        ])

        let fallbackTitle = StatusItemController.costMenuFallbackAttributedTitle(visibleDetailLines: visibleLines)
        #expect(fallbackTitle.string.contains("Cost"))
        #expect(fallbackTitle.string.contains("Today: $74.83 - 87M tokens"))
        #expect(fallbackTitle.string.contains("Last 30 days: $4,279.64 - 5.7B tokens"))
        #expect(fallbackTitle.string.contains("Cost refresh failed."))
    }

    @Test
    func `cost menu tooltip preserves hint and error details`() {
        let tokenUsage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "Today: $1.00",
            monthLine: "Last 30 days: $9.00",
            hintLine: "Costs are estimated from local usage.",
            errorLine: "Cost refresh failed.",
            errorCopyText: nil)

        #expect(StatusItemController.costMenuTooltipLines(tokenUsage: tokenUsage) == [
            "Today: $1.00",
            "Last 30 days: $9.00",
            "Costs are estimated from local usage.",
            "Cost refresh failed.",
        ])
    }
}
