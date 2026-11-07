import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
struct OverviewProviderFlyoutTests {
    private func controller(layout: MergedOverviewLayout) -> StatusItemController {
        let suite = "OverviewProviderFlyoutTests-\(UUID().uuidString)"
        let settings = SettingsStore(
            userDefaults: UserDefaults(suiteName: suite)!,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.mergedMenuLastSelectedWasOverview = true
        settings.mergedOverviewLayout = layout
        let providers: [UsageProvider] = [.claude, .codex]
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
        for provider in providers {
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 40,
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(3600),
                        resetDescription: nil),
                    secondary: nil,
                    updatedAt: Date()),
                provider: provider)
        }
        return StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
    }

    /// The flyout is how detail opens, and it must not move anything in the menu it came from.
    @Test
    func `the row flyout carries the detail and leaves the parent menu alone`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let parentItems = menu.items.count

        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-claude" })
        let flyout = try #require(row.submenu)
        #expect(flyout is OverviewProviderDetailMenu)
        #expect(controller.isHostedSubviewMenu(flyout))
        #expect(controller.hydrateHostedSubviewMenuIfNeeded(flyout, width: 310))
        #expect(flyout.items.first?.view != nil)
        #expect(flyout.items.contains { $0.action == #selector(StatusItemController.selectOverviewProvider(_:)) })
        // A hydrated flyout stays hosted, or its next open would rebuild it as the root menu.
        #expect(controller.isHostedSubviewMenu(flyout))
        controller.menuWillOpen(flyout)
        defer { controller.menuDidClose(flyout) }
        #expect(flyout.items.first?.view != nil)
        #expect(!flyout.items.contains { $0.title == L("Quit") })
        #expect(menu.items.count == parentItems)
    }

    @Test
    func `a reopened flyout rebuilds only when its provider's data changed`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        /// No reset date, so nothing in the card ticks with the clock between opens.
        func publish(_ secondary: RateWindow?) {
            controller.store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(usedPercent: 40, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                    secondary: secondary,
                    updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
                provider: .claude)
        }
        publish(nil)
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-claude" })
        let flyout = try #require(row.submenu)
        func reopen() throws -> NSView {
            controller.menuWillOpen(flyout)
            defer { controller.menuDidClose(flyout) }
            return try #require(flyout.items.first?.view)
        }
        _ = try reopen()
        let settled = try reopen()
        #expect(try reopen() === settled)

        // A new window fails the live monitor's layout check, so only this rebuild can show it.
        publish(RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil))
        let refreshed = try reopen()
        #expect(refreshed !== settled)
        #expect(flyout.items.contains { $0.action == #selector(StatusItemController.selectOverviewProvider(_:)) })
    }

    @Test
    func `a storage-only change rebuilds the reopened flyout`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        controller.settings.providerStorageFootprintsEnabled = true
        // No reset date, so a minute rolling over between opens cannot rebuild the flyout.
        self.publishNewClaudeData(to: controller)
        func publish(_ bytes: Int64) {
            controller.store.providerStorageFootprints[UsageProvider.claude.instanceID] = ProviderStorageFootprint(
                provider: .claude,
                totalBytes: bytes,
                paths: ["/synthetic"],
                missingPaths: [],
                unreadablePaths: [],
                components: [],
                updatedAt: Date(timeIntervalSince1970: 0))
        }
        publish(10)
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-claude" })
        let flyout = try #require(row.submenu)
        func reopen() throws -> NSView {
            controller.menuWillOpen(flyout)
            defer { controller.menuDidClose(flyout) }
            return try #require(flyout.items.first?.view)
        }
        _ = try reopen()
        let settled = try reopen()
        #expect(try reopen() === settled)
        let originalText = controller.store.storageFootprintText(for: .claude)
        publish(1000)
        #expect(controller.store.storageFootprintText(for: .claude) != originalText)
        #expect(try reopen() !== settled)
    }

    /// The default snapshot's reset date is ahead of the clock, so its off-pace session has a pace that never rests.
    @Test
    func `a running window's pace changes the flyout signature at most once a minute`() {
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        let minute = (Date().timeIntervalSince1970 / 60).rounded(.down) * 60
        func signature(secondsIn seconds: TimeInterval) -> String {
            controller.overviewProviderDetailRenderSignature(
                for: .claude,
                now: Date(timeIntervalSince1970: minute + seconds))
        }

        #expect(signature(secondsIn: 1) == signature(secondsIn: 59))
        #expect(signature(secondsIn: 1) != signature(secondsIn: 61))
    }

    @Test
    func `show details in the flyout opens the provider tab from the parent menu`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-codex" })
        let flyout = try #require(row.submenu)
        #expect(controller.hydrateHostedSubviewMenuIfNeeded(flyout, width: 310))
        let open = try #require(flyout.items.first {
            $0.action == #selector(StatusItemController.selectOverviewProvider(_:))
        })
        #expect(open.menu?.supermenu === menu)

        controller.selectOverviewProvider(open)

        #expect(controller.settings.mergedMenuLastSelectedWasOverview == false)
        #expect(controller.settings.selectedMenuProvider == .codex)
    }

    /// Replays the order the packaged app logged for a real click: the nested chart closes, which queues a flyout
    /// rebuild that waits on the native highlight, then mouse-up clears that highlight just before the menus close
    /// and AppKit sends the action. Sending it directly from the item would skip all of this.
    @Test
    func `clicking show details after the chart closed selects the provider through the menu lifecycle`() async throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let controller = self.controller(layout: .compact)
        controller.menuRefreshEnabledOverrideForTesting = true
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-claude" })
        let flyout = try #require(row.submenu)
        controller.menuWillOpen(menu)
        controller.menuWillOpen(flyout)
        let open = try self.showDetailsItem(in: flyout)
        let chartItem = try #require(flyout.items.first { $0.submenu != nil })
        let chart = try #require(chartItem.submenu)

        controller.menu(flyout, willHighlight: chartItem, eventType: .mouseMoved)
        controller.menuWillOpen(chart)
        self.publishNewClaudeData(to: controller)
        controller.menuDidClose(chart)
        controller.menu(flyout, willHighlight: open, eventType: .mouseMoved)
        await self.drainMainRunLoop()
        #expect(open.menu === flyout)

        controller.menu(flyout, willHighlight: nil, eventType: .leftMouseUp)
        controller.menu(menu, willHighlight: nil, eventType: .leftMouseUp)
        await self.drainMainRunLoop()
        #expect(open.menu === flyout)
        controller.menuDidClose(flyout)
        controller.menuDidClose(menu)
        try self.sendNativeAction(of: open)

        #expect(controller.settings.mergedMenuLastSelectedWasOverview == false)
        #expect(controller.settings.selectedMenuProvider == .claude)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        #expect(!menu.items.contains { ($0.representedObject as? String) == "overviewRow-claude" })
    }

    /// A data refresh can still finish between mouse-up and the action, leaving the item without a menu.
    @Test
    func `show details still selects its provider when a rebuild detached the clicked item`() throws {
        let wasEnabled = StatusItemController.menuCardRenderingEnabled
        StatusItemController.menuCardRenderingEnabled = true
        defer { StatusItemController.menuCardRenderingEnabled = wasEnabled }
        let controller = self.controller(layout: .compact)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-claude" })
        let flyout = try #require(row.submenu)
        controller.menuWillOpen(flyout)
        defer { controller.menuDidClose(flyout) }
        let open = try self.showDetailsItem(in: flyout)

        self.publishNewClaudeData(to: controller)
        controller.refreshHostedSubviewMenu(flyout)
        #expect(open.menu == nil)
        try self.sendNativeAction(of: open)

        #expect(controller.settings.mergedMenuLastSelectedWasOverview == false)
        #expect(controller.settings.selectedMenuProvider == .claude)
    }

    private func showDetailsItem(in flyout: NSMenu) throws -> NSMenuItem {
        try #require(flyout.items.first { $0.action == #selector(StatusItemController.selectOverviewProvider(_:)) })
    }

    private func publishNewClaudeData(to controller: StatusItemController) {
        controller.store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 70, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
                secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
                updatedAt: Date(timeIntervalSince1970: 1_800_000_000)),
            provider: .claude)
    }

    private func sendNativeAction(of item: NSMenuItem) throws {
        let action = try #require(item.action)
        #expect(NSApplication.shared.sendAction(action, to: item.target, from: item))
    }

    /// Runs both the queued tasks and the run-loop blocks that menu rebuilds use while AppKit tracks.
    private func drainMainRunLoop() async {
        for _ in 0..<5 {
            await Task.yield()
            self.spinMainRunLoop()
        }
    }

    private func spinMainRunLoop() {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }

    @Test
    func `the detailed layout keeps its existing chart submenu`() throws {
        let controller = self.controller(layout: .detailed)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.populateMenu(menu, provider: nil)
        let row = try #require(menu.items.first { ($0.representedObject as? String) == "overviewRow-claude" })
        #expect(!(row.submenu is OverviewProviderDetailMenu))
    }
}
