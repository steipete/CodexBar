import AppKit
import CodexBarCore
import SwiftUI
import Testing
@testable import CodexBar

@MainActor
private final class RecordingMenuHighlightView: NSView, MenuCardHighlighting {
    private(set) var isHighlighted = false

    func setHighlighted(_ highlighted: Bool) {
        self.isHighlighted = highlighted
    }
}

extension StatusMenuTests {
    private func makeRecyclingController(settings: SettingsStore) -> StatusItemController {
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        return StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
    }

    private func cardViewIdentities(in menu: NSMenu) -> [String: ObjectIdentifier] {
        var identities: [String: ObjectIdentifier] = [:]
        for item in menu.items {
            guard let id = item.representedObject as? String else { continue }
            guard let view = item.view, view is any MenuCardMeasuring else { continue }
            identities[id] = ObjectIdentifier(view)
        }
        return identities
    }

    @Test
    func `menu card enabled state follows interaction affordances`() {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        for renderingEnabled in [false, true] {
            StatusItemController.menuCardRenderingEnabled = renderingEnabled
            let settings = self.makeSettings()
            settings.statusChecksEnabled = false
            let controller = self.makeRecyclingController(settings: settings)
            defer { controller.releaseStatusItemsForTesting() }

            let informational = controller.makeMenuCardItem(Text("Info"), id: "info", width: 300)
            let embedded = controller.makeMenuCardItem(
                Text("Embedded"),
                id: "embedded",
                width: 300,
                containsInteractiveControls: true)
            let clickable = controller.makeMenuCardItem(Text("Click"), id: "click", width: 300, onClick: {})
            let submenu = controller.makeMenuCardItem(
                Text("Submenu"),
                id: "submenu",
                width: 300,
                submenu: NSMenu())

            #expect(!informational.isEnabled)
            #expect(embedded.isEnabled == renderingEnabled)
            #expect(clickable.isEnabled)
            #expect(submenu.isEnabled)
        }
    }

    @Test
    func `embedded controls stay enabled without highlighting the card`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let item = controller.makeMenuCardItem(
            Text("Embedded"),
            id: "embedded",
            width: 300,
            containsInteractiveControls: true)
        menu.addItem(item)

        controller.menu(menu, willHighlight: item)

