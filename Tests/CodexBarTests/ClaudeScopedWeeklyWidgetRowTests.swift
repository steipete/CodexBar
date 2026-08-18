import Foundation
import Testing
@testable import CodexBarCore
@testable import CodexBarWidget

struct ClaudeScopedWeeklyWidgetRowTests {
    @Test
    func `Claude widget renders projected model scoped weekly rows`() {
        let entry = WidgetSnapshot.ProviderEntry(
            provider: .claude,
            updatedAt: Date(),
            primary: nil,
            secondary: nil,
            tertiary: nil,
            usageRows: [
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "primary", title: "Session", percentLeft: 75),
                WidgetSnapshot.WidgetUsageRowSnapshot(id: "secondary", title: "Weekly", percentLeft: 50),
                WidgetSnapshot.WidgetUsageRowSnapshot(
                    id: "claude-weekly-scoped-fable",
                    title: "Fable only",
                    percentLeft: 70),
            ],
            creditsRemaining: nil,
            codeReviewRemainingPercent: nil,
            tokenUsage: nil,
            dailyUsage: [])

        #expect(WidgetUsageRow.smallWidgetRowLimit(for: entry) == nil)
        #expect(WidgetUsageRow.rows(for: entry).map(\.id) == [
            "primary",
            "secondary",
            "claude-weekly-scoped-fable",
        ])
    }
}
