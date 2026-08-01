import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
extension StatusMenuTests {
    @Test
    func `codex workspaces row is present in the populated provider menu`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
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

        let menu = NSMenu()
        controller.populateMenu(menu, provider: .codex)

        let item = try #require(menu.items.first { $0.title == "Workspaces" })
        #expect(item.submenu != nil)
    }

    @Test
    func `codex workspaces section does not duplicate a trailing separator`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.codexLocalProjectUsageEnabled = true

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

        let menu = NSMenu()
        let credits = NSMenuItem(title: "Credits", action: nil, keyEquivalent: "")
        credits.representedObject = "menuCardCredits"
        menu.addItem(credits)
        menu.addItem(.separator())

        controller.addCodexLocalProjectUsageMenuSection(to: menu, provider: .codex, width: 420)

        #expect(menu.items.count == 4)
        #expect(menu.items[1].isSeparatorItem)
        #expect(menu.items[2].title == "Workspaces")
        #expect(menu.items[3].isSeparatorItem)
    }

    @Test
    func `codex workspaces row exposes a native hosted submenu`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let scope = store.tokenCostScope(for: .codex)
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "\(scope.signature)|historyDays=\(settings.costUsageHistoryDays)" +
            "|hidePersonalInfo=\(settings.hidePersonalInfo)"

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let didAdd = controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420)

        #expect(didAdd)
        let item = try #require(menu.items.first { $0.title == "Workspaces" })
        let submenu = try #require(item.submenu)
        #expect(submenu.minimumWidth == CodexLocalProjectUsageSubmenuLayout.menuWidth)
        #expect(item.view == nil)
        #expect(menu.items.count == 1)
        #expect(item.target === controller)
        #expect(item.action == #selector(controller.menuCardNoOp(_:)))
        #expect(
            submenu.items.first?.representedObject as? String
                == StatusItemController.codexLocalProjectUsageSubmenuID)
    }

    @Test
    func `codex workspaces row construction does not enqueue refresh work`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
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

        let menu = NSMenu()
        let didAdd = controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420)
        await Task.yield()
        await Task.yield()

        #expect(didAdd)
        #expect(store.codexLocalProjectUsageRefreshInFlight == false)
        #expect(store.codexLocalProjectUsageProgress == nil)
        #expect(store.lastCodexLocalProjectUsageFetchScope == nil)
    }

    @Test
    func `codex workspaces row does not require cost summary section`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = false
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
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

        let menu = NSMenu()
        let didAdd = controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420)

        #expect(didAdd)
        #expect(menu.items.first?.title == "Workspaces")
    }

    @Test
    func `codex workspaces row updates indexing progress in place`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let scope = store.tokenCostScope(for: .codex)
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "\(scope.signature)|historyDays=\(settings.costUsageHistoryDays)"
        store.codexLocalProjectUsageRefreshInFlight = true
        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 25,
            totalFileCount: 503,
            indexedFileCount: 25,
            skippedFileCount: 0)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let didAdd = controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420)
        #expect(didAdd)
        let item = try #require(menu.items.first { $0.title == "Workspaces" })
        let progressItem = try #require(self.codexLocalProjectUsageProgressItem(from: item))
        #expect(progressItem.isEnabled == false)
        #expect(progressItem.submenu == nil)
        #expect(progressItem.view?.fittingSize.height == 24)
        let progressView = try #require(progressItem.view)
        let progressIndicator = try #require(self.progressIndicators(in: progressView).first)
        #expect(progressIndicator.isHidden == false)
        #expect(progressIndicator.isIndeterminate)
        #expect(self.codexLocalProjectUsageSubtitle(from: item) == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Indexing projects… 25/503 files, 478 left")

        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 50,
            totalFileCount: 503,
            indexedFileCount: 50,
            skippedFileCount: 0)
        controller.updateCodexLocalProjectUsageRows()

        #expect(self.codexLocalProjectUsageProgressItem(from: item) === progressItem)
        #expect(self.codexLocalProjectUsageSubtitle(from: item) == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Indexing projects… 50/503 files, 453 left")
    }

    @Test
    func `codex workspaces menu action opens the persistent window`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let scope = store.tokenCostScope(for: .codex)
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "\(scope.signature)|historyDays=\(settings.costUsageHistoryDays)"

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        let didAdd = controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420)
        #expect(didAdd)
        let item = try #require(menu.items.first { $0.title == "Workspaces" })

        controller.openCodexLocalProjectUsageWindowFromMenu(item)

        #expect(controller.codexLocalProjectUsageWindow != nil)
        controller.codexLocalProjectUsageWindow?.close()
    }

    @Test
    func `codex workspaces submenu hydrates through the hosted view pipeline`() throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let scope = store.tokenCostScope(for: .codex)
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "\(scope.signature)|historyDays=\(settings.costUsageHistoryDays)"

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let menu = NSMenu()
        #expect(controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420))
        let item = try #require(menu.items.first { $0.title == "Workspaces" })
        let submenu = try #require(item.submenu)

        #expect(controller.hydrateHostedSubviewMenuIfNeeded(submenu, width: 520))
        #expect(submenu.items.count == 3)
        #expect(
            submenu.items.first?.representedObject as? String
                == StatusItemController.codexLocalProjectUsageSubmenuID)
        #expect(submenu.items.last?.title == "Open in Window")

        controller.menuWillOpen(submenu)
        #expect(store.codexLocalProjectUsageRefreshTask != nil)
        store.codexLocalProjectUsageRefreshTask?.cancel()
    }

    @Test
    func `codex workspaces progress does not trigger broad menu invalidation path`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.costUsageEnabled = true
        settings.codexLocalProjectUsageEnabled = true

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let scope = store.tokenCostScope(for: .codex)
        store.lastCodexLocalProjectUsageFetchAt = Date()
        store.lastCodexLocalProjectUsageFetchScope = "\(scope.signature)|historyDays=\(settings.costUsageHistoryDays)"
        store.codexLocalProjectUsageRefreshInFlight = true
        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 25,
            totalFileCount: 503,
            indexedFileCount: 25,
            skippedFileCount: 0)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        var broadMenuChangeCount = 0
        controller.onObservedStoreMenuChangeForTesting = {
            broadMenuChangeCount += 1
        }

        let menu = NSMenu()
        let didAdd = controller.addCodexLocalProjectUsageMenuItemIfNeeded(to: menu, provider: .codex, width: 420)
        #expect(didAdd)
        let item = try #require(menu.items.first { $0.title == "Workspaces" })

        store.codexLocalProjectUsageProgress = CodexLocalProjectUsageIndexProgress(
            phase: .indexingProjects,
            processedFileCount: 50,
            totalFileCount: 503,
            indexedFileCount: 50,
            skippedFileCount: 0)
        await Task.yield()
        await Task.yield()

        #expect(broadMenuChangeCount == 0)
        #expect(self.codexLocalProjectUsageSubtitle(from: item) == "Indexing local Codex logs…")
        #expect(store.codexLocalProjectUsageProgressSubtitle == "Indexing projects… 50/503 files, 453 left")

        store.codexLocalProjectUsageError = "Failed to read Codex logs"
        await Task.yield()
        await Task.yield()

        #expect(broadMenuChangeCount == 1)

        store.codexLocalProjectUsageRefreshInFlight = false
        store.codexLocalProjectUsageProgress = nil
        controller.updateCodexLocalProjectUsageRows()
        #expect(self.codexLocalProjectUsageProgressItem(from: item) == nil)
        #expect(self.codexLocalProjectUsageSubtitle(from: item) == "Failed to read Codex logs")
    }

    private func codexLocalProjectUsageSubtitle(from item: NSMenuItem) -> String? {
        if #available(macOS 14.4, *), let subtitle = item.subtitle, !subtitle.isEmpty {
            return subtitle
        }
        let view = item.view ?? self.codexLocalProjectUsageProgressItem(from: item)?.view
        guard let view else { return nil }
        return self.textFields(in: view).map(\.stringValue).first {
            $0.hasPrefix("Indexing") || $0.hasPrefix("Scanning") || $0.hasPrefix("Saving") ||
                $0.hasPrefix("Finalizing")
        }
    }

    private func codexLocalProjectUsageProgressItem(from item: NSMenuItem) -> NSMenuItem? {
        guard let menu = item.menu,
              let index = menu.items.firstIndex(where: { $0 === item }),
              index + 1 < menu.items.count
        else { return nil }
        let candidate = menu.items[index + 1]
        return (candidate.representedObject as? String) == "codexLocalProjectUsageProgress" ? candidate : nil
    }

    private func progressIndicators(in view: NSView) -> [NSProgressIndicator] {
        var indicators = view.subviews.flatMap(self.progressIndicators(in:))
        if let indicator = view as? NSProgressIndicator {
            indicators.insert(indicator, at: 0)
        }
        return indicators
    }

    private func textFields(in view: NSView) -> [NSTextField] {
        var fields = view.subviews.flatMap(self.textFields(in:))
        if let field = view as? NSTextField {
            fields.insert(field, at: 0)
        }
        return fields
    }
}
