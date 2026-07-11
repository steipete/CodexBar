import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
private final class ViewportRefreshGate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false

    func wait() async {
        if self.isOpen {
            self.isOpen = false
            return
        }
        await withCheckedContinuation { continuation in
            self.continuation = continuation
        }
    }

    func resume() {
        if let continuation = self.continuation {
            continuation.resume()
            self.continuation = nil
        } else {
            self.isOpen = true
        }
    }
}

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
    func `manual refresh restores originating dirty menu without rebuilding tracked parent`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let menuID = ObjectIdentifier(menu)

        var restoredMenus: [ObjectIdentifier] = []
        var rebuildCount = 0
        controller._test_menuViewportRestoreObserver = { restoredMenus.append(ObjectIdentifier($0)) }
        controller._test_openMenuRebuildObserver = { rebuiltMenu in
            if rebuiltMenu === menu {
                rebuildCount += 1
            }
        }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        #expect(try controller.handleMenuTrackingShortcutEvent(self.keyEvent("r", keyCode: 15), menu: menu))
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value

        #expect(controller.menuNeedsRefresh(menu))
        #expect(controller.menuSession.isParentRebuildDeferred(menuID))
        #expect(rebuildCount == 0)

        self.runLoop(mode: CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString))

        #expect(restoredMenus == [menuID])
        self.runLoop(mode: .defaultMode)
        #expect(restoredMenus == [menuID])
        #expect(rebuildCount == 0)
        #expect(controller.menuNeedsRefresh(menu))
        #expect(controller.menuSession.isParentRebuildDeferred(menuID))
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `completed manual refresh clears its request when the menu stayed clean`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        controller.markMenuFresh(menu)

        var scheduledCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_manualRefreshOperation = {}
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value

        #expect(scheduledCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `provider refresh restores only its originating open menu`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let claudeMenu = controller.makeMenu(for: .claude)
        let codexMenu = controller.makeMenu(for: .codex)
        controller.providerMenus[.claude] = claudeMenu
        controller.providerMenus[.codex] = codexMenu
        controller.menuWillOpen(claudeMenu)
        controller.menuWillOpen(codexMenu)
        defer {
            controller.menuDidClose(codexMenu)
            controller.menuDidClose(claudeMenu)
        }

        var scheduled: [@MainActor () -> Void] = []
        var restoredMenus: [ObjectIdentifier] = []
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { restoredMenus.append(ObjectIdentifier($0)) }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: claudeMenu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.claude)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.claude)])
        await task.value

        #expect(scheduled.count == 1)
        scheduled.removeFirst()()

        #expect(restoredMenus == [ObjectIdentifier(claudeMenu)])
        #expect(controller.menuNeedsRefresh(codexMenu))
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `closing and reopening during refresh cannot transfer restore to new tracking session`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        #expect(!controller.menuSession.pendingViewportRestores.isEmpty)

        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)

        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `closing and reopening after completion invalidates scheduled restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value
        #expect(scheduled.count == 1)

        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `open hosted submenu blocks parent viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.usageBreakdownChartID)
        controller.openMenus[ObjectIdentifier(submenu)] = submenu

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        var rebuildCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_openMenuRebuildObserver = { rebuiltMenu in
            if rebuiltMenu === menu {
                rebuildCount += 1
            }
        }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value

        #expect(scheduled.isEmpty)
        #expect(restoreCount == 0)
        #expect(!controller.menuSession.pendingViewportRestores.isEmpty)
        #expect(controller.manualRefreshViewportRestoreState.deferredUntilRebuild.count == 1)

        controller.menuDidClose(submenu)
        for _ in 0..<20 where scheduled.isEmpty {
            await Task.yield()
        }
        #expect(rebuildCount == 1)
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()

        #expect(restoreCount == 1)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
        #expect(controller.manualRefreshViewportRestoreState.deferredUntilRebuild.isEmpty)
    }

    @Test
    func `hosted submenu opening before delivery invalidates parent viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        var rebuildCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_openMenuRebuildObserver = { rebuiltMenu in
            if rebuiltMenu === menu {
                rebuildCount += 1
            }
        }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value
        #expect(scheduled.count == 1)

        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.usageBreakdownChartID)
        controller.openMenus[ObjectIdentifier(submenu)] = submenu
        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(!controller.menuSession.pendingViewportRestores.isEmpty)
        #expect(controller.manualRefreshViewportRestoreState.deferredUntilRebuild.count == 1)

        controller.menuDidClose(submenu)
        for _ in 0..<20 where scheduled.isEmpty {
            await Task.yield()
        }
        #expect(rebuildCount == 1)
        #expect(scheduled.count == 1)
        scheduled.removeFirst()()

        #expect(restoreCount == 1)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
        #expect(controller.manualRefreshViewportRestoreState.deferredUntilRebuild.isEmpty)
    }

    @Test
    func `fresh parent does not defer old restore when hosted submenu opens before delivery`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value
        #expect(scheduled.count == 1)

        controller.rebuildOpenMenuIfStillVisible(menu, provider: .codex)
        #expect(!controller.menuNeedsRefresh(menu))
        controller.parentMenuRebuildPendingAfterHostedSubviewClose = true
        let submenu = controller.makeHostedSubviewPlaceholderMenu(
            chartID: StatusItemController.usageBreakdownChartID)
        controller.openMenus[ObjectIdentifier(submenu)] = submenu
        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
        #expect(controller.manualRefreshViewportRestoreState.deferredUntilRebuild.isEmpty)
    }

    @Test
    func `native highlight blocks parent viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let settingsItem = try #require(menu.items.first { $0.title == "Settings..." })
        controller.menu(menu, willHighlight: settingsItem)

        var scheduledCount = 0
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `native highlight before delivery invalidates parent viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value
        #expect(scheduled.count == 1)

        let settingsItem = try #require(menu.items.first { $0.title == "Settings..." })
        controller.menu(menu, willHighlight: settingsItem)
        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `custom highlight blocks parent viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let overviewItem = NSMenuItem()
        overviewItem.view = NSView()
        overviewItem.isEnabled = true
        menu.addItem(overviewItem)
        controller.menu(menu, willHighlight: overviewItem)

        var scheduledCount = 0
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.menuSession.invalidate(allowsStaleContent: false, requiresRebuild: true)
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `custom highlight before delivery invalidates parent viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value
        #expect(scheduled.count == 1)

        let overviewItem = NSMenuItem()
        overviewItem.view = NSView()
        overviewItem.isEnabled = true
        menu.addItem(overviewItem)
        controller.menu(menu, willHighlight: overviewItem)
        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `refresh row highlight clears while its action is in flight`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        let refreshItem = try #require(menu.items.first(where: controller.isPersistentRefreshItem))
        let refreshView = try #require(refreshItem.view as? PersistentRefreshMenuView)
        controller.menu(menu, willHighlight: refreshItem)

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        let gate = ViewportRefreshGate()
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }

        #expect(refreshView.accessibilityPerformPress())
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        #expect(controller.highlightedMenuItems[ObjectIdentifier(menu)] == nil)
        #expect(!refreshItem.isEnabled)

        gate.resume()
        await task.value
        #expect(refreshItem.isEnabled)
        #expect(scheduled.count == 1)

        scheduled.removeFirst()()
        #expect(restoreCount == 1)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `non-manual invalidation never schedules a viewport restore`() {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        var scheduledCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller.refreshOpenMenusAfterExplicitStoreAction()

        #expect(controller.menuNeedsRefresh(menu))
        #expect(scheduledCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `closed origin cannot transfer restore to another open menu before task starts`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let claudeMenu = controller.makeMenu(for: .claude)
        let codexMenu = controller.makeMenu(for: .codex)
        controller.providerMenus[.claude] = claudeMenu
        controller.providerMenus[.codex] = codexMenu
        controller.menuWillOpen(claudeMenu)

        var scheduledCount = 0
        var restoreCount = 0
        let gate = ViewportRefreshGate()
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }

        controller.performPersistentRefreshAction(in: ObjectIdentifier(claudeMenu))
        controller.menuDidClose(claudeMenu)
        controller.menuWillOpen(codexMenu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.claude)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.claude)])
        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `queued refresh cannot arm restore for a reopened persistent menu`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = try #require(controller.makeMenu(for: .codex) as? StatusItemMenu)
        controller.providerMenus[.codex] = menu
        controller.menuWillOpen(menu)
        let closedSession = try #require(menu.menuInteractionGeneration)

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }

        menu.requestPersistentRefreshAction()
        controller.menuDidClose(menu)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let reopenedSession = try #require(menu.menuInteractionGeneration)
        #expect(reopenedSession != closedSession)

        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)

        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }
}

extension StatusMenuViewportRestoreTests {
    @Test
    func `open non-hosted child menu blocks global viewport restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let rootMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(rootMenu)
        let submenu = NSMenu()
        let submenuItem = NSMenuItem(title: "Submenu", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        rootMenu.addItem(submenuItem)
        controller.menuWillOpen(submenu)
        defer {
            controller.menuDidClose(submenu)
            controller.menuDidClose(rootMenu)
        }

        var scheduledCount = 0
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshNow()
        for _ in 0..<20 where controller.manualRefreshTasks[.global] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.global])
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `opening and closing non-hosted child during refresh invalidates parent restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let rootMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(rootMenu)
        defer { controller.menuDidClose(rootMenu) }
        let rootID = ObjectIdentifier(rootMenu)

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: rootMenu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        let refreshInteraction = try #require(controller.menuSession.menuInteractionGeneration(for: rootID))

        let submenu = NSMenu()
        let submenuItem = NSMenuItem(title: "Submenu", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        rootMenu.addItem(submenuItem)
        controller.menuWillOpen(submenu)
        #expect(controller.menuSession.menuInteractionGeneration(for: rootID) != refreshInteraction)
        controller.menuDidClose(submenu)

        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `non-hosted child opening before delivery invalidates parent restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let rootMenu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(rootMenu)
        defer { controller.menuDidClose(rootMenu) }

        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: rootMenu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        await task.value
        #expect(scheduled.count == 1)

        let submenu = NSMenu()
        let submenuItem = NSMenuItem(title: "Submenu", action: nil, keyEquivalent: "")
        submenuItem.submenu = submenu
        rootMenu.addItem(submenuItem)
        controller.menuWillOpen(submenu)
        defer { controller.menuDidClose(submenu) }
        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `merged selection change discards originating refresh restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnly([.claude, .codex], settings: settings)
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.claude)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.claude)])

        settings.selectedMenuProvider = .codex
        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `merged selection ABA discards originating refresh restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnly([.claude, .codex], settings: settings)
        settings.mergedOverviewSelectedProviders = []
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = UInt64.max
        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let gate = ViewportRefreshGate()
        var scheduled: [@MainActor () -> Void] = []
        var restoreCount = 0
        controller._test_menuViewportRestoreScheduler = { scheduled.append($0) }
        controller._test_menuViewportRestoreObserver = { _ in restoreCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.claude)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.claude)])

        gate.resume()
        await task.value
        #expect(scheduled.count == 1)

        let initialGeneration = try #require(controller.menuSession
            .menuInteractionGeneration(for: ObjectIdentifier(menu)))
        controller.selectOverviewProvider(.codex, menu: menu)
        controller.selectOverviewProvider(.claude, menu: menu)
        #expect(settings.selectedMenuProvider == .claude)
        #expect(controller.menuSession.menuInteractionGeneration(for: ObjectIdentifier(menu)) == initialGeneration + 2)

        scheduled.removeFirst()()

        #expect(restoreCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `queued refresh captures menu interaction before its task starts`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        self.enableOnly([.claude, .codex], settings: settings)
        settings.mergedOverviewSelectedProviders = []
        settings.selectedMenuProvider = .claude
        settings.mergedMenuLastSelectedWasOverview = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = UInt64.max
        let menu = try #require(controller.makeMenu() as? StatusItemMenu)
        controller.mergedMenu = menu
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }

        menu.requestPersistentRefreshAction()
        let actionGeneration = try #require(controller.menuSession
            .menuInteractionGeneration(for: ObjectIdentifier(menu)))
        controller.selectOverviewProvider(.codex, menu: menu)
        controller.selectOverviewProvider(.claude, menu: menu)
        #expect(controller.menuSession.menuInteractionGeneration(for: ObjectIdentifier(menu)) == actionGeneration + 2)

        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.claude)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.claude)])
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)

        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `account selection ABA discards originating refresh restore`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.multiAccountMenuLayout = .segmented
        settings.statusChecksEnabled = false
        self.enableOnly([.copilot], settings: settings)
        settings.addTokenAccount(provider: .copilot, label: "Primary", token: "a")
        settings.addTokenAccount(provider: .copilot, label: "Secondary", token: "b")
        settings.setActiveTokenAccountIndex(0, for: .copilot)

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        controller._test_providerSwitcherMenuRebuildDebounceNanoseconds = UInt64.max
        let menu = controller.makeMenu(for: .copilot)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }
        let switcher = try #require(menu.items.compactMap { $0.view as? TokenAccountSwitcherView }.first)

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_manualRefreshOperation = {
            await gate.wait()
            controller.refreshOpenMenusAfterExplicitStoreAction()
        }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.copilot)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.copilot)])
        let initialGeneration = try #require(controller.menuSession
            .menuInteractionGeneration(for: ObjectIdentifier(menu)))

        let secondaryRefresh = try #require(switcher._test_select(index: 1))
        secondaryRefresh.cancel()
        let primaryRefresh = try #require(switcher._test_select(index: 0))
        primaryRefresh.cancel()
        #expect(settings.tokenAccountsData(for: .copilot)?.clampedActiveIndex() == 0)
        #expect(controller.menuSession.menuInteractionGeneration(for: ObjectIdentifier(menu)) == initialGeneration + 2)

        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `cancelled manual refresh clears restore request without scheduling`() async throws {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        controller.menuRefreshEnabledOverrideForTesting = true
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)

        let gate = ViewportRefreshGate()
        var scheduledCount = 0
        controller._test_menuViewportRestoreScheduler = { _ in scheduledCount += 1 }
        controller._test_manualRefreshOperation = { await gate.wait() }
        controller.refreshMenuProviderNow(in: menu)
        for _ in 0..<20 where controller.manualRefreshTasks[.provider(.codex)] == nil {
            await Task.yield()
        }
        let task = try #require(controller.manualRefreshTasks[.provider(.codex)])
        #expect(!controller.menuSession.pendingViewportRestores.isEmpty)

        task.cancel()
        gate.resume()
        await task.value

        #expect(scheduledCount == 0)
        #expect(controller.menuSession.pendingViewportRestores.isEmpty)
    }

    @Test
    func `viewport restore is a safe no-op without an attached menu window`() {
        let settings = self.makeSettings()
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

        let controller = self.makeController(settings: settings)
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu(for: .codex)
        controller.menuWillOpen(menu)
        defer { controller.menuDidClose(menu) }

        // Menu items exist but no view is hosted in a menu window, so the private
        // scroll view cannot be resolved and the restore must bail out quietly.
        #expect(StatusItemController.attachedMenuScrollView(in: menu) == nil)
        controller.restoreMenuViewportToTop(menu)
    }

    private func keyEvent(_ characters: String, keyCode: UInt16) throws -> NSEvent {
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

    private func enableOnly(_ providers: Set<UsageProvider>, settings: SettingsStore) {
        for provider in UsageProvider.allCases {
            guard let metadata = ProviderRegistry.shared.metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: providers.contains(provider))
        }
    }

    private func runLoop(mode: CFRunLoopMode) {
        CFRunLoopRunInMode(mode, 0.1, true)
    }
}
