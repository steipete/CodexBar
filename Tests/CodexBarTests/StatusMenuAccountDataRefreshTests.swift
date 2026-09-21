import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusMenuAccountDataRefreshTests {
    @Test
    func `account data rebuilds coalesce during tracking and execute only once across modes`() throws {
        try self.withMenu { _, controller, menu in
            var rebuilds = 0
            controller._test_openMenuRebuildObserver = { rebuilt in
                #expect(rebuilt === menu)
                rebuilds += 1
            }
            defer { controller._test_openMenuRebuildObserver = nil }
            for _ in 0..<3 {
                controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex)
            }
            #expect(controller.menuNeedsRefresh(menu))
            Self.drainTracking()
            #expect(rebuilds == 1)
            #expect(!controller.menuNeedsRefresh(menu))
            CFRunLoopRunInMode(.defaultMode, 0.1, true)
            #expect(rebuilds == 1)
        }
    }

    @Test
    func `account data rebuild preserves a hosted submenu and leaves parent stale`() throws {
        try self.withMenu { _, controller, menu in
            let submenu = controller.makeHostedSubviewPlaceholderMenu(
                chartID: StatusItemController.costHistoryChartID, provider: .codex)
            let childKey = ObjectIdentifier(submenu)
            controller.openMenus[childKey] = submenu
            defer { controller.openMenus.removeValue(forKey: childKey) }
            var rebuilds = 0
            controller._test_openMenuRebuildObserver = { _ in rebuilds += 1 }
            defer { controller._test_openMenuRebuildObserver = nil }
            controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex)
            Self.drainTracking()
            #expect(rebuilds == 0)
            #expect(controller.openMenus[childKey] === submenu)
            #expect(controller.menuNeedsRefresh(menu))
            #expect(!controller.openMenuRebuildsClosingHostedSubviewMenus.contains(ObjectIdentifier(menu)))
        }
    }

    @Test
    func `account data resumes during parent tracking after a hosted submenu closes`() throws {
        try self.withMenu { _, controller, menu in
            let submenu = controller.makeHostedSubviewPlaceholderMenu(
                chartID: StatusItemController.costHistoryChartID, provider: .codex)
            let childKey = ObjectIdentifier(submenu)
            controller.openMenus[childKey] = submenu
            controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex)
            Self.drainTracking()
            #expect(controller.menuNeedsRefresh(menu))
            controller.menuDidClose(submenu)
            Self.drainTracking()
            #expect(!controller.menuNeedsRefresh(menu))
            #expect(controller.openMenus[childKey] == nil)
        }
    }

    @Test
    func `account data resumes during tracking after a native highlight clears`() throws {
        try self.withMenu { _, controller, menu in
            let key = ObjectIdentifier(menu)
            let item = NSMenuItem(title: "Synthetic action", action: nil, keyEquivalent: "")
            item.isEnabled = true
            menu.addItem(item)
            controller.highlightedMenuItems[key] = item
            controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex)
            Self.drainTracking()
            #expect(controller.menuNeedsRefresh(menu))
            #expect(controller.nativeHighlightDeferredMenuRebuilds[key] != nil)
            controller.highlightedMenuItems.removeValue(forKey: key)
            controller.resumeMenuRebuildDeferredForNativeHighlightIfNeeded(menu)
            Self.drainTracking()
            #expect(!controller.menuNeedsRefresh(menu))
            #expect(controller.nativeHighlightDeferredMenuRebuilds[key] == nil)
        }
    }

    @Test
    func `late account data cannot replace a newer provider selection request`() throws {
        try self.withMenu { fixture, controller, menu in
            fixture.settings.setProviderEnabled(
                provider: .claude,
                metadata: ProviderDescriptorRegistry.descriptor(for: .claude).metadata,
                enabled: true)
            controller.selectedMenuProvider = .claude
            fixture.settings.mergedMenuLastSelectedWasOverview = false
            var selectionRequestRan = false
            controller.scheduleTrackingMenuRebuildIfStillVisible(menu, provider: .claude) {
                selectionRequestRan = true
                return true
            }
            let version = controller.menuContentVersion
            controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex)
            #expect(controller.menuContentVersion == version)
            Self.drainTracking()
            #expect(selectionRequestRan)
            #expect(controller.selectedMenuProvider == .claude)
        }
    }

    @Test
    func `queued account data is discarded when account ownership changes before execution`() throws {
        try self.withMenu { _, controller, menu in
            let selection = AccountSelection()
            var rebuilds = 0
            controller._test_openMenuRebuildObserver = { _ in rebuilds += 1 }
            defer { controller._test_openMenuRebuildObserver = nil }
            controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex) {
                selection.id == "account-a"
            }
            selection.id = "account-b"
            Self.drainTracking()
            #expect(rebuilds == 0)
            #expect(controller.menuNeedsRefresh(menu))
        }
    }

    @Test
    func `closing an account menu discards its pending data rebuild`() throws {
        try self.withMenu { _, controller, menu in
            var rebuilds = 0
            controller._test_openMenuRebuildObserver = { _ in rebuilds += 1 }
            defer { controller._test_openMenuRebuildObserver = nil }
            controller.scheduleOpenRootMenuDataRebuildIfStillVisible(menu, provider: .codex)
            controller.menuDidClose(menu)
            Self.drainTracking()
            #expect(rebuilds == 0)
            #expect(controller.openMenus[ObjectIdentifier(menu)] == nil)
        }
    }

    @MainActor
    private final class AccountSelection {
        var id = "account-a"
    }

    private func withMenu(
        _ body: (CodexAccountMenuPhaseFixture, StatusItemController, NSMenu) throws -> Void) throws
    {
        let previousRendering = StatusItemController.menuCardRenderingEnabled
        let previousRefresh = StatusItemController.menuRefreshEnabled
        StatusItemController.menuCardRenderingEnabled = false
        StatusItemController.setMenuRefreshEnabledForTesting(true)
        defer {
            StatusItemController.menuCardRenderingEnabled = previousRendering
            StatusItemController.setMenuRefreshEnabledForTesting(previousRefresh)
        }
        let fixture = try CodexAccountMenuPhaseFixture()
        defer { fixture.cleanup() }
        let controller = fixture.makeController()
        defer { controller.releaseStatusItemsForTesting() }
        let menu = controller.makeMenu()
        controller.menuWillOpen(menu)
        try body(fixture, controller, menu)
    }

    private static func drainTracking() {
        CFRunLoopRunInMode(CFRunLoopMode(RunLoop.Mode.eventTracking.rawValue as CFString), 0.1, true)
    }
}
