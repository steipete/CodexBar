import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    @Test
    func `groq cost data stays reachable via inline dashboard regardless of cost row gating`() throws {
        StatusItemController.menuCardRenderingEnabled = true
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer { self.disableMenuCardsForTesting() }
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.selectedMenuProvider = .groq
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .costSubmenu

        let metadata = try #require(ProviderRegistry.shared.metadata[.groq])
        settings.setProviderEnabled(provider: .groq, metadata: metadata, enabled: true)

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_179_200)
        let usage = GroqConsoleUsageSnapshot(
            daily: [
                GroqConsoleUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now.addingTimeInterval(-86400),
                    endTime: now,
                    costUSD: 1.5,
                    requests: 10,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    totalTokens: 150,
                    models: []),
            ],
            updatedAt: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .groq)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        // Groq's descriptor sets `tokenCost.supportsTokenCost = false`, so the generic Cost
        // row/submenu is unreachable regardless of display style or `tokenCostMenuSectionEnabled`
        // (that guard runs first in `tokenUsageSection`) — Groq relies solely on the inline
        // dashboard for its cost data, same as openai/mistral. This locks in that Groq's absence
        // from the "Cost" row is unaffected by which provider set gates that row, so a future
        // predicate change there can't silently break Groq the way it silently broke when this
        // row's gate briefly reused `usesProviderCostHistoryAsPrimaryDashboard`.
        let model = try #require(controller.menuCardModel(for: .groq))
        #expect(model.tokenUsage == nil)
        #expect(model.inlineUsageDashboard != nil)
    }
}
