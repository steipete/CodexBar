import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
extension StatusMenuTests {
    final class HighlightProbeView: NSView, MenuCardHighlighting {
        private(set) var states: [Bool] = []

        func setHighlighted(_ highlighted: Bool) {
            self.states.append(highlighted)
        }
    }

    @Test
    func `menu highlight updates only previous and current custom rows`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let firstView = HighlightProbeView()
        let secondView = HighlightProbeView()
        let thirdView = HighlightProbeView()
        let first = NSMenuItem()
        first.view = firstView
        first.isEnabled = true
        let second = NSMenuItem()
        second.view = secondView
        second.isEnabled = true
        let third = NSMenuItem()
        third.view = thirdView
        third.isEnabled = true
        menu.addItem(first)
        menu.addItem(second)
        menu.addItem(third)

        controller.menu(menu, willHighlight: first)
        controller.menu(menu, willHighlight: second)
        controller.menu(menu, willHighlight: second)

        #expect(firstView.states == [true, false])
        #expect(secondView.states == [true])
        #expect(thirdView.states.isEmpty)
    }

    @Test
    func `native highlight defers open menu rebuild until pointer leaves native rows`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let key = ObjectIdentifier(menu)
        controller.cancelMenuWork(key)
        controller.openMenus[key] = menu
        let planUsage = NSMenuItem(title: "Plan Usage", action: nil, keyEquivalent: "")
        planUsage.isEnabled = true
        let cost = NSMenuItem(title: "Cost", action: nil, keyEquivalent: "")
        cost.isEnabled = true
        menu.addItem(planUsage)
        menu.addItem(cost)

        controller.menu(menu, willHighlight: planUsage)
        #expect(controller.highlightedMenuItems[key] === planUsage)
        #expect(controller.isNativeMenuItemHighlighted(in: menu))
        controller.lastMenuAdjunctReadinessSignature = "stale-baseline"
        controller.menuSession.invalidate(allowsStaleContent: false, requiresRebuild: true)

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in rebuildCount += 1 }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.scheduleOpenMenuRebuildIfStillVisible(
            menu,
            provider: .codex,
            resyncReadinessBaselineAfterRebuild: true)
        for _ in 0..<20 where !controller.nativeHighlightDeferredMenuRebuilds.contains(key) {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds.contains(key))
        #expect(controller.nativeHighlightDeferredMenuBaselineResyncs.contains(key))
        #expect(controller.menuNeedsRefresh(menu))

        controller.menu(menu, willHighlight: cost)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds.contains(key))

        controller.menu(menu, willHighlight: nil)
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(!controller.nativeHighlightDeferredMenuRebuilds.contains(key))
        #expect(!controller.nativeHighlightDeferredMenuBaselineResyncs.contains(key))
        #expect(!controller.menuNeedsRefresh(menu))
        #expect(controller.lastMenuAdjunctReadinessSignature == controller.menuAdjunctReadinessSignature())
    }

    @Test
    func `custom highlight does not defer open menu rebuild`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let key = ObjectIdentifier(menu)
        controller.cancelMenuWork(key)
        controller.openMenus[key] = menu
        let customItem = NSMenuItem()
        customItem.view = HighlightProbeView()
        customItem.isEnabled = true
        menu.addItem(customItem)
        controller.menu(menu, willHighlight: customItem)
        controller.menuSession.invalidate(allowsStaleContent: false, requiresRebuild: true)

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in rebuildCount += 1 }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.rebuildOpenMenuIfStillVisible(menu, provider: .codex)

        #expect(rebuildCount == 1)
        #expect(!controller.nativeHighlightDeferredMenuRebuilds.contains(key))
        #expect(!controller.menuNeedsRefresh(menu))
    }
}
