import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuViewportRestoreTests {
    private func makeSettings() -> SettingsStore {
        testSettingsStore(suiteName: "StatusMenuViewportRestoreTests")
    }

    private func makeController(settings: SettingsStore) -> StatusItemController {
        let environment = Self.isolatedEnvironment()
        let fetcher = UsageFetcher(environment: environment)
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: environment)
        return StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
    }

    private static func isolatedEnvironment() -> [String: String] {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("codexbar-tests", isDirectory: true)
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        return [
            "HOME": root.path,
            "CODEX_HOME": root.appendingPathComponent(".codex", isDirectory: true).path,
            "XDG_CONFIG_HOME": root.appendingPathComponent(".config", isDirectory: true).path,
        ]
    }

    @Test
    func `viewport top offset is nil when the menu content fits the clip`() {
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: true,
            documentHeight: 500,
            clipHeight: 500,
            currentOffset: 0) == nil)
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: true,
            documentHeight: 400,
            clipHeight: 500,
            currentOffset: 0) == nil)
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: true,
            documentHeight: 400,
            clipHeight: 0,
            currentOffset: 0) == nil)
    }

    @Test
    func `viewport top offset is nil when the viewport already shows the top`() {
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: true,
            documentHeight: 1700,
            clipHeight: 950,
            currentOffset: 0) == nil)
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: false,
            documentHeight: 1700,
            clipHeight: 950,
            currentOffset: 750) == nil)
    }

    @Test
    func `viewport top offset targets the content top for a scrolled menu`() {
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: true,
            documentHeight: 1700,
            clipHeight: 950,
            currentOffset: 750) == 0)
        #expect(StatusItemController.menuViewportTopOffset(
            documentIsFlipped: false,
            documentHeight: 1700,
            clipHeight: 950,
            currentOffset: 0) == 750)
    }

    @Test
    func `completed manual refresh arms a restore for the open dirty menu`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        #expect(controller.openMenus[ObjectIdentifier(menu)] === menu)

        controller._test_manualRefreshOperation = {
            // Stand-in for the store mutations of a real refresh: content is newer
            // than what the open menu rendered.
            controller.menuContentVersion += 1
        }
        controller.refreshNow()
        for _ in 0..<20 where controller.manualRefreshTasks[.global] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.global])
        await task.value

        #expect(controller.menuSession.pendingViewportRestores.contains(ObjectIdentifier(menu)))
    }

    @Test
    func `completed manual refresh does not arm a restore for a clean menu`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        controller.markMenuFresh(menu)

        controller._test_manualRefreshOperation = {}
        controller.refreshNow()
        for _ in 0..<20 where controller.manualRefreshTasks[.global] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.global])
        await task.value

        #expect(!controller.menuSession.pendingViewportRestores.contains(ObjectIdentifier(menu)))
    }

    @Test
    func `landed open-menu rebuild consumes the pending restore exactly once`() async {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        #expect(controller.openMenus[ObjectIdentifier(menu)] === menu)

        var restoredMenus: [ObjectIdentifier] = []
        StatusItemController._test_menuViewportRestoreObserver = { restoredMenus.append(ObjectIdentifier($0)) }
        defer { StatusItemController._test_menuViewportRestoreObserver = nil }

        controller.menuSession.armViewportRestore(ObjectIdentifier(menu))
        controller.rebuildOpenMenuIfStillVisible(menu, provider: .codex)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
        for _ in 0..<20 where restoredMenus.isEmpty {
            await Task.yield()
        }
        #expect(restoredMenus == [ObjectIdentifier(menu)])

        // A follow-up rebuild without a pending restore must leave the viewport alone.
        controller.rebuildOpenMenuIfStillVisible(menu, provider: .codex)
        for _ in 0..<20 {
            await Task.yield()
        }
        #expect(restoredMenus == [ObjectIdentifier(menu)])
    }

    @Test
    func `closing the menu clears its pending restore`() {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        controller.menuSession.armViewportRestore(ObjectIdentifier(menu))
        controller.menuDidClose(menu)

        #expect(!controller.menuSession.pendingViewportRestores.contains(ObjectIdentifier(menu)))
    }

    @Test
    func `viewport restore is a safe no-op without an attached menu window`() {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        // Menu items exist but no view is hosted in a menu window, so the private
        // scroll view cannot be resolved and the restore must bail out quietly.
        #expect(StatusItemController.attachedMenuScrollView(in: menu) == nil)
        controller.restoreMenuViewportToTop(menu)
    }
}
