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
}