        #expect(item.isEnabled)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] == nil)
        guard let hosting = item.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected a card hosting view")
            return
        }
        #expect(!hosting.allowsMenuHighlight)
        #expect(!hosting.highlightState.isHighlighted)
    }

    @Test
    func `merged menu width uses widest provider action set`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let narrow = [
            MenuDescriptor.Section(entries: [
                .action("Usage Dashboard", .dashboard),
            ]),
        ]
        let wide = [
            MenuDescriptor.Section(entries: [
                .action(String(repeating: "W", count: 60), .dashboard),
            ]),
        ]

        let narrowWidth = controller.measuredMenuCardWidth(for: [narrow])
        let stableWidth = controller.measuredMenuCardWidth(for: [narrow, wide])

        #expect(narrowWidth == StatusItemController.menuCardBaseWidth)
        #expect(stableWidth > narrowWidth)
        #expect(controller.measuredMenuCardWidth(for: [wide, narrow]) == stableWidth)
    }

    @Test
    func `menu width normalization includes usage history submenu row`() {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let usageHistoryItem = controller.makeMenuCardItem(
            Text("Subscription Utilization"),
            id: "usageHistorySubmenu",
            width: StatusItemController.menuCardBaseWidth)
        menu.addItem(usageHistoryItem)
        menu.addItem(NSMenuItem(
            title: String(repeating: "W", count: 60),
            action: nil,
            keyEquivalent: ""))

        let expectedWidth = controller.renderedMenuWidth(for: menu)
        #expect(expectedWidth > StatusItemController.menuCardBaseWidth)

        controller.refreshMenuCardHeights(in: menu)

        #expect(abs((usageHistoryItem.view?.frame.width ?? 0) - expectedWidth) <= 0.5)
    }

    @Test
    func `rendered menu width keeps tracked window width after AppKit shrink`() {
        let width = StatusItemController.resolvedRenderedMenuWidth(
            menuWidth: 310,
            trackedWindowWidth: 356)

        #expect(width == 356)
        #expect(StatusItemController.resolvedRenderedMenuWidth(
            menuWidth: 310,
            trackedWindowWidth: nil) == 310)
    }

    @Test
    func `data only repopulate reuses menu card hosting views`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
            }
        }

        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        let firstPass = self.cardViewIdentities(in: menu)
        #expect(!firstPass.isEmpty)

        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.populateMenu(menu, provider: .codex)
        let secondPass = self.cardViewIdentities(in: menu)

        #expect(secondPass.keys.sorted() == firstPass.keys.sorted())
        for (id, identity) in firstPass {
            #expect(secondPass[id] == identity, "card \(id) should reuse its hosting view")
        }
        #expect(controller.menuCardViewRecyclePool.isEmpty)
    }

    @Test
    func `merged data tick keeps row count and card views stable`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = false
        let registry = ProviderRegistry.shared
        let enabled: Set<UsageProvider> = [.codex, .claude]
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(
                    provider: provider,
                    metadata: metadata,
                    enabled: enabled.contains(provider))
            }
        }
        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: UsageFetcher().loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.selectedMenuProvider = .codex
        let menu = controller.makeMenu()
        controller.populateMenu(menu, provider: .codex)
        let itemCountBefore = menu.items.count
        let cardViewsBefore = self.cardViewIdentities(in: menu)
        #expect(!cardViewsBefore.isEmpty)

        controller.invalidateMenus(allowStaleContentDuringDataRefresh: true)
        controller.populateMenu(menu, provider: .codex)

        #expect(menu.items.count == itemCountBefore, "data-only repopulate should keep row count stable")
        let cardViewsAfter = self.cardViewIdentities(in: menu)
        for (id, identity) in cardViewsBefore {
            #expect(cardViewsAfter[id] == identity, "card \(id) should reuse its hosting view")
        }
    }

    @Test
    func `reconcile keeps matching edge rows when the middle differs`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        func plainItem(_ title: String) -> NSMenuItem {
            NSMenuItem(title: title, action: nil, keyEquivalent: "")
        }

        let menu = NSMenu()
        menu.addItem(controller.makeMenuCardItem(Text("card"), id: "menuCard", width: 300))
        menu.addItem(.separator())
        menu.addItem(plainItem("Old Provider Action"))
        menu.addItem(plainItem("Old Provider Detail"))
        menu.addItem(.separator())
        menu.addItem(plainItem("Settings"))
        let cardItem = menu.items[0]
        let cardView = cardItem.view
        let settingsItem = menu.items[5]

        let shapes = controller.menuContentShapes(in: menu, fromIndex: 0)
        controller.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: nil)
        defer { controller.clearMenuCardViewRecyclePool() }

        let scratch = NSMenu()
        scratch.addItem(controller.makeMenuCardItem(Text("other provider card"), id: "menuCard", width: 300))
        scratch.addItem(.separator())
        scratch.addItem(plainItem("New Provider Action"))
        scratch.addItem(.separator())
        scratch.addItem(plainItem("Settings"))

        controller.reconcileMenuContent(menu, fromIndex: 0, shapes: shapes, with: scratch)

        #expect(menu.items.count == 5)
        #expect(menu.items[0] === cardItem, "card row should be updated in place")
        #expect(menu.items[0].view === cardView, "card hosting view should be recycled in place")
        #expect(menu.items[4] === settingsItem, "shared trailing row should be updated in place")
        #expect(menu.items[2].title == "New Provider Action")
    }

    @Test
    func `cached provider content replaces native image rows and preserves switch back items`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let outgoing = NSMenuItem(title: "Status Page", action: nil, keyEquivalent: "")
        outgoing.image = NSImage(size: NSSize(width: 16, height: 16))
        let incoming = NSMenuItem(title: "Dashboard", action: nil, keyEquivalent: "")
        incoming.image = NSImage(size: NSSize(width: 16, height: 16))
        let menu = NSMenu()
        menu.addItem(outgoing)

        let displacedOutgoing = controller.replaceMenuContentKeepingRowsVisible(
            menu,
            fromIndex: 0,
            with: [incoming])

        #expect(menu.items.first === incoming)
        #expect(displacedOutgoing.first === outgoing)

        let displacedIncoming = controller.replaceMenuContentKeepingRowsVisible(
            menu,
            fromIndex: 0,
            with: displacedOutgoing)

        #expect(menu.items.first === outgoing)
        #expect(displacedIncoming.first === incoming)
    }

    @Test
    func `cached provider content swap preserves both item sets for switch back`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let switcher = NSMenuItem(title: "Switcher", action: nil, keyEquivalent: "")
        let outgoing = [
            NSMenuItem(title: "Overview Card", action: nil, keyEquivalent: ""),
            NSMenuItem.separator(),
            NSMenuItem(title: "Overview Action", action: nil, keyEquivalent: ""),
        ]
        let incoming = [
            NSMenuItem(title: "Codex Card", action: nil, keyEquivalent: ""),
            NSMenuItem.separator(),
            NSMenuItem(title: "Codex Usage", action: nil, keyEquivalent: ""),
            NSMenuItem(title: "Codex Settings", action: nil, keyEquivalent: ""),
        ]
        let menu = NSMenu()
        menu.addItem(switcher)
        outgoing.forEach(menu.addItem)

        let displacedOutgoing = controller.replaceMenuContentKeepingRowsVisible(
            menu,
            fromIndex: 1,
            with: incoming)

        #expect(menu.items.first === switcher)
        #expect(menu.items.dropFirst().map(\.title) == ["Codex Card", "", "Codex Usage", "Codex Settings"])
        #expect(Array(menu.items[1...3]).map(ObjectIdentifier.init) == outgoing.map(ObjectIdentifier.init))
        #expect(displacedOutgoing.map(ObjectIdentifier.init) == incoming.prefix(3).map(ObjectIdentifier.init))
        #expect(displacedOutgoing.map(\.title) == ["Overview Card", "", "Overview Action"])

        let displacedIncoming = controller.replaceMenuContentKeepingRowsVisible(
            menu,
            fromIndex: 1,
            with: displacedOutgoing)

        #expect(Array(menu.items.dropFirst()).map(ObjectIdentifier.init) == outgoing.map(ObjectIdentifier.init))
        #expect(displacedIncoming.map(ObjectIdentifier.init) == incoming.map(ObjectIdentifier.init))
        #expect(displacedIncoming.allSatisfy { $0.menu == nil })
        #expect(displacedIncoming.map(\.title) == ["Codex Card", "", "Codex Usage", "Codex Settings"])
    }

    @Test
    func `reconcile preserves highlight on a retained custom action row`() {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let liveItem = NSMenuItem()
        liveItem.isEnabled = true
        liveItem.representedObject = "action"
        liveItem.view = RecordingMenuHighlightView()
        menu.addItem(liveItem)
        controller.menu(menu, willHighlight: liveItem)

        let replacementView = RecordingMenuHighlightView()
        let replacementItem = NSMenuItem()
        replacementItem.isEnabled = true
        replacementItem.representedObject = "action"
        replacementItem.view = replacementView
        let scratch = NSMenu()
        scratch.addItem(replacementItem)

        let shapes = controller.menuContentShapes(in: menu, fromIndex: 0)
        controller.reconcileMenuContent(menu, fromIndex: 0, shapes: shapes, with: scratch)

        #expect(menu.items[0] === liveItem)
        #expect(liveItem.view === replacementView)
        #expect(replacementView.isHighlighted)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] === liveItem)
    }

    @Test
    func `reconcile restores highlight on a retained recycled card`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let liveItem = controller.makeMenuCardItem(Text("before"), id: "menuCard", width: 300, onClick: {})
        menu.addItem(liveItem)
        controller.menu(menu, willHighlight: liveItem)
        guard let hosting = liveItem.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected a card hosting view")
            return
        }

        let shapes = controller.menuContentShapes(in: menu, fromIndex: 0)
        controller.harvestRecyclableMenuCardViews(
            in: menu,
            fromIndex: 0,
            displacedSelection: nil,
            preserveHighlightedItem: true)
        defer { controller.clearMenuCardViewRecyclePool() }
        #expect(!hosting.highlightState.isHighlighted)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] === liveItem)

        let scratch = NSMenu()
        scratch.addItem(controller.makeMenuCardItem(Text("after"), id: "menuCard", width: 300, onClick: {}))
        controller.reconcileMenuContent(menu, fromIndex: 0, shapes: shapes, with: scratch)

        #expect(menu.items[0] === liveItem)
        #expect(liveItem.view === hosting)
        #expect(hosting.highlightState.isHighlighted)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] === liveItem)
    }

    @Test
    func `reconcile clears highlight when a retained card becomes disabled`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let liveItem = controller.makeMenuCardItem(Text("before"), id: "menuCard", width: 300, onClick: {})
        menu.addItem(liveItem)
        controller.menu(menu, willHighlight: liveItem)
        guard let liveView = liveItem.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected a card hosting view")
            return
        }
        #expect(liveView.highlightState.isHighlighted)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] === liveItem)

        let shapes = controller.menuContentShapes(in: menu, fromIndex: 0)
        let scratch = NSMenu()
        scratch.addItem(controller.makeMenuCardItem(Text("after"), id: "menuCard", width: 300))
        controller.reconcileMenuContent(menu, fromIndex: 0, shapes: shapes, with: scratch)

        #expect(menu.items[0] === liveItem)
        #expect(!liveItem.isEnabled)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] == nil)
        guard let rebuiltView = liveItem.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected the rebuilt card hosting view")
            return
        }
        #expect(!rebuiltView.highlightState.isHighlighted)
    }

    @Test
    func `harvesting consumes only the displaced selection cache entry`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let item = controller.makeMenuCardItem(Text("card"), id: "menuCard", width: 300, onClick: {})
        menu.addItem(item)

        let entry = CachedMergedSwitcherMenuContent(
            requiredMenuContentVersion: 0,
            menuWidth: 300,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil,
            localizationSignature: "",
            items: [])
        controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] = [
            .overview: entry,
            .provider(.codex): entry,
        ]
        controller.harvestRecyclableMenuCardViews(
            in: menu,
            fromIndex: 0,
            displacedSelection: .provider(.codex))
        defer { controller.clearMenuCardViewRecyclePool() }

        #expect(controller.menuCardViewRecyclePool.count == 1)
        #expect(item.view == nil)
        let remaining = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]
        #expect(remaining?[.provider(.codex)] == nil)
        #expect(remaining?[.overview] != nil)
    }

    @Test
    func `harvesting consumes displaced cache when card rendering is disabled`() {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let entry = CachedMergedSwitcherMenuContent(
            requiredMenuContentVersion: 0,
            menuWidth: 300,
            codexAccountDisplay: nil,
            tokenAccountDisplay: nil,
            localizationSignature: "",
            items: [])
        controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)] = [
            .overview: entry,
            .provider(.codex): entry,
        ]

        controller.harvestRecyclableMenuCardViews(
            in: menu,
            fromIndex: 0,
            displacedSelection: .provider(.codex))

        let remaining = controller.mergedSwitcherContentCaches[ObjectIdentifier(menu)]
        #expect(remaining?[.provider(.codex)] == nil)
        #expect(remaining?[.overview] != nil)
    }

    @Test
    func `type compatible leftover is adopted across card identifiers`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let original = controller.makeMenuCardItem(Text("codex usage"), id: "menuCard-0", width: 300)
        menu.addItem(original)
        let originalView = original.view

        controller.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: nil)
        defer { controller.clearMenuCardViewRecyclePool() }
        let switched = controller.makeMenuCardItem(Text("claude usage"), id: "menuCard", width: 300)

        #expect(switched.view === originalView)
        #expect(controller.menuCardViewRecyclePool.isEmpty)
    }

    @Test
    func `recycled card keeps its hosting view and highlight state`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let original = controller.makeMenuCardItem(Text("before"), id: "menuCard", width: 300)
        menu.addItem(original)
        guard let originalView = original.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected a card hosting view")
            return
        }

        controller.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: nil)
        defer { controller.clearMenuCardViewRecyclePool() }
        let rebuilt = controller.makeMenuCardItem(Text("after"), id: "menuCard", width: 300)

        #expect(rebuilt.view === originalView)
        guard let rebuiltView = rebuilt.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected the recycled hosting view")
            return
        }
        #expect(rebuiltView.highlightState === originalView.highlightState)
        rebuiltView.setHighlighted(true)
        #expect(rebuiltView.highlightState.isHighlighted)
        rebuiltView.setHighlighted(false)
    }

    @Test
    func `recycled card clears button role when click action is removed`() {
        let highlightState = MenuCardHighlightState()
        let hosting = MenuCardItemHostingView(
            rootView: Text("clickable"),
            highlightState: highlightState,
            allowsMenuHighlight: true,
            onClick: {})

        #expect(hosting.accessibilityRole() == .button)

        hosting.prepareForReuse(
            rootView: Text("informational"),
            allowsMenuHighlight: false,
            onClick: nil)

        #expect(hosting.accessibilityRole() == .group)
    }

    @Test
    func `harvesting a highlighted card clears its highlight and tracking entry`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let item = controller.makeMenuCardItem(Text("card"), id: "menuCard", width: 300, onClick: {})
        menu.addItem(item)
        controller.menu(menu, willHighlight: item)
        guard let hosting = item.view as? MenuCardItemHostingView<MenuCardSectionContainerView<Text>>
        else {
            Issue.record("expected a card hosting view")
            return
        }
        #expect(hosting.highlightState.isHighlighted)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] === item)

        controller.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: nil)
        defer { controller.clearMenuCardViewRecyclePool() }

        #expect(!hosting.highlightState.isHighlighted)
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] == nil)

        let rebuilt = controller.makeMenuCardItem(Text("rebuilt"), id: "menuCard", width: 300, onClick: {})
        #expect(rebuilt.view === hosting)
        #expect(!hosting.highlightState.isHighlighted)
    }

    @Test
    func `same id with different content type builds a fresh view`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let original = controller.makeMenuCardItem(Text("text card"), id: "menuCard", width: 300)
        menu.addItem(original)
        let originalView = original.view

        controller.harvestRecyclableMenuCardViews(in: menu, fromIndex: 0, displacedSelection: nil)
        defer { controller.clearMenuCardViewRecyclePool() }
        let rebuilt = controller.makeMenuCardItem(Image(systemName: "clock"), id: "menuCard", width: 300)

        #expect(rebuilt.view != nil)
        #expect(rebuilt.view !== originalView)
        // The incompatible pool entry is consumed rather than left behind.
        #expect(controller.menuCardViewRecyclePool.isEmpty)
    }

    @Test
    func `gpu selection highlight bypasses swiftui highlight state`() {
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        let controller = self.makeRecyclingController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let item = controller.makeMenuCardItem(
            Text("Overview row"),
            id: "overview-gpu",
            width: 300,
            submenu: NSMenu(),
            usesGPUSelection: true,
            onClick: {})
        menu.addItem(item)

        guard let gpuView = item.view as? GPUSelectionHostingView<Text>
        else {
            Issue.record("expected a GPU selection hosting view")
            return
        }

        // The menu highlights the AppKit row, but the hosted SwiftUI highlight state must stay false
        // so selection never re-invalidates the SwiftUI graph.
        controller.menu(menu, willHighlight: item)
        #expect(gpuView.isHighlightedForTesting)
        #expect(!gpuView.swiftUIHighlightStateIsHighlightedForTesting)

        controller.menu(menu, willHighlight: nil)
        #expect(!gpuView.isHighlightedForTesting)
        #expect(!gpuView.swiftUIHighlightStateIsHighlightedForTesting)
    }
}
