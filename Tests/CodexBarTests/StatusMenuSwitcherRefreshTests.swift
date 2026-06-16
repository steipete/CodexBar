import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherRefreshTests {
    @Test
    func `native switcher action preserves off tab switches after button state toggles`() {
        var selections: [ProviderSwitcherSelection] = []
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: false,
            width: 310,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selections.append($0) })

        #expect(switcher._test_simulateNativeAction(buttonTag: 1, state: .on))
        #expect(selections == [.provider(.claude)])
    }

    @Test
    func `native switcher action restores active tab after native toggle`() {
        var selections: [ProviderSwitcherSelection] = []
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: false,
            width: 310,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selections.append($0) })

        #expect(switcher._test_simulateNativeAction(buttonTag: 0, state: .off))
        #expect(selections.isEmpty)
        #expect(Self.switcherButtons(in: switcher).first { $0.tag == 0 }?.state == .on)
    }

    @Test
    func `merged provider switch rebuilds stale width switcher rows`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)

        let activeProviders: [UsageProvider] = [.codex, .claude]
        _ = settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        _ = settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store.isRefreshing = true
        defer { store.isRefreshing = false }
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        #expect(controller.openMenus[ObjectIdentifier(menu)] === menu)

        let initialSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        initialSwitcher.frame.size.width = 250

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let nextProviderButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .off })
        #expect(initialSwitcher._test_simulateRuntimeClick(buttonTag: nextProviderButton.tag) == true)

        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rebuildCount == 1)
        let updatedSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(updatedSwitcher.frame.width == 310)
        #expect(Self.switcherButtons(in: menu).first { $0.tag == nextProviderButton.tag }?.state == .on)
    }

    @Test
    func `selected provider tab click does not rebuild open menu`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)
        Self.disableOverview(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        let selectedButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .on })

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        #expect(switcher._test_simulateRuntimeClick(buttonTag: selectedButton.tag))
        try? await Task.sleep(for: .milliseconds(40))

        #expect(rebuildCount == 0)
        #expect(Self.switcherButtons(in: menu).first { $0.tag == selectedButton.tag }?.state == .on)
    }

    @Test
    func `merged provider switch updates live tab rows in place`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)
        Self.disableOverview(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let contentStartIndex = controller.providerSwitcherContentStartIndex(in: menu)
        #expect(menu.items.indices.contains(contentStartIndex))
        let originalContentID = ObjectIdentifier(menu.items[contentStartIndex])
        let selectedButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .on })
        let alternateButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .off })

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        // Provider switches now reconcile matching rows in place instead of parking and
        // restoring distinct item sets per tab: the same NSMenuItem objects carry each
        // tab's freshly built content, so AppKit never relayouts the open menu per insert.
        let initialSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(initialSwitcher._test_simulateRuntimeClick(buttonTag: alternateButton.tag))
        await Self.waitForRebuildCount(1, rebuildCount: { rebuildCount })
        #expect(menu.items.indices.contains(contentStartIndex))
        #expect(ObjectIdentifier(menu.items[contentStartIndex]) == originalContentID)

        let alternateSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(alternateSwitcher._test_simulateRuntimeClick(buttonTag: selectedButton.tag))
        await Self.waitForRebuildCount(2, rebuildCount: { rebuildCount })
        #expect(menu.items.indices.contains(contentStartIndex))
        #expect(ObjectIdentifier(menu.items[contentStartIndex]) == originalContentID)

        let restoredSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(restoredSwitcher._test_simulateRuntimeClick(buttonTag: alternateButton.tag))
        await Self.waitForRebuildCount(3, rebuildCount: { rebuildCount })
        #expect(menu.items.indices.contains(contentStartIndex))
        #expect(ObjectIdentifier(menu.items[contentStartIndex]) == originalContentID)

        controller.invalidateMenus()
        #expect(controller.mergedSwitcherContentCaches.isEmpty)
    }

    @Test
    func `native image menu rows are replaced during reconciliation`() {
        let settings = Self.makeSettings()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let liveItem = Self.nativeImageItem(title: "Status Page")
        menu.addItem(liveItem)
        let shapes = controller.menuContentShapes(in: menu, fromIndex: 0)

        let scratch = NSMenu()
        let freshItem = Self.nativeImageItem(title: "Status Page")
        scratch.addItem(freshItem)

        controller.reconcileMenuContent(menu, fromIndex: 0, shapes: shapes, with: scratch)

        #expect(menu.items.count == 1)
        #expect(ObjectIdentifier(menu.items[0]) == ObjectIdentifier(freshItem))
        #expect(ObjectIdentifier(menu.items[0]) != ObjectIdentifier(liveItem))
    }

    @Test
    func `native image submenu rows reconcile in place`() {
        let settings = Self.makeSettings()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let liveItem = Self.nativeImageItem(title: "System Account")
        liveItem.submenu = NSMenu(title: "System Account")
        menu.addItem(liveItem)
        let shapes = controller.menuContentShapes(in: menu, fromIndex: 0)

        let scratch = NSMenu()
        let freshItem = Self.nativeImageItem(title: "System Account")
        freshItem.submenu = NSMenu(title: "System Account")
        scratch.addItem(freshItem)

        controller.reconcileMenuContent(menu, fromIndex: 0, shapes: shapes, with: scratch)

        #expect(menu.items.count == 1)
        #expect(ObjectIdentifier(menu.items[0]) == ObjectIdentifier(liveItem))
        #expect(ObjectIdentifier(menu.items[0]) != ObjectIdentifier(freshItem))
    }

    @Test
    func `provider switch does not cache stale rows after required invalidation`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.resetMenuRefreshEnabledForTesting()
        }

        let settings = Self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        Self.enableCodexAndClaude(settings)
        Self.disableOverview(settings)

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let contentStartIndex = controller.providerSwitcherContentStartIndex(in: menu)
        #expect(menu.items.indices.contains(contentStartIndex))
        let selectedButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .on })
        let alternateButton = try #require(Self.switcherButtons(in: menu).first { $0.state == .off })

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        controller.invalidateMenus()
        #expect(controller.mergedSwitcherContentCaches.isEmpty)
        let initialSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(initialSwitcher._test_simulateRuntimeClick(buttonTag: alternateButton.tag))
        await Self.waitForRebuildCount(1, rebuildCount: { rebuildCount })

        let alternateSwitcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(alternateSwitcher._test_simulateRuntimeClick(buttonTag: selectedButton.tag))
        await Self.waitForRebuildCount(2, rebuildCount: { rebuildCount })

        // Rows are reconciled in place, so freshness is guaranteed by rebuilding content
        // from current data rather than by minting new items: the live menu must be marked
        // fresh and no cached entry may predate the required invalidation. (In-place item
        // identity itself is covered deterministically in MenuCardViewRecyclingTests; here
        // async gate state may legitimately route a populate through the full rebuild.)
        #expect(menu.items.indices.contains(contentStartIndex))
        let menuKey = ObjectIdentifier(menu)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
        for entry in controller.mergedSwitcherContentCaches[menuKey]?.values ?? [:].values {
            #expect(entry.requiredMenuContentVersion >= controller.latestRequiredMenuRebuildVersion)
        }
    }

    @Test
    func `tab switch does not replace quota indicator constraints`() {
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: false,
            width: 310,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in 75.0 },
            onSelect: { _ in })

        let initialConstraints = switcher._test_quotaIndicatorConstraintIdentifiers()
        #expect(initialConstraints.count == 2, "both providers should have quota indicators")

        switcher.updateQuotaIndicators()

        let afterFirstCall = switcher._test_quotaIndicatorConstraintIdentifiers()
        #expect(afterFirstCall == initialConstraints, "same ratio: constraints must not be replaced")
    }

    @Test
    func `quota indicator constraints are replaced when ratio changes`() {
        var currentRemaining = 75.0
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: false,
            width: 310,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in currentRemaining },
            onSelect: { _ in })

        let initialConstraints = switcher._test_quotaIndicatorConstraintIdentifiers()
        #expect(initialConstraints.count == 2)

        currentRemaining = 40.0
        switcher.updateQuotaIndicators()

        let afterDataChange = switcher._test_quotaIndicatorConstraintIdentifiers()
        #expect(afterDataChange != initialConstraints, "changed ratio: constraints should be replaced")
    }

    private static func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherRefreshTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        return SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private static func enableCodexAndClaude(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }
    }

    private static func disableOverview(_ settings: SettingsStore) {
        let activeProviders: [UsageProvider] = [.codex, .claude]
        _ = settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        _ = settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)
    }

    private static func waitForRebuildCount(
        _ expectedCount: Int,
        rebuildCount: () -> Int) async
    {
        for _ in 0..<100 where rebuildCount() < expectedCount {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }
    }

    private static func switcherButtons(in menu: NSMenu) -> [NSButton] {
        guard let switcherView = menu.items.first?.view as? ProviderSwitcherView else { return [] }
        return self.switcherButtons(in: switcherView)
    }

    private static func switcherButtons(in switcherView: ProviderSwitcherView) -> [NSButton] {
        switcherView.subviews
            .compactMap { $0 as? NSButton }
            .sorted { $0.tag < $1.tag }
    }

    private static func nativeImageItem(title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.image = NSImage(size: NSSize(width: 16, height: 16))
        return item
    }
}
