import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuSwitcherClickTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    private func makeSettings() -> SettingsStore {
        let suite = "StatusMenuSwitcherClickTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        return SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
    }

    private func makeInstalledSwitcherShortcutMonitor() -> (controller: StatusItemController, menu: StatusItemMenu) {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = StatusItemMenu()
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        let switcherItem = NSMenuItem()
        switcherItem.view = switcher
        menu.addItem(switcherItem)
        menu.addItem(.separator())

        controller.installProviderSwitcherShortcutMonitorIfNeeded(for: menu)
        return (controller, menu)
    }

    @Test
    func `merged switcher routes runtime clicks after overview round-trip`() throws {
        // Regression test for #867: after Provider → Overview, subsequent runtime clicks on a
        // sub-provider tab dropped through NSButton's tracking and never updated state.
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        // Step 1: provider → Overview via the runtime click path.
        let switcher1 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher1._test_simulateRuntimeClick(buttonTag: 0))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        // Step 2: Overview → provider via the runtime click path. Tag 2 is the second provider
        // (claude) since tag 0 is Overview and tag 1 is the first provider.
        let switcher2 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher2._test_simulateRuntimeClick(buttonTag: 2))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)

        // Step 3: provider → Overview again.
        let switcher3 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher3._test_simulateRuntimeClick(buttonTag: 0))
        #expect(settings.mergedMenuLastSelectedWasOverview == true)

        // Step 4: Overview → other provider. This is the click that previously got dropped.
        let switcher4 = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher4._test_simulateRuntimeClick(buttonTag: 1))
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)
    }

    @Test
    func `merged switcher commits selection on matching mouse up`() throws {
        var selections: [ProviderSwitcherSelection] = []
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selections.append($0) })

        #expect(switcher._test_simulateMouseDown(buttonTag: 0))
        #expect(selections.isEmpty)
        let mouseUp = try #require(switcher._test_mouseUpEvent(buttonTag: 0))
        #expect(switcher.handleMenuTrackingMouseUp(mouseUp))
        #expect(selections == [.overview])
    }

    @Test
    func `menu tracking routes switcher pointer sequence before AppKit menu dispatch`() throws {
        var selected: ProviderSwitcherSelection?
        let switcher = ProviderSwitcherView(
            providers: [.codex, .claude],
            selected: .provider(.codex),
            includesOverview: true,
            width: 320,
            showsIcons: false,
            iconProvider: { _ in NSImage() },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { selected = $0 })
        let menu = StatusItemMenu()
        let item = NSMenuItem()
        item.view = switcher
        item.isEnabled = false
        menu.addItem(item)

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        let fetcher = UsageFetcher()
        let controller = StatusItemController(
            store: UsageStore(
                fetcher: fetcher,
                browserDetection: BrowserDetection(cacheTTL: 0),
                settings: settings),
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let mouseDown = try #require(switcher._test_mouseDownEvent(buttonTag: 0))
        let mouseUp = try #require(switcher._test_mouseUpEvent(buttonTag: 0))
        #expect(controller.handleProviderSwitcherTrackingEvent(mouseDown, menu: menu))
        #expect(selected == nil)
        #expect(controller.handleProviderSwitcherTrackingEvent(mouseUp, menu: menu))
        #expect(selected == .overview)
    }

    @Test
    func `merged switcher runtime click defers icon rendering until after event handling`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.applyIcon(phase: nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))

        #expect(settings.selectedMenuProvider == .claude)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)
        await controller.providerSelectionUIRefreshTask?.value
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=claude") == true)
    }

    @Test
    func `merged switcher click marks menu stale before deferred rebuild`() throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = UInt64.max
        defer { controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = nil }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        let key = ObjectIdentifier(menu)
        #expect(controller.menuVersions[key] == controller.menuContentVersion)

        let openedVersion = controller.menuContentVersion
        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))

        #expect(settings.selectedMenuProvider == .claude)
        #expect(controller.menuContentVersion != openedVersion)
        #expect(controller.menuVersions[key] != controller.menuContentVersion)

        controller.menuDidClose(menu)
        #expect(controller.menuVersions[key] != controller.menuContentVersion)
        #expect(controller.openMenuRebuildTasks[key] == nil)
    }

    @Test
    func `merged switcher runtime click updates loading animation state after event handling`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        controller.applyIcon(phase: nil)
        #expect(controller.needsMenuBarIconAnimation() == false)
        #expect(controller.animationDriver == nil)

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)

        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))
        #expect(settings.selectedMenuProvider == .claude)
        await controller.providerSelectionUIRefreshTask?.value
        #expect(controller.needsMenuBarIconAnimation() == true)
        #expect(controller.animationDriver != nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=claude") == true)

        #expect(switcher._test_simulateRuntimeClick(buttonTag: 1))
        #expect(settings.selectedMenuProvider == .codex)
        await controller.providerSelectionUIRefreshTask?.value
        #expect(controller.needsMenuBarIconAnimation() == false)
        #expect(controller.animationDriver == nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)
    }

    @Test
    func `merged switcher switches provider while overview chart submenu is open`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .openai
        settings.mergedMenuLastSelectedWasOverview = true
        settings.costUsageEnabled = true
        settings.costSummaryDisplayStyle = .both

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .openai || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let usage = OpenAIAPIUsageSnapshot(
            daily: [
                OpenAIAPIUsageSnapshot.DailyBucket(
                    day: "2023-11-14",
                    startTime: now,
                    endTime: now.addingTimeInterval(86400),
                    costUSD: 9,
                    requests: 12,
                    inputTokens: 100,
                    cachedInputTokens: 0,
                    outputTokens: 50,
                    totalTokens: 150,
                    lineItems: [],
                    models: []),
            ],
            updatedAt: now)
        store._setSnapshotForTesting(usage.toUsageSnapshot(), provider: .openai)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        controller.openMenus[ObjectIdentifier(menu)] = menu

        let openAIRow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewRow-openai"
        })
        let submenu = try #require(openAIRow.submenu)
        controller.openMenus[ObjectIdentifier(submenu)] = submenu

        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        let switcher = try #require(menu.items.first?.view as? ProviderSwitcherView)
        #expect(switcher._test_simulateRuntimeClick(buttonTag: 2))
        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)
        #expect(rebuildCount == 1)
        #expect(controller.openMenus[ObjectIdentifier(submenu)] == nil)

        let ids = menu.items.compactMap { $0.representedObject as? String }
        #expect(ids.contains("menuCard"))
        #expect(ids.contains(where: { $0.hasPrefix("overviewRow-") }) == false)
    }

    @Test
    func `merged switcher handles left and right arrow keyboard navigation`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }
        settings.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: [.codex, .claude])
        settings.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: [.codex, .claude])

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        controller.menuRefreshEnabledOverrideForTesting = true
        defer { controller.releaseStatusItemsForTesting() }

        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.menuWillOpen(menu)
        #expect(menu.items.first?.view is ProviderSwitcherView)
        store.tokenRefreshInFlight.insert(.codex)
        defer { store.tokenRefreshInFlight.remove(.codex) }
        var rebuildCount = 0
        controller._test_openMenuRebuildObserver = { _ in
            rebuildCount += 1
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        #expect(try menu.performKeyEquivalent(with: Self.arrowKeyEvent(keyCode: 124)) == true)
        for _ in 0..<100 where rebuildCount == 0 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)
        #expect(rebuildCount == 1)

        #expect(try menu.performKeyEquivalent(with: Self.arrowKeyEvent(keyCode: 123)) == true)
        for _ in 0..<100 where rebuildCount == 1 {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)
        #expect(rebuildCount == 2)
    }

    @Test
    func `merged switcher handles command number shortcuts in visible order`() async throws {
        let previousMenuCardRendering = StatusItemController.menuCardRenderingEnabled
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(false)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousMenuCardRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = false

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            let shouldEnable = provider == .codex || provider == .claude || provider == .cursor
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: shouldEnable)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.menuWillOpen(menu)
        #expect(menu.items.first?.view is ProviderSwitcherView)

        #expect(try controller.handleProviderSwitcherShortcut(Self.commandKeyEvent("3", keyCode: 20), menu: menu))
        await Task.yield()
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)

        #expect(try controller.handleProviderSwitcherShortcut(Self.commandKeyEvent("1", keyCode: 18), menu: menu))
        await Task.yield()
        #expect(settings.mergedMenuLastSelectedWasOverview == true)
        #expect(settings.selectedMenuProvider == .claude)

        #expect(try !controller.handleProviderSwitcherShortcut(Self.commandKeyEvent("9", keyCode: 25), menu: menu))
        await Task.yield()
        #expect(settings.mergedMenuLastSelectedWasOverview == true)
        #expect(settings.selectedMenuProvider == .claude)
    }

    @Test
    func `provider shortcut monitor is removed when tracked menu closes after switcher rebuild`() {
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let (controller, menu) = self.makeInstalledSwitcherShortcutMonitor()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.providerSwitcherShortcutEventMonitor != nil)
        #expect(controller.providerSwitcherShortcutMenuID == ObjectIdentifier(menu))

        menu.removeAllItems()
        controller.menuDidClose(menu)

        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.providerSwitcherShortcutMenuID == nil)
    }

    @Test
    func `switcher shortcut monitor is removed from direct close cleanup`() {
        let previousMenuRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.setMenuRefreshEnabledForTesting(previousMenuRefresh)
        }

        let (controller, menu) = self.makeInstalledSwitcherShortcutMonitor()
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.providerSwitcherShortcutEventMonitor != nil)
        #expect(controller.providerSwitcherShortcutMenuID == ObjectIdentifier(menu))

        controller.forgetClosedMenu(menu)

        #expect(controller.providerSwitcherShortcutEventMonitor == nil)
        #expect(controller.providerSwitcherShortcutMenuID == nil)
    }

    @Test
    func `switcher hover styling keeps layout stable`() {
        let view = ProviderSwitcherView(
            providers: [.codex, .claude, .cursor, .factory, .zai, .minimax, .alibaba],
            selected: .provider(.codex),
            includesOverview: true,
            width: 300,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })

        let initialSize = view.intrinsicContentSize
        let initialFrames = view._test_buttonFrames()

        view._test_setHoveredButtonTag(3)
        view._test_setHoveredButtonTag(6)
        view._test_setHoveredButtonTag(nil as Int?)

        #expect(view.intrinsicContentSize == initialSize)
        #expect(view._test_buttonFrames() == initialFrames)
    }

    @Test
    func `switcher quota indicator preserves remaining percentage`() throws {
        let view = ProviderSwitcherView(
            providers: [.claude, .grok],
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                switch provider {
                case .claude:
                    5
                case .grok:
                    95
                default:
                    nil
                }
            },
            onSelect: { _ in })

        let fillRatios = view._test_quotaIndicatorFillRatios()
        #expect(fillRatios.count == 2)
        let lowRemainingRatio = try #require(fillRatios.first)
        let highRemainingRatio = try #require(fillRatios.last)
        #expect(lowRemainingRatio < highRemainingRatio)
    }

    @Test
    func `switcher quota indicator refresh updates fill ratios`() throws {
        var claudeRemaining = 5.0
        var grokRemaining = 95.0
        let view = ProviderSwitcherView(
            providers: [.claude, .grok],
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                switch provider {
                case .claude:
                    claudeRemaining
                case .grok:
                    grokRemaining
                default:
                    nil
                }
            },
            onSelect: { _ in })

        let initialRatios = view._test_quotaIndicatorFillRatios()
        let initialLow = try #require(initialRatios.first)
        let initialHigh = try #require(initialRatios.last)

        claudeRemaining = 80
        grokRemaining = 12
        view.updateQuotaIndicators()

        let updatedRatios = view._test_quotaIndicatorFillRatios()
        let updatedLow = try #require(updatedRatios.first)
        let updatedHigh = try #require(updatedRatios.last)
        #expect(updatedLow > initialLow)
        #expect(updatedHigh < initialHigh)
    }

    @Test
    func `switcher quota indicator renders zero remaining empty`() {
        var grokRemaining = 50.0
        let view = ProviderSwitcherView(
            providers: [.claude, .grok],
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                switch provider {
                case .claude:
                    100
                case .grok:
                    grokRemaining
                default:
                    nil
                }
            },
            onSelect: { _ in })

        grokRemaining = 0
        view.updateQuotaIndicators()
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        let fillRatios = view._test_quotaIndicatorFillRatios()
        let fillFrames = view._test_quotaIndicatorFillFrames()
        #expect(fillRatios.last == 0)
        #expect(fillFrames.last?.width == 0)
    }

    @Test
    func `switcher keeps stable height when remaining becomes unavailable`() throws {
        var grokRemaining: Double? = 50
        let noQuotaView = ProviderSwitcherView(
            providers: [.claude, .grok],
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        let view = ProviderSwitcherView(
            providers: [.claude, .grok],
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { provider in
                switch provider {
                case .claude:
                    100
                case .grok:
                    grokRemaining
                default:
                    nil
                }
            },
            onSelect: { _ in })
        #expect(view._test_quotaIndicatorFillRatios().count == 2)
        let noQuotaHeight = try #require(noQuotaView._test_buttonFittingSizes().last?.height)
        let quotaHeight = try #require(view._test_buttonFittingSizes().last?.height)
        #expect(quotaHeight == noQuotaHeight)

        grokRemaining = nil
        view.updateQuotaIndicators()

        #expect(view._test_quotaIndicatorFillRatios().count == 1)
        let removedQuotaHeight = try #require(view._test_buttonFittingSizes().last?.height)
        #expect(removedQuotaHeight == noQuotaHeight)
    }

    @Test
    func `text only switcher keeps stable height with quota bars`() throws {
        let providers: [UsageProvider] = [.claude, .grok]
        let textOnlyWithoutQuota = ProviderSwitcherView(
            providers: providers,
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: false,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in nil },
            onSelect: { _ in })
        let textOnlyWithQuota = ProviderSwitcherView(
            providers: providers,
            selected: .provider(.claude),
            includesOverview: false,
            width: 180,
            showsIcons: false,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in 50 },
            onSelect: { _ in })

        let withoutQuotaHeight = try #require(textOnlyWithoutQuota._test_buttonFittingSizes().first?.height)
        let withQuotaHeight = try #require(textOnlyWithQuota._test_buttonFittingSizes().first?.height)
        #expect(withQuotaHeight == withoutQuotaHeight)
    }

    @Test
    func `multi row switcher quota bars stay inside bounds`() {
        let view = ProviderSwitcherView(
            providers: [.codex, .claude, .cursor, .factory, .zai, .minimax, .alibaba],
            selected: .provider(.codex),
            includesOverview: true,
            width: 300,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in 50 },
            onSelect: { _ in })
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        for frame in view._test_buttonFrames() {
            #expect(frame.minY >= 0)
            #expect(frame.maxY <= view.bounds.maxY)
        }
    }

    private static func arrowKeyEvent(keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: "",
            charactersIgnoringModifiers: "",
            isARepeat: false,
            keyCode: keyCode))
    }

    private static func commandKeyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown,
            location: .zero,
            modifierFlags: [.command],
            timestamp: 0,
            windowNumber: 0,
            context: nil,
            characters: characters,
            charactersIgnoringModifiers: characters,
            isARepeat: false,
            keyCode: keyCode))
    }

    @Test
    func `multi-row switcher uses compact height and stays inside bounds`() {
        // 14 providers + Overview forces the four-row path and includes multi-word titles.
        let view = ProviderSwitcherView(
            providers: [
                .codex,
                .claude,
                .cursor,
                .factory,
                .zai,
                .minimax,
                .alibaba,
                .opencodego,
                .grok,
                .groq,
                .gemini,
                .openrouter,
                .perplexity,
                .kiro,
            ],
            selected: .provider(.codex),
            includesOverview: true,
            width: 300,
            showsIcons: true,
            iconProvider: { _ in NSImage(size: NSSize(width: 16, height: 16)) },
            weeklyRemainingProvider: { _ in 50 },
            onSelect: { _ in })
        view.updateConstraintsForSubtreeIfNeeded()
        view.layoutSubtreeIfNeeded()

        // All buttons must stay within switcher bounds (no vertical overflow).
        let buttonFrames = view._test_buttonFrames()
        let contentFrames = view._test_buttonContentFrames()
        let trackFrames = view._test_quotaIndicatorTrackFrames()
        for (frame, contentFrame) in zip(buttonFrames, contentFrames) {
            #expect(frame.minY >= 0)
            #expect(frame.maxY <= view.bounds.maxY)
            #expect(abs((contentFrame?.midY ?? -1) - frame.height / 2) <= 0.5)
        }
        for (buttonFrame, trackFrame) in zip(buttonFrames.dropFirst(), trackFrames) {
            #expect(trackFrame.minY >= buttonFrame.minY)
            #expect(trackFrame.maxY <= buttonFrame.maxY)
        }

        #expect(view._test_rowCount() == 4)
        #expect(view._test_rowHeight() == 39)
        #expect(view.bounds.height == 168)
    }
}
