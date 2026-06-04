import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

extension StatusMenuTests {
    private func makeCoalesceController(
        _ settings: SettingsStore,
        store: UsageStore) -> StatusItemController
    {
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        controller.menuRefreshEnabledOverrideForTesting = true
        return controller
    }

    /// Reproduces the closed-menu rebuild storm: store observation churns the menu content
    /// version continuously, but a closed (invisible) menu whose displayed content is unchanged
    /// must converge — additional churn ticks must not keep re-populating it. Before the fix this
    /// rebuilt once per tick (dozens of full main-thread rebuilds).
    @Test
    func `closed menu rebuild converges when displayed content is unchanged`() async {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = self.makeCoalesceController(settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuProviders[ObjectIdentifier(menu)] = .codex

        var closedRebuilds = 0
        controller._test_closedMenuRebuildObserver = { _ in closedRebuilds += 1 }
        defer { controller._test_closedMenuRebuildObserver = nil }

        func churnOnce() async {
            controller.menuContentVersion &+= 1
            controller.rebuildClosedMenuIfNeeded(menu)
            for _ in 0..<12 {
                await Task.yield()
            }
        }

        // Let the content settle (the first real populate plus its one-shot self-perturbation).
        for _ in 0..<5 {
            await churnOnce()
        }
        let settledCount = closedRebuilds

        // Many more observation ticks with identical displayed content must add no rebuilds.
        for _ in 0..<20 {
            await churnOnce()
        }

        #expect(closedRebuilds == settledCount, "unchanged content kept rebuilding the closed menu")
        #expect(settledCount <= 2, "settling should be bounded, not per-tick (got \(settledCount))")
    }

    /// Guards against the gate over-suppressing: once content is stable, a genuine change to the
    /// displayed usage must still re-populate the closed menu.
    @Test
    func `closed menu rebuilds again when displayed content changes`() async {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = self.makeCoalesceController(settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        let menu = controller.makeMenu()
        controller.menuProviders[ObjectIdentifier(menu)] = .codex

        var closedRebuilds = 0
        controller._test_closedMenuRebuildObserver = { _ in closedRebuilds += 1 }
        defer { controller._test_closedMenuRebuildObserver = nil }

        func churnOnce() async {
            controller.menuContentVersion &+= 1
            controller.rebuildClosedMenuIfNeeded(menu)
            for _ in 0..<12 {
                await Task.yield()
            }
        }

        for _ in 0..<5 {
            await churnOnce()
        }
        let beforeChange = closedRebuilds

        // Displayed usage genuinely changes (22% -> 91%).
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 91,
                    windowMinutes: 300,
                    resetsAt: Date().addingTimeInterval(1800),
                    resetDescription: nil),
                secondary: nil,
                tertiary: nil,
                updatedAt: Date(),
                identity: ProviderIdentitySnapshot(
                    providerID: .codex,
                    accountEmail: "codex@example.com",
                    accountOrganization: nil,
                    loginMethod: "Plus Plan")),
            provider: .codex)
        await churnOnce()

        #expect(closedRebuilds > beforeChange, "a real content change must rebuild the closed menu")
    }

    /// End-to-end: drives the real production entry point (`invalidateMenus`, as fired by
    /// `observeStoreChanges` on every `menuObservationToken` change) against an attached, closed
    /// menu. A stream of observation changes with unchanged displayed content must not keep
    /// re-populating the menu.
    @Test
    func `invalidateMenus does not storm a closed attached menu on unchanged content`() async {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        defer { StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = self.makeCoalesceController(settings, store: store)
        defer { controller.releaseStatusItemsForTesting() }

        StatusItemController.setClosedMenuPreparationDelayForTesting(.zero)
        defer { StatusItemController.resetClosedMenuPreparationDelayForTesting() }

        // Attach a closed provider menu so prepareAttachedClosedMenusIfNeeded considers it.
        let menu = controller.makeMenu()
        controller.menuProviders[ObjectIdentifier(menu)] = .codex
        controller.providerMenus[.codex] = menu

        var rebuilds = 0
        controller._test_closedMenuRebuildObserver = { _ in rebuilds += 1 }
        defer { controller._test_closedMenuRebuildObserver = nil }

        func observationTick() async {
            controller.invalidateMenus()
            for _ in 0..<12 {
                await Task.yield()
            }
        }

        for _ in 0..<10 {
            await observationTick()
        }
        let settled = rebuilds

        for _ in 0..<20 {
            await observationTick()
        }

        #expect(rebuilds == settled, "invalidateMenus kept rebuilding the closed attached menu")
        #expect(settled <= 4, "settling should be bounded, not per-observation (got \(settled))")
    }
}
