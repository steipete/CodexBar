import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

extension StatusMenuTests {
    private func enableOnlyCodexForHoverPrefetch(_ settings: SettingsStore) {
        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: provider == .codex)
        }
    }

    private func makeHoverPrefetchSettings(refreshAllOnOpen: Bool) -> SettingsStore {
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.refreshAllProvidersOnMenuOpen = refreshAllOnOpen
        self.enableOnlyCodexForHoverPrefetch(settings)
        return settings
    }

    private func makeHoverPrefetchController(
        store: UsageStore,
        settings: SettingsStore) -> StatusItemController
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

    @Test
    func `status item hover prefetch refreshes enabled providers when refresh on open is enabled`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: true)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var refreshed: [UsageProvider] = []
        store._test_providerRefreshOverride = { provider in
            refreshed.append(provider)
        }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        controller.handleStatusItemHoverPrefetch(for: nil)
        let task = try #require(controller.statusItemHoverPrefetch.tasks[.codex])
        await task.value

        #expect(refreshed == [.codex])
        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)
        #expect(controller.statusItemHoverPrefetch.completedAt[.codex] != nil)
        #expect(controller.recentlyHoverPrefetchedProviders() == [.codex])
    }

    @Test
    func `status item hover prefetch does nothing when refresh on open is disabled`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: false)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var refreshed: [UsageProvider] = []
        store._test_providerRefreshOverride = { provider in
            refreshed.append(provider)
        }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        controller.handleStatusItemHoverPrefetch(for: nil)

        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)
        #expect(refreshed.isEmpty)
    }

    @Test
    func `provider status item hover prefetch refreshes only that provider`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: true)
        settings.mergeIcons = false

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var refreshed: [UsageProvider] = []
        store._test_providerRefreshOverride = { provider in
            refreshed.append(provider)
        }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        // A disabled provider's status item must not trigger any refresh.
        controller.handleStatusItemHoverPrefetch(for: .claude)
        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)

        controller.handleStatusItemHoverPrefetch(for: .codex)
        let task = try #require(controller.statusItemHoverPrefetch.tasks[.codex])
        await task.value

        #expect(refreshed == [.codex])
    }

    @Test
    func `status item hover prefetch skips while a menu is open`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: true)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var refreshed: [UsageProvider] = []
        store._test_providerRefreshOverride = { provider in
            refreshed.append(provider)
        }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        let menu = controller.makeMenu()
        controller.openMenus[ObjectIdentifier(menu)] = menu
        defer { controller.openMenus.removeValue(forKey: ObjectIdentifier(menu)) }

        controller.handleStatusItemHoverPrefetch(for: nil)

        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)
        #expect(refreshed.isEmpty)
    }

    @Test
    func `repeated hover does not start a second prefetch while one is in flight`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: true)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var refreshStarts = 0
        var gate: CheckedContinuation<Void, Never>?
        store._test_providerRefreshOverride = { _ in
            refreshStarts += 1
            await withCheckedContinuation { continuation in
                gate = continuation
            }
        }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        controller.handleStatusItemHoverPrefetch(for: .codex)
        let task = try #require(controller.statusItemHoverPrefetch.tasks[.codex])
        for _ in 0..<200 where refreshStarts == 0 {
            await Task.yield()
        }
        #expect(refreshStarts == 1)

        controller.handleStatusItemHoverPrefetch(for: .codex)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(refreshStarts == 1)

        gate?.resume()
        await task.value
        #expect(refreshStarts == 1)
        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)
    }

    @Test
    func `hover re-entry after a fresh completed prefetch does not refresh again`() async throws {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: true)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        var refreshed: [UsageProvider] = []
        store._test_providerRefreshOverride = { provider in
            refreshed.append(provider)
        }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        defer { controller.releaseStatusItemsForTesting() }

        controller.handleStatusItemHoverPrefetch(for: .codex)
        let task = try #require(controller.statusItemHoverPrefetch.tasks[.codex])
        await task.value
        #expect(refreshed == [.codex])

        // Pointer leaves and re-enters: the completed prefetch is still fresh, so no new task.
        controller.handleStatusItemHoverPrefetch(for: .codex)
        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)
        #expect(refreshed == [.codex])

        // Once the completion falls outside the freshness window, hovering prefetches again.
        controller.statusItemHoverPrefetch.completedAt[.codex] = Date()
            .addingTimeInterval(-StatusItemController.hoverPrefetchFreshnessWindow - 1)
        controller.handleStatusItemHoverPrefetch(for: .codex)
        let secondTask = try #require(controller.statusItemHoverPrefetch.tasks[.codex])
        await secondTask.value
        #expect(refreshed == [.codex, .codex])
    }

    @Test
    func `shutdown removes hover trackers and cancels prefetch tasks`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeHoverPrefetchSettings(refreshAllOnOpen: true)

        let store = self.makeCodexStore(settings: settings, dashboardAuthorized: false)
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }

        let controller = self.makeHoverPrefetchController(store: store, settings: settings)
        #expect(controller.statusItemHoverPrefetch.mergedTracker != nil)

        controller.releaseStatusItemsForTesting()

        #expect(controller.statusItemHoverPrefetch.mergedTracker == nil)
        #expect(controller.statusItemHoverPrefetch.providerTrackers.isEmpty)
        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)

        // The shutdown gate blocks any prefetch that arrives afterwards.
        controller.handleStatusItemHoverPrefetch(for: nil)
        #expect(controller.statusItemHoverPrefetch.tasks.isEmpty)
    }
}
