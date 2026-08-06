import AppKit
import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Characterizes the menu-invalidation behavior of agent-session rescans (#2652).
///
/// The Overview flicker loop needed two ingredients: every rescan unconditionally invalidated
/// menus (even with byte-identical results), and the agent-session path rebuilt a tracked parent
/// menu in place instead of deferring like the store-observation path. On the Overview tab the
/// in-place rebuild is structural, so it replaced the hovered row and force-closed its hosted
/// chart submenu; the reopen triggered another rescan, closing the loop.
extension StatusMenuTests {
    private func makeSession(
        id: String = "session-1",
        lastActivityAt: Date? = Date(timeIntervalSince1970: 1_700_000_000)) -> AgentSession
    {
        AgentSession(
            id: id,
            provider: .claude,
            source: .cli,
            state: .active,
            pid: 1234,
            cwd: "/tmp/project",
            projectName: "project",
            startedAt: Date(timeIntervalSince1970: 1_699_999_000),
            lastActivityAt: lastActivityAt,
            transcriptPath: nil,
            host: "local")
    }

    @Test
    func `agent session rescan with unchanged sessions does not invalidate menus`() {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.agentSessionsEnabled = true

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
        controller.openMenus[ObjectIdentifier(menu)] = menu
        controller.menuRefreshEnabledOverrideForTesting = true

        let sessions = [self.makeSession()]
        let scanTime = Date(timeIntervalSince1970: 1_700_000_100)
        controller.agentSessions.applyLocalScanResult(sessions, updatedAt: scanTime)
        let versionAfterFirstScan = controller.menuContentVersion

        // A rescan that reproduces the exact same session list must be a menu no-op; every open
        // of a hovered chart submenu used to trigger such a rescan and re-dirty the parent.
        controller.agentSessions.applyLocalScanResult(sessions, updatedAt: scanTime.addingTimeInterval(30))
        #expect(controller.menuContentVersion == versionAfterFirstScan)

        // Changed session content still invalidates.
        controller.agentSessions.applyLocalScanResult(
            [self.makeSession(lastActivityAt: scanTime.addingTimeInterval(60))],
            updatedAt: scanTime.addingTimeInterval(60))
        #expect(controller.menuContentVersion != versionAfterFirstScan)
    }

    @Test
    func `agent session change defers parent rebuild while hosted submenu is open`() async {
        self.disableMenuCardsForTesting()
        let settings = self.makeSettings()
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.agentSessionsEnabled = true

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
        let menuKey = ObjectIdentifier(menu)
        controller.openMenus[menuKey] = menu

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.costHistoryChartID,
            provider: .claude)
        let submenuKey = ObjectIdentifier(submenu)
        controller.openMenus[submenuKey] = submenu
        controller.menuRefreshEnabledOverrideForTesting = true

        let openedVersion = controller.menuVersions[menuKey]
        var parentRebuildCount = 0
        controller._test_openMenuRebuildObserver = { rebuilt in
            if rebuilt === menu {
                parentRebuildCount += 1
            }
        }
        defer { controller._test_openMenuRebuildObserver = nil }

        // Session data changes while the user hovers an Overview row's chart submenu.
        controller.agentSessions.applyLocalScanResult([self.makeSession()])
        for _ in 0..<20 {
            await Task.yield()
        }

        // The tracked parent must stay attached (stale) instead of being structurally rebuilt in
        // place, which would force-close the hovered submenu and feed the #2652 flicker loop.
        #expect(parentRebuildCount == 0)
        #expect(controller.menuVersions[menuKey] == openedVersion)
        #expect(controller.parentMenuRebuildsDeferredDuringTracking.contains(menuKey))

        // Once the hovered submenu closes, the deferred rebuild lands exactly once.
        controller.menuDidClose(submenu)
        for _ in 0..<20 where parentRebuildCount == 0 {
            await Task.yield()
        }
        #expect(controller.openMenus[submenuKey] == nil)
        #expect(parentRebuildCount == 1)
        #expect(controller.menuVersions[menuKey] == controller.menuContentVersion)
    }
}
