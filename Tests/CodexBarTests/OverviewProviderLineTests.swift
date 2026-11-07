import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OverviewProviderLineTests {
    private func metric(
        _ title: String,
        percent: Double,
        style: UsageMenuCardView.Model.PercentStyle = .left,
        reset: String? = "Resets in 2h 18m",
        eta: TimeInterval? = nil) -> UsageMenuCardView.Model.Metric
    {
        UsageMenuCardView.Model.Metric(
            id: title,
            title: title,
            percent: percent,
            percentStyle: style,
            resetText: reset,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            detailIsPaceDerived: eta != nil,
            exhaustionETASeconds: eta,
            paceOnTop: true)
    }

    private func model(
        _ provider: UsageProvider = .claude,
        metrics: [UsageMenuCardView.Model.Metric],
        error: String? = nil) -> UsageMenuCardView.Model
    {
        UsageMenuCardView.Model(
            provider: provider,
            providerName: provider.rawValue,
            email: "",
            subtitleText: error ?? "Updated just now",
            subtitleStyle: error == nil ? .info : .error,
            planText: nil,
            metrics: metrics,
            usageNotes: [],
            openAIAPIUsage: nil,
            inlineUsageDashboard: nil,
            tokenUsage: nil,
            placeholder: nil,
            showsRetainedMeasurement: error != nil,
            progressColor: .gray)
    }

    private func line(_ provider: UsageProvider, _ percent: Double, eta: TimeInterval? = nil) -> OverviewProviderLine {
        OverviewProviderLine(
            id: provider.rawValue,
            model: self.model(provider, metrics: [self.metric("Session", percent: percent, eta: eta)]))
    }

    @Test
    func `the row shows the tightest window in either percent style`() {
        let left = OverviewProviderLine(id: "a", model: self.model(metrics: [
            self.metric("Session", percent: 62),
            self.metric("Weekly", percent: 39),
        ]))
        #expect(left.caption == "Weekly")
        #expect(left.remainingPercent == 39)
        #expect(left.percent == 39)

        let used = OverviewProviderLine(id: "a", model: self.model(metrics: [
            self.metric("Session", percent: 38, style: .used),
            self.metric("Weekly", percent: 61, style: .used),
        ]))
        #expect(used.caption == "Weekly")
        #expect(used.remainingPercent == 39)
        #expect(used.percent == 61)
    }

    @Test
    func `the value drops the suffix because the column head carries it`() {
        let line = self.line(.claude, 8)
        #expect(line.value == "8%")
        #expect(line.trailing == "2h 18m")
    }

    @Test
    func `an imminent forecast beats a lower percentage and takes the caption, not the reset column`() {
        let line = OverviewProviderLine(id: "a", model: self.model(metrics: [
            self.metric("Weekly", percent: 5),
            self.metric("Session", percent: 30, eta: 20 * 60),
        ]))
        #expect(line.caption?.hasSuffix("~20m") == true)
        #expect(line.captionIsCritical)
        #expect(line.status == .critical)
        #expect(line.remainingPercent == 30)
        #expect(line.trailing == "2h 18m")
    }

    @Test
    func `an exhausted limit outranks a forecast on another window`() {
        let line = OverviewProviderLine(id: "a", model: self.model(metrics: [
            self.metric("Session", percent: 0),
            self.metric("Weekly", percent: 60, eta: 30 * 60),
        ]))
        #expect(line.caption == "Session")
        #expect(line.remainingPercent == 0)
    }

    @Test
    func `an account row keeps its account when stale or close to running out`() {
        let imminent = OverviewProviderLine(
            id: "a",
            model: self.model(metrics: [self.metric("Session", percent: 40, eta: 20 * 60)]),
            account: "work@example.com")
        #expect(imminent.caption == "work@example.com")
        #expect(imminent.status == .critical)
        let stale = OverviewProviderLine(
            id: "a",
            model: self.model(metrics: [self.metric("Session", percent: 40)], error: "Refresh failed"),
            account: "work@example.com")
        #expect(stale.caption == "work@example.com")
        #expect(stale.status == .stale)
    }

    @Test
    func `a distant forecast does not raise an alarm`() {
        let line = self.line(.claude, 42, eta: 9 * 86400)
        #expect(line.status == .normal)
        #expect(line.trailing == "2h 18m")
    }

    @Test
    func `stale numbers never read as critical`() {
        let line = OverviewProviderLine(
            id: "a",
            model: self.model(metrics: [self.metric("Session", percent: 3)], error: "Refresh failed"))
        #expect(line.status == .stale)
        #expect(line.caption == L("stale data"))
        #expect(!line.captionIsCritical)
        #expect(line.trailing == "2h 18m")
    }

    @Test
    func `urgent rows sort by when they stop and healthy rows keep their order inside a band`() {
        let sorted = OverviewProviderLine.sortedByUrgency([
            self.line(.cursor, 70),
            self.line(.copilot, 60),
            self.line(.gemini, 3),
            self.line(.codex, 8, eta: 20 * 60),
            self.line(.claude, 39),
            self.line(.factory, 45),
        ])
        #expect(sorted.map(\.provider) == [.codex, .gemini, .claude, .factory, .cursor, .copilot])
    }

    @Test
    func `a provider already at zero sorts ahead of one forecast to stop`() {
        let sorted = OverviewProviderLine.sortedByUrgency([
            self.line(.codex, 30, eta: 20 * 60),
            self.line(.gemini, 0),
        ])
        #expect(sorted.map(\.provider) == [.gemini, .codex])
    }

    @Test
    func `a status only limit keeps its text when no percentage exists`() {
        let balance = UsageMenuCardView.Model.Metric(
            id: "mistral-balance",
            title: "Balance",
            percent: 0,
            percentStyle: .left,
            statusText: "$12.50",
            resetText: nil,
            detailText: nil,
            detailLeftText: nil,
            detailRightText: nil,
            pacePercent: nil,
            paceOnTop: true)
        let line = OverviewProviderLine(id: "a", model: self.model(.mistral, metrics: [balance]))
        #expect(line.value == "$12.50")
        #expect(line.percent == nil)
        #expect(line.remainingPercent == nil)

        let mixed = OverviewProviderLine(id: "a", model: self.model(.mistral, metrics: [
            balance,
            self.metric("Session", percent: 27),
        ]))
        #expect(mixed.value == "27%")
        #expect(mixed.remainingPercent == 27)
    }

    @Test
    func `a stale row stays in its band instead of jumping ahead of fresh rows`() {
        let stale = OverviewProviderLine(
            id: "stale",
            model: self.model(.cursor, metrics: [self.metric("Total", percent: 53)], error: "Refresh failed"))
        let sorted = OverviewProviderLine.sortedByUrgency([stale, self.line(.claude, 39)])
        #expect(sorted.map(\.provider) == [.claude, .cursor])
    }

    @Test
    func `small percentage moves do not reorder healthy rows`() {
        let before = OverviewProviderLine.sortedByUrgency([self.line(.claude, 41), self.line(.cursor, 44)])
        let after = OverviewProviderLine.sortedByUrgency([self.line(.claude, 44), self.line(.cursor, 41)])
        #expect(before.map(\.provider) == after.map(\.provider))
    }

    @Test
    func `the overview defaults to the provider limit when nothing is selected`() throws {
        let suite = "OverviewProviderLineTests-limit-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let active: [ProviderInstanceID] = [
            .codex, .claude, .cursor, .opencode, .warp, .gemini, .grok,
            .copilot, .kimi, .factory, .windsurf, .perplexity, .zai,
        ]
        #expect(store.resolvedMergedOverviewProviders(activeProviders: active)
            == Array(active.prefix(SettingsStore.mergedOverviewProviderLimit)))
    }

    // MARK: - Real menu

    private func controller(providers: [UsageProvider]) -> (StatusItemController, UsageStore) {
        let suite = "OverviewProviderLineTests-\(UUID().uuidString)"
        let settings = SettingsStore(
            userDefaults: UserDefaults(suiteName: suite)!,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        for (index, provider) in providers.enumerated() {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: Double(10 + index),
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                provider: provider)
        }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (controller, store)
    }

    /// What a user with several providers needs: no scrolling on a 14-inch laptop, no provider left out.
    @Test
    func `eight providers all appear and the menu stays under a laptop screen`() {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let providers: [UsageProvider] = [.codex, .claude, .cursor, .gemini, .copilot, .factory, .windsurf, .kimi]
        let (controller, _) = self.controller(providers: providers)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)

        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.filter { $0.hasPrefix("overviewRow-") }.count == providers.count)
        let height = menu.items.reduce(CGFloat(0)) { total, item in
            total + (item.isSeparatorItem ? 11 : (item.view?.frame.height ?? 22))
        }
        #expect(height <= 500, "Overview grew to \(height)pt")
        #expect(menu.items.last?.title == L("Quit"))
    }

    @Test
    func `the worst case roster still leaves the footer on a laptop screen`() {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let providers: [UsageProvider] = [
            .codex, .claude, .cursor, .gemini, .copilot, .factory, .windsurf, .kimi,
            .kiro, .amp, .warp, .augment, .devin, .perplexity, .kilo, .ollama,
        ]
        let (controller, store) = self.controller(providers: providers)
        defer { controller.releaseStatusItemsForTesting() }
        store._setSnapshotForTesting(nil, provider: .kimi)
        store._setErrorForTesting("Session expired after a very long explanation that would wrap", provider: .kimi)
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let height = menu.items.reduce(CGFloat(0)) { total, item in
            total + (item.isSeparatorItem ? 11 : (item.view?.frame.height ?? 22))
        }
        #expect(height <= 620, "Overview grew to \(height)pt")
        #expect(menu.items.last?.title == L("Quit"))
    }

    private func populatedOverview(
        providers: [UsageProvider],
        failing: [UsageProvider],
        layout: MergedOverviewLayout = .compact,
        deselected: [UsageProvider] = []) -> (menu: NSMenu, controller: StatusItemController)
    {
        let (controller, store) = self.controller(providers: providers)
        controller.settings.mergedOverviewLayout = layout
        for provider in deselected {
            _ = controller.settings.setMergedOverviewProviderSelection(
                provider: provider.instanceID,
                isSelected: false,
                activeProviders: providers.map(\.instanceID))
        }
        for provider in failing {
            store._setSnapshotForTesting(nil, provider: provider)
            store._setErrorForTesting("\(provider.rawValue) session expired", provider: provider)
        }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        return (menu, controller)
    }

    @Test
    func `compact names every provider when all of them have failed`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(providers: [.claude, .kimi], failing: [.claude, .kimi])
        defer { controller.releaseStatusItemsForTesting() }

        #expect(!menu.items.contains { $0.title == L("No overview data available.") })
        let attention = try #require(menu.items.first { ($0.representedObject as? String) == "overviewAttention" })
        let children = attention.submenu?.items.compactMap { $0.representedObject as? String }
        #expect(children == ["overviewRow-claude", "overviewRow-kimi"])
    }

    @Test
    func `compact shows the row when the only selected provider has failed`() {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(
            providers: [.kimi, .codex],
            failing: [.kimi],
            deselected: [.codex])
        defer { controller.releaseStatusItemsForTesting() }

        #expect(!menu.items.contains { $0.title == L("No overview data available.") })
        #expect(menu.items.contains { ($0.representedObject as? String) == "overviewRow-kimi" })
    }

    @Test
    func `detailed keeps its empty state when every provider has failed`() {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(
            providers: [.claude, .kimi],
            failing: [.claude, .kimi],
            layout: .detailed)
        defer { controller.releaseStatusItemsForTesting() }

        #expect(menu.items.contains { $0.title == L("No overview data available.") })
        #expect(!menu.items.contains { ($0.representedObject as? String) == "overviewAttention" })
    }

    @Test
    func `a single attention row selects its provider through the native menu action`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(providers: [.codex, .kimi], failing: [.kimi])
        defer { controller.releaseStatusItemsForTesting() }

        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-kimi" })
        #expect(row.submenu == nil)
        #expect(row.isEnabled)
        let target = try #require(row.target as? StatusItemController)
        #expect(target === controller)
        let action = try #require(row.action)
        _ = target.perform(action, with: row)

        #expect(controller.selectedMenuProvider == UsageProvider.kimi.instanceID)
        #expect(!controller.settings.mergedMenuLastSelectedWasOverview)
    }

    /// AppKit closes the menu on an accessibility press of an item that hosts a view, without sending its action.
    @Test
    func `an accessibility press on the attention row selects its provider`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(providers: [.codex, .kimi], failing: [.kimi])
        defer { controller.releaseStatusItemsForTesting() }
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-kimi" })

        #expect(row.accessibilityPerformPress())
        #expect(controller.selectedMenuProvider == UsageProvider.kimi.instanceID)
        #expect(!controller.settings.mergedMenuLastSelectedWasOverview)
    }

    private func returnKey(_ modifiers: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: modifiers,
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "\r",
            charactersIgnoringModifiers: "\r",
            isARepeat: false,
            keyCode: 36))
    }

    /// `NSMenu` drops Return for a highlighted item that hosts a view, so the tracking monitor has to deliver it.
    @Test
    func `return activates the highlighted attention row while the menu tracks`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(providers: [.codex, .kimi], failing: [.kimi])
        defer { controller.releaseStatusItemsForTesting() }
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-kimi" })

        #expect(try !controller.handleMenuTrackingShortcutEvent(self.returnKey(), menu: menu))
        #expect(controller.settings.mergedMenuLastSelectedWasOverview)

        controller.menu(menu, willHighlight: row, eventType: .keyDown)
        #expect(try !controller.handleMenuTrackingShortcutEvent(self.returnKey(.command), menu: menu))
        #expect(controller.settings.mergedMenuLastSelectedWasOverview)

        #expect(try controller.handleMenuTrackingShortcutEvent(self.returnKey(), menu: menu))
        #expect(controller.selectedMenuProvider == UsageProvider.kimi.instanceID)
        #expect(!controller.settings.mergedMenuLastSelectedWasOverview)
    }

    @Test
    func `return leaves a row with a flyout to the menu`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (menu, controller) = self.populatedOverview(providers: [.claude, .kimi], failing: [.claude, .kimi])
        defer { controller.releaseStatusItemsForTesting() }
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewAttention" })

        controller.menu(menu, willHighlight: row, eventType: .keyDown)
        #expect(try !controller.handleMenuTrackingShortcutEvent(self.returnKey(), menu: menu))
        #expect(controller.settings.mergedMenuLastSelectedWasOverview)
    }

    @Test
    func `a provider row is one line however many windows it has`() {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let (controller, store) = self.controller(providers: [.claude, .codex])
        defer { controller.releaseStatusItemsForTesting() }
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 10, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                tertiary: RateWindow(usedPercent: 30, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: Date()),
            provider: .claude)
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let rows = menu.items.filter { ($0.representedObject as? String)?.hasPrefix("overviewRow-") == true }
        #expect(rows.count == 2)
        #expect(Set(rows.compactMap { $0.view?.frame.height }).count == 1)
    }
}
