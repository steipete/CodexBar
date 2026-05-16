import Foundation
import Testing
@testable import CodexBar

struct MenuBarVisibilityWatcherTests {
    @Test
    func `does not flag intentionally hidden status item`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: false,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item without attached window`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item without button`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: false,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 0)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item with zero width`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 0)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `allows visible item attached to a screen with width`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `flags visible item attached to a detached screen`() {
        let snapshot = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            isOnCurrentScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.isBlockedSnapshot(snapshot: snapshot))
    }

    @Test
    func `guidance shows once then repeats after a day`() throws {
        let defaults = try #require(UserDefaults(suiteName: "MenuBarVisibilityWatcherTests"))
        defaults.removePersistentDomain(forName: "MenuBarVisibilityWatcherTests")
        let now = Date(timeIntervalSince1970: 1000)

        #expect(MenuBarVisibilityWatcher.shouldShowGuidance(defaults: defaults, now: now))

        MenuBarVisibilityWatcher.markGuidanceShown(defaults: defaults, now: now)

        #expect(!MenuBarVisibilityWatcher.shouldShowGuidance(
            defaults: defaults,
            now: now.addingTimeInterval(MenuBarVisibilityWatcher.guidanceRepeatInterval - 1)))
        #expect(MenuBarVisibilityWatcher.shouldShowGuidance(
            defaults: defaults,
            now: now.addingTimeInterval(MenuBarVisibilityWatcher.guidanceRepeatInterval)))
    }

    @Test
    func `startup recovery triggers for blocked visible snapshot`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [blocked]))
    }

    @Test
    func `startup recovery triggers when one split status item is blocked`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [healthy, blocked]))
    }

    @Test
    func `startup recovery ignores stale checks`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(MenuBarVisibilityWatcher.startupFreshnessInterval + 1),
            snapshots: [blocked]))
    }

    @Test
    func `startup recovery ignores healthy visible snapshot`() {
        let launchedAt = Date(timeIntervalSince1970: 1000)
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptStartupRecovery(
            appLaunchedAt: launchedAt,
            now: launchedAt.addingTimeInterval(2),
            snapshots: [healthy]))
    }

    @Test
    func `screen change recovery triggers when a display is removed with visible status item`() {
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptScreenChangeRecovery(
            previousScreenCount: 2,
            currentScreenCount: 1,
            snapshots: [healthy]))
    }

    @Test
    func `screen change recovery triggers for blocked status item without display count change`() {
        let blocked = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: false,
            hasScreen: false,
            buttonWidth: 18)

        #expect(MenuBarVisibilityWatcher.shouldAttemptScreenChangeRecovery(
            previousScreenCount: 1,
            currentScreenCount: 1,
            snapshots: [blocked]))
    }

    @Test
    func `screen change recovery ignores healthy item when display count does not shrink`() {
        let healthy = StatusItemVisibilitySnapshot(
            isVisible: true,
            hasButton: true,
            hasWindow: true,
            hasScreen: true,
            buttonWidth: 18)

        #expect(!MenuBarVisibilityWatcher.shouldAttemptScreenChangeRecovery(
            previousScreenCount: 1,
            currentScreenCount: 2,
            snapshots: [healthy]))
    }
}
