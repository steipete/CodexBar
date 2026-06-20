import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuCostMenuCardTests {
    @Test
    func `cost menu shows no detail lines`() {
        let tokenUsage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "Today: $74.83 - 87M tokens",
            monthLine: "Last 30 days: $4,279.64 - 5.7B tokens",
            hintLine: "Costs are estimated from local usage.",
            errorLine: "Cost refresh failed.",
            errorCopyText: nil)

        let visibleLines = StatusItemController.costMenuVisibleDetailLines(
            tokenUsage: tokenUsage,
            hasSubmenu: true)
        #expect(visibleLines == [])

        let fallbackTitle = StatusItemController.costMenuFallbackAttributedTitle(visibleDetailLines: visibleLines)
        #expect(fallbackTitle.string == "Cost")
    }

    @Test
    func `cost menu preserves summary lines without history submenu`() {
        let tokenUsage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "Today: $74.83 - 87M tokens",
            monthLine: "Last 30 days: $4,279.64 - 5.7B tokens",
            hintLine: "Costs are estimated from local usage.",
            errorLine: "Cost refresh failed.",
            errorCopyText: nil)

        let visibleLines = StatusItemController.costMenuVisibleDetailLines(
            tokenUsage: tokenUsage,
            hasSubmenu: false)
        #expect(visibleLines == [
            "Today: $74.83 - 87M tokens",
            "Last 30 days: $4,279.64 - 5.7B tokens",
            "Cost refresh failed.",
        ])

        let fallbackTitle = StatusItemController.costMenuFallbackAttributedTitle(visibleDetailLines: visibleLines)
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

    @Test
    func `cost menu item has correct title tooltip and submenu`() {
        let settings = self.makeSettings()
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let tokenUsage = UsageMenuCardView.Model.TokenUsageSection(
            sessionLine: "Today: $227.42 - 267M tokens",
            monthLine: "Last 30 days: $52,431.09 - 77B tokens",
            hintLine: "Costs are estimated from local usage.",
            errorLine: nil,
            errorCopyText: nil)
        let model = self.makeModel(tokenUsage: tokenUsage)
        let submenu = NSMenu()

        let item = controller.makeCostMenuCardItem(model: model, submenu: submenu)

        #expect(item.title == "Cost")
        #expect(item.toolTip?.contains("$52,431.09") == true)
        #expect(item.submenu === submenu)
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuCostMenuCardTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeModel(
        tokenUsage: UsageMenuCardView.Model.TokenUsageSection) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: .codex,
            providerName: "Codex",
            email: "user@example.com",
            subtitleText: "Updated now",
            subtitleStyle: .info,
            planText: "Pro",
            metrics: [],
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            creditsText: nil,
            creditsRemaining: nil,
            creditsHintText: nil,
            creditsHintCopyText: nil,
            providerCost: nil,
            tokenUsage: tokenUsage,
            placeholder: nil,
            progressColor: .blue)
    }
}
