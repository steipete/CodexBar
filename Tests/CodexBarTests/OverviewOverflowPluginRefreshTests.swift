#if canImport(JavaScriptCore)
import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Stay in the existing serialized plugin suite because its fixtures own the shared plugin registry.
@MainActor
extension UserProviderPluginTests {
    @Test
    func `successful refresh replaces a captured overflow plugin card without reopening Overview`() async throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }

        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "overflow-refresh.js", source: """
        defineProvider({
          id: "overflow-refresh-meter",
          name: "Overflow Refresh Meter",
          topLevel: false,
          endpoints: ["https://overflow-refresh.example.test"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 42 } }; },
        });
        """)
        let transport = RecordingTransport(responseJSON: "{}")
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: transport)).first?.plugin)
        try fixture.approvals.record(plugin.approvalBinding(settings: [:]))
        let (controller, store, settings) = Self.overflowPluginRefreshController(
            plugin: plugin,
            approvalStore: fixture.approvals)
        defer {
            controller._test_openMenuRebuildObserver = nil
            controller.openMenus.removeAll()
            controller.releaseStatusItemsForTesting()
        }
        controller.menuRefreshEnabledOverrideForTesting = true
        let oldSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 5, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: .distantPast)
        let oldError = "Synthetic previous plugin refresh failure"
        store.snapshots[plugin.manifest.id] = oldSnapshot
        store.errors[plugin.manifest.id] = oldError

        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        controller.openMenus[ObjectIdentifier(menu)] = menu
        let cardID = "pluginCard:\(plugin.manifest.id.rawValue)"
        let oldOverflow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewOverflow"
        }?.submenu)
        let oldCard = try #require(oldOverflow.items.first { ($0.representedObject as? String) == cardID })
        let oldView = try #require(oldCard.view as? MenuRowContainerView)
        #expect(!plugin.manifest.topLevel)
        #expect(!menu.items.contains { ($0.representedObject as? String) == cardID })
        #expect(controller.openMenus.count == 1)
        #expect(controller.openMenus[ObjectIdentifier(oldOverflow)] == nil)
        #expect(oldOverflow.supermenu === menu)
        let oldFingerprint = UserPluginMenuCardView.fingerprint(
            snapshot: oldSnapshot, error: oldError, resetStyle: settings.resetTimeDisplayStyle)
        #expect(controller.menuCardHeightCache.keys.contains {
            $0.id == cardID && $0.fingerprint == oldFingerprint
        })

        var rebuilt: [NSMenu] = []
        controller._test_openMenuRebuildObserver = { rebuilt.append($0) }
        await store.refreshUserPlugin(plugin.manifest.id)
        let freshSnapshot = try #require(store.snapshots[plugin.manifest.id])
        #expect(freshSnapshot.primary?.usedPercent == 42)
        #expect(store.errors[plugin.manifest.id] == nil)
        #expect(transport.requestCount == 0)
        let freshFingerprint = UserPluginMenuCardView.fingerprint(
            snapshot: freshSnapshot, error: nil, resetStyle: settings.resetTimeDisplayStyle)
        #expect(freshFingerprint != oldFingerprint)

        controller.refreshOpenMenusAfterUserPluginRefresh(plugin.manifest.id)
        for _ in 0..<100 where !rebuilt.contains(where: { $0 === menu }) {
            await Task.yield()
            try? await Task.sleep(for: .milliseconds(10))
        }

        #expect(rebuilt.contains { $0 === menu })
        #expect(controller.openMenus[ObjectIdentifier(menu)] === menu)
        #expect(settings.mergedMenuLastSelectedWasOverview)
        let freshOverflow = try #require(menu.items.first {
            ($0.representedObject as? String) == "overviewOverflow"
        }?.submenu)
        let freshCard = try #require(freshOverflow.items.first { ($0.representedObject as? String) == cardID })
        let freshView = try #require(freshCard.view as? MenuRowContainerView)
        #expect(freshOverflow.supermenu === menu)
        #expect(freshCard !== oldCard)
        #expect(freshView !== oldView)
        #expect(controller.menuCardHeightCache.keys.contains {
            $0.id == cardID && $0.fingerprint == freshFingerprint
        })
    }

    @Test
    func `native highlighted More refreshes its captured plugin card without replacing navigation`() async throws {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = previousRendering }
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.write(name: "highlighted-overflow-refresh.js", source: """
        defineProvider({
          id: "highlighted-overflow-refresh-meter",
          name: "Highlighted Overflow Refresh Meter",
          topLevel: false,
          endpoints: ["https://overflow-refresh.example.test"],
          settings: [],
          fetchUsage() { return { primary: { usedPercent: 42 } }; },
        });
        """)
        let transport = RecordingTransport(responseJSON: "{}")
        let plugin = try #require(UserProviderPluginRegistry.refresh(
            loader: fixture.loader(transport: transport)).first?.plugin)
        try fixture.approvals.record(plugin.approvalBinding(settings: [:]))
        let (controller, store, settings) = Self.overflowPluginRefreshController(
            plugin: plugin, approvalStore: fixture.approvals)
        defer {
            controller._test_openMenuRebuildObserver = nil
            controller.openMenus.removeAll()
            controller.releaseStatusItemsForTesting()
        }
        controller.menuRefreshEnabledOverrideForTesting = true
        let oldSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 5, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: .distantPast)
        let oldError = "Synthetic previous plugin refresh failure"
        store.snapshots[plugin.manifest.id] = oldSnapshot
        store.errors[plugin.manifest.id] = oldError
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let rootKey = ObjectIdentifier(menu)
        controller.openMenus[rootKey] = menu
        let parent = try #require(menu.items.first { ($0.representedObject as? String) == "overviewOverflow" })
        let overflow = try #require(parent.submenu)
        let cardID = "pluginCard:\(plugin.manifest.id.rawValue)"
        let cardIndex = try #require(overflow.items.firstIndex { ($0.representedObject as? String) == cardID })
        let oldCard = overflow.items[cardIndex]
        let oldView = try #require(oldCard.view as? MenuRowContainerView)
        let rootItems = menu.items
        let overflowItems = overflow.items
        let rootNavigation = Self.overflowNavigationSignatures(rootItems)
        let otherNavigation = Self.overflowNavigationSignatures(
            overflowItems.enumerated().filter { $0.offset != cardIndex }.map(\.element))
        let oldFingerprint = UserPluginMenuCardView.fingerprint(
            snapshot: oldSnapshot, error: oldError, resetStyle: settings.resetTimeDisplayStyle)
        #expect(parent.view == nil)
        #expect(parent.isEnabled)
        #expect(overflow.supermenu === menu)
        #expect(controller.openMenus[ObjectIdentifier(overflow)] == nil)
        #expect(controller.menuCardHeightCache.keys.contains { $0.id == cardID && $0.fingerprint == oldFingerprint })

        // Deliver the real delegate event for a native submenu parent. Do not override highlightedItem,
        // disable the interaction guard, unhighlight, or close/reopen the menus to permit a root rebuild.
        controller.menu(menu, willHighlight: parent, eventType: .mouseMoved)
        #expect(controller.isNativeMenuItemHighlighted(in: menu))
        #expect(controller.highlightedMenuItems[rootKey] === parent)
        var rebuilt: [NSMenu] = []
        controller._test_openMenuRebuildObserver = { rebuilt.append($0) }
        await store.refreshUserPlugin(plugin.manifest.id)
        let freshSnapshot = try #require(store.snapshots[plugin.manifest.id])
        #expect(freshSnapshot.primary?.usedPercent == 42)
        #expect(store.errors[plugin.manifest.id] == nil)
        #expect(transport.requestCount == 0)
        #expect(controller.isNativeMenuItemHighlighted(in: menu))
        #expect(controller.highlightedMenuItems[rootKey] === parent)
        let freshFingerprint = UserPluginMenuCardView.fingerprint(
            snapshot: freshSnapshot, error: nil, resetStyle: settings.resetTimeDisplayStyle)
        #expect(freshFingerprint != oldFingerprint)
        controller.refreshOpenMenusAfterUserPluginRefresh(plugin.manifest.id)
        for _ in 0..<100 {
            #expect(controller.isNativeMenuItemHighlighted(in: menu))
            #expect(controller.highlightedMenuItems[rootKey] === parent)
            if rebuilt.contains(where: { $0 === overflow }),
               controller.nativeHighlightDeferredMenuRebuilds[rootKey] != nil
            {
                break
            }
            await Task.yield()
            try await Task.sleep(for: .milliseconds(10))
        }

        // The root remains blocked by native navigation while only the captured nested payload refreshes.
        #expect(rebuilt.contains { $0 === overflow })
        #expect(!rebuilt.contains { $0 === menu })
        #expect(controller.nativeHighlightDeferredMenuRebuilds[rootKey] != nil)
        #expect(controller.openMenus.count == 1)
        #expect(controller.openMenus[rootKey] === menu)
        #expect(controller.highlightedMenuItems[rootKey] === parent)
        #expect(controller.isNativeMenuItemHighlighted(in: menu))
        #expect(settings.mergedMenuLastSelectedWasOverview)
        #expect(parent.submenu === overflow)
        #expect(overflow.supermenu === menu)
        #expect(menu.items.map(ObjectIdentifier.init) == rootItems.map(ObjectIdentifier.init))
        #expect(Self.overflowNavigationSignatures(menu.items) == rootNavigation)
        let freshItems = overflow.items
        #expect(freshItems.count == overflowItems.count)
        let freshCard = try #require(freshItems.first { ($0.representedObject as? String) == cardID })
        let freshView = try #require(freshCard.view as? MenuRowContainerView)
        #expect(freshItems.firstIndex { $0 === freshCard } == cardIndex)
        #expect(freshCard !== oldCard)
        #expect(freshView !== oldView)
        let otherItems = freshItems.enumerated().filter { $0.offset != cardIndex }.map(\.element)
        #expect(otherItems.map(ObjectIdentifier.init) == overflowItems.enumerated()
            .filter { $0.offset != cardIndex }.map { ObjectIdentifier($0.element) })
        #expect(Self.overflowNavigationSignatures(otherItems) == otherNavigation)
        #expect(controller.menuCardHeightCache.keys.contains { $0.id == cardID && $0.fingerprint == freshFingerprint })
    }

    private static func overflowNavigationSignatures(_ items: [NSMenuItem]) -> [String] {
        items.map { item in
            [
                item.title,
                item.keyEquivalent,
                String(item.keyEquivalentModifierMask.rawValue),
                String(item.state.rawValue),
                String(item.isEnabled),
                item.action.map { NSStringFromSelector($0) } ?? "none",
                item.target.map { String(describing: ObjectIdentifier($0)) } ?? "none",
                item.submenu.map { String(describing: ObjectIdentifier($0)) } ?? "none",
            ].joined(separator: "|")
        }
    }

    private static func overflowPluginRefreshController(
        plugin: UserProviderPlugin,
        approvalStore: ProviderPluginApprovalStore) -> (StatusItemController, UsageStore, SettingsStore)
    {
        let settings = testSettingsStore(
            suiteName: "OverviewOverflowPluginRefreshTests-\(UUID().uuidString)",
            userDefaults: InMemoryUserDefaults(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        settings.mergedOverviewLayout = .compact
        settings.mergedOverviewAllAccounts = true
        settings.multiAccountMenuLayout = .stacked
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider, metadata: metadata, enabled: [.claude, .codex].contains(provider))
        }
        settings.setPluginEnabled(plugin.manifest.id, enabled: true)
        settings.setProviderOrder([.claude, .codex, plugin.manifest.id])
        for index in 0..<14 {
            settings.addTokenAccount(provider: .claude, label: "Synthetic account \(index)", token: "fixture-\(index)")
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:],
            pluginApprovalStore: approvalStore)
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: .distantPast),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        return (controller, store, settings)
    }
}
#endif
