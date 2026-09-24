import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct RecentWindowsMenuTests {
    private func makeController(suiteName: String) -> StatusItemController {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: NSStatusBar.system)
    }

    private func dashboard(windows: [InlineUsageDashboardModel.QuotaWindow]) -> InlineUsageDashboardModel {
        var model = InlineUsageDashboardModel(
            accessibilityLabel: "Cost",
            valueStyle: .currencyUSD,
            kpis: [],
            points: [],
            detailLines: [])
        model.quotaWindows = windows
        return model
    }

    @Test
    func `recent windows appear as a titled submenu row`() throws {
        let controller = self.makeController(suiteName: "RecentWindowsMenuTests-row")
        let menu = NSMenu()
        let windows: [InlineUsageDashboardModel.QuotaWindow] = [
            .init(id: "current", title: "Current window", range: "Sep 20 – Sep 27", value: "$10.00 · 1K"),
            .init(id: "previous", title: "Previous window", range: "Sep 13 – Sep 20", value: "$4.00 · 400"),
        ]

        let added = controller.addRecentWindowsMenuItemIfNeeded(
            to: menu,
            dashboard: self.dashboard(windows: windows),
            width: 310)

        #expect(added)
        let item = try #require(menu.items.first)
        #expect(item.title == L("Recent windows"))
        #expect(item.view == nil)
        #expect(item.isEnabled)
        #expect(item.representedObject as? String == StatusItemController.recentWindowsSubmenuID)
        #expect(item.submenu?.items.count == 1)
    }

    @Test
    func `recent windows row is omitted without quota windows`() {
        let controller = self.makeController(suiteName: "RecentWindowsMenuTests-empty")
        let menu = NSMenu()

        #expect(!controller.addRecentWindowsMenuItemIfNeeded(
            to: menu,
            dashboard: self.dashboard(windows: []),
            width: 310))
        #expect(!controller.addRecentWindowsMenuItemIfNeeded(to: menu, dashboard: nil, width: 310))
        #expect(menu.items.isEmpty)
    }

    private func antigravityModel() throws -> UsageMenuCardView.Model {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(secondsFromGMT: 0))
        let now = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 15, hour: 12)))
        let resetAt = try #require(calendar.date(from: DateComponents(
            timeZone: calendar.timeZone, year: 2026, month: 7, day: 18, hour: 15)))
        let metadata = try #require(ProviderDefaults.metadata[.antigravity])
        return UsageMenuCardView.Model.make(.init(
            provider: .antigravity,
            metadata: metadata,
            snapshot: UsageSnapshot(
                primary: nil,
                secondary: nil,
                extraRateWindows: [
                    NamedRateWindow(
                        id: "antigravity-quota-summary-gemini",
                        title: "Gemini",
                        window: RateWindow(
                            usedPercent: 40,
                            windowMinutes: CostUsageTokenSnapshot.quotaWeekMinutes,
                            resetsAt: resetAt,
                            resetDescription: nil)),
                ],
                updatedAt: now),
            credits: nil,
            creditsError: nil,
            dashboardError: nil,
            tokenSnapshot: InlineCostHistoryDashboardLabelTests.antigravitySnapshot(now: now),
            tokenError: nil,
            account: AccountInfo(email: nil, plan: nil),
            isRefreshing: false,
            lastError: nil,
            usageBarsShowUsed: false,
            resetTimeDisplayStyle: .countdown,
            tokenCostUsageEnabled: true,
            showOptionalCreditsAndExtraUsage: true,
            hidePersonalInfo: false,
            costUsageBucketCalendar: calendar,
            now: now))
    }

    private func fittingHeight(_ view: some View) -> CGFloat {
        let hosting = NSHostingView(rootView: view.frame(width: 310))
        hosting.frame = NSRect(x: 0, y: 0, width: 310, height: 1)
        hosting.layoutSubtreeIfNeeded()
        return hosting.fittingSize.height
    }

    @Test
    func `provider cards leave quota windows to the submenu`() throws {
        let dashboard = try #require(try self.antigravityModel().inlineUsageDashboard)
        #expect(!dashboard.quotaWindows.isEmpty)

        let hidden = self.fittingHeight(InlineUsageDashboardContent(model: dashboard))
        let inline = self.fittingHeight(InlineUsageDashboardContent(model: dashboard)
            .environment(\.inlineUsageDashboardShowsQuotaWindows, true))

        #expect(inline > hidden)
    }

    @Test
    func `detailed overview rows keep quota window values inline`() throws {
        let model = try self.antigravityModel()
        let windows = try #require(model.inlineUsageDashboard?.quotaWindows)
        #expect(OverviewMenuCardRowView.showsInlineQuotaWindows)

        let overview = self.fittingHeight(
            OverviewMenuCardRowView(model: model, storageText: nil, width: 310, layout: .detailed))
        // Same header + usage sections the Overview row renders, without its inline-windows opt-in.
        let withoutWindows = self.fittingHeight(VStack(alignment: .leading, spacing: 0) {
            UsageMenuCardHeaderSectionView(model: model, showDivider: false, width: 310)
            UsageMenuCardUsageSectionView(
                model: model,
                layoutModel: model,
                showBottomDivider: false,
                bottomPadding: 6,
                width: 310,
                showsSectionDividers: OverviewMenuCardRowView.showsSectionDividers,
                compactMetrics: false)
        })

        #expect(!windows.isEmpty)
        #expect(overview > withoutWindows)
    }
}
