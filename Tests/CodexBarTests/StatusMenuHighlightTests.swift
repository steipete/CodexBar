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
    func `native highlight preserves coalesced baseline resync until pointer leaves native rows`() async {
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
        controller.scheduleOpenMenuRebuildIfStillVisible(menu, provider: .codex)
        for _ in 0..<20 where controller.nativeHighlightDeferredMenuRebuilds[key] == nil {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] != nil)
        #expect(controller.pendingMenuBaselineResyncs.contains(key))
        #expect(controller.menuNeedsRefresh(menu))

        controller.menu(menu, willHighlight: cost)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] != nil)

        controller.menu(menu, willHighlight: nil)
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] == nil)
        #expect(!controller.pendingMenuBaselineResyncs.contains(key))
        #expect(!controller.menuNeedsRefresh(menu))
        #expect(controller.lastMenuAdjunctReadinessSignature == controller.menuAdjunctReadinessSignature())
    }

    @Test
    func `native highlight preserves explicit rebuild even when menu is already fresh`() async {
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
        controller.populateMenu(menu, provider: .codex)
        controller.markMenuFresh(menu)
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        defer { controller.menuDidClose(menu) }

        let nativeItem = NSMenuItem(title: "Plan Usage", action: nil, keyEquivalent: "")
        nativeItem.isEnabled = true
        menu.addItem(nativeItem)
        controller.menu(menu, willHighlight: nativeItem)
        #expect(!controller.menuNeedsRefresh(menu))

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in rebuildCount += 1 }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.scheduleOpenMenuRebuildIfStillVisible(menu, provider: .claude)
        for _ in 0..<20 where controller.nativeHighlightDeferredMenuRebuilds[key] == nil {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key]?.provider == .claude)
        #expect(!controller.menuNeedsRefresh(menu))

        controller.menu(menu, willHighlight: nil)
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] == nil)
        #expect(!controller.menuNeedsRefresh(menu))
    }

    @Test
    func `hosted submenu close resumes deferred explicit rebuild on fresh parent`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let parent = controller.makeMenu()
        controller.populateMenu(parent, provider: .codex)
        controller.markMenuFresh(parent)
        let parentKey = ObjectIdentifier(parent)
        controller.openMenus[parentKey] = parent
        defer { controller.menuDidClose(parent) }

        let nativeItem = NSMenuItem(title: "Plan Usage", action: nil, keyEquivalent: "")
        nativeItem.isEnabled = true
        parent.addItem(nativeItem)
        controller.menu(parent, willHighlight: nativeItem)

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { menu in
            if menu === parent {
                rebuildCount += 1
            }
        }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.scheduleOpenMenuRebuildIfStillVisible(parent, provider: .claude)
        for _ in 0..<20 where controller.nativeHighlightDeferredMenuRebuilds[parentKey] == nil {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[parentKey]?.provider == .claude)
        #expect(!controller.menuNeedsRefresh(parent))

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .codex)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        controller.menu(parent, willHighlight: nil)
        for _ in 0..<20 {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[parentKey]?.provider == .claude)
        #expect(!controller.menuNeedsRefresh(parent))

        controller.menuDidClose(submenu)
        for _ in 0..<40 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 1)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[parentKey] == nil)
        #expect(!controller.menuNeedsRefresh(parent))
    }

    @Test
    func `hosted submenu close keeps explicit rebuild ahead of dirty parent refresh`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let parent = controller.makeMenu()
        controller.populateMenu(parent, provider: .codex)
        controller.markMenuFresh(parent)
        let parentKey = ObjectIdentifier(parent)
        controller.openMenus[parentKey] = parent
        defer { controller.menuDidClose(parent) }

        let nativeItem = NSMenuItem(title: "Plan Usage", action: nil, keyEquivalent: "")
        nativeItem.isEnabled = true
        parent.addItem(nativeItem)
        controller.menu(parent, willHighlight: nativeItem)

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { menu in
            if menu === parent {
                rebuildCount += 1
            }
        }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.scheduleOpenMenuRebuildIfStillVisible(parent, provider: .claude)
        for _ in 0..<20 where controller.nativeHighlightDeferredMenuRebuilds[parentKey] == nil {
            await Task.yield()
        }

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .codex)
        controller.openMenus[ObjectIdentifier(submenu)] = submenu
        controller.menuSession.invalidate(allowsStaleContent: false, requiresRebuild: true)
        #expect(controller.menuNeedsRefresh(parent))

        controller.menuDidClose(submenu)
        for _ in 0..<40 {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[parentKey]?.provider == .claude)
        #expect(controller.menuNeedsRefresh(parent))

        controller.menu(parent, willHighlight: nil)
        for _ in 0..<40 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[parentKey] == nil)
        #expect(!controller.menuNeedsRefresh(parent))
    }

    @Test
    func `hosted submenu close preserves pending parent baseline resync`() async {
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let parent = controller.makeMenu()
        controller.populateMenu(parent, provider: .codex)
        controller.markMenuFresh(parent)
        let parentKey = ObjectIdentifier(parent)
        controller.openMenus[parentKey] = parent
        defer { controller.menuDidClose(parent) }

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .codex)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu

        controller.lastMenuAdjunctReadinessSignature = "stale-baseline"
        controller.menuSession.invalidate(allowsStaleContent: false, requiresRebuild: true)
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { menu in
            if menu === parent {
                rebuildCount += 1
            }
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.scheduleOpenMenuRebuildIfStillVisible(
            parent,
            provider: .codex,
            resyncReadinessBaselineAfterRebuild: true)
        for _ in 0..<20 where controller.openMenuRebuildTasks[parentKey] != nil {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.pendingMenuBaselineResyncs.contains(parentKey))
        #expect(controller.menuNeedsRefresh(parent))

        controller.menuDidClose(submenu)
        for _ in 0..<40 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(controller.openMenus[submenuKey] == nil)
        #expect(rebuildCount == 1)
        #expect(!controller.pendingMenuBaselineResyncs.contains(parentKey))
        #expect(!controller.menuNeedsRefresh(parent))
        #expect(controller.lastMenuAdjunctReadinessSignature == controller.menuAdjunctReadinessSignature())
    }

    @Test
    func `menu close clears native highlight deferral and pending baseline resync`() async {
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
        let key = ObjectIdentifier(menu)
        controller.openMenus[key] = menu
        let nativeItem = NSMenuItem(title: "Settings", action: nil, keyEquivalent: "")
        nativeItem.isEnabled = true
        menu.addItem(nativeItem)
        controller.menu(menu, willHighlight: nativeItem)
        controller.menuSession.invalidate(allowsStaleContent: false, requiresRebuild: true)

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in rebuildCount += 1 }
        defer { controller._test_openMenuRebuildObserver = nil }
        controller.scheduleOpenMenuRebuildIfStillVisible(
            menu,
            provider: .codex,
            resyncReadinessBaselineAfterRebuild: true)
        for _ in 0..<20 where controller.nativeHighlightDeferredMenuRebuilds[key] == nil {
            await Task.yield()
        }

        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] != nil)
        #expect(controller.pendingMenuBaselineResyncs.contains(key))
        controller.menuDidClose(menu)
        for _ in 0..<10 {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.openMenus[key] == nil)
        #expect(controller.highlightedMenuItems[key] == nil)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] == nil)
        #expect(!controller.pendingMenuBaselineResyncs.contains(key))
        #expect(controller.openMenuRebuildTasks[key] == nil)
        #expect(controller.openMenuRebuildRequests.tokens[key] == nil)
    }

    @Test
    func `hosted native highlight defers signature changing refresh until pointer leaves`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = true
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
        controller.menuRefreshEnabledOverrideForTesting = true

        let submenu = NSMenu()
        #expect(controller.appendStatusComponentsItem(
            to: submenu,
            provider: .codex,
            width: StatusItemController.menuCardBaseWidth))
        let key = ObjectIdentifier(submenu)
        controller.openMenus[key] = submenu
        defer { controller.menuDidClose(submenu) }
        let originalLink = try #require(submenu.items.last)
        #expect(originalLink.title == L("Open Status Page"))
        #expect(originalLink.view == nil)
        #expect(originalLink.isEnabled)
        controller.menu(submenu, willHighlight: originalLink)

        store.statusComponents[.codex] = [
            ProviderStatusComponent(
                id: "api",
                name: "API",
                indicator: .none,
                status: "operational"),
        ]
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { menu in
            if menu === submenu {
                rebuildCount += 1
            }
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.refreshOpenMenusAllowingParentRebuild()
        for _ in 0..<20 where controller.nativeHighlightDeferredMenuRebuilds[key] == nil {
            await Task.yield()
        }

        #expect(rebuildCount == 0)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] != nil)
        #expect(submenu.items.count == 1)
        #expect(submenu.items.first === originalLink)

        controller.menu(submenu, willHighlight: nil)
        for _ in 0..<20 where rebuildCount == 0 {
            await Task.yield()
        }

        #expect(rebuildCount == 1)
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] == nil)
        #expect(submenu.items.count == 3)
        #expect(submenu.items.last !== originalLink)
        #expect(submenu.items.last?.title == L("Open Status Page"))
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
        #expect(controller.nativeHighlightDeferredMenuRebuilds[key] == nil)
        #expect(!controller.menuNeedsRefresh(menu))
    }
}
