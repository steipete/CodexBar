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

        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.menuWillOpen(menu)
        #expect(menu.items.first?.view is ProviderSwitcherView)

        #expect(try menu.performKeyEquivalent(with: Self.arrowKeyEvent(keyCode: 124)) == true)
        await Task.yield()
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .claude)

        #expect(try menu.performKeyEquivalent(with: Self.arrowKeyEvent(keyCode: 123)) == true)
        await Task.yield()
        #expect(settings.mergedMenuLastSelectedWasOverview == false)
        #expect(settings.selectedMenuProvider == .codex)
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
}
