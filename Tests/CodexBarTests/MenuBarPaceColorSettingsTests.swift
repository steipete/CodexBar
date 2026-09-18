import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarPaceColorSettingsTests {
    private final class ObservationFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = false

        func set() {
            self.lock.lock()
            self.value = true
            self.lock.unlock()
        }

        func get() -> Bool {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    @Test
    func `pace color defaults off persists and triggers menu observation`() {
        let defaults = InMemoryUserDefaults()
        let store = testSettingsStore(suiteName: "pace-color", userDefaults: defaults)
        #expect(!store.menuBarColorPace)
        let changed = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            changed.set()
        }
        store.menuBarColorPace = true
        #expect(changed.get())
        #expect(defaults.bool(forKey: "menuBarColorPace"))
        let restored = testSettingsStore(suiteName: "pace-color-restored", userDefaults: defaults)
        #expect(restored.menuBarColorPace)
    }

    @Test(arguments: [false, true])
    func `upgraded preferences keep their layout and default to monochrome`(storedLayout: Bool) {
        let defaults = InMemoryUserDefaults()
        let previous = testSettingsStore(suiteName: "pace-color-upgrade", userDefaults: defaults)
        previous.menuBarDisplayMode = .both
        previous.menuBarLayoutGap = .tight
        if storedLayout {
            previous.menuBarLayout = MenuBarLayout(lines: [[.pace(window: .weekly)]])
            previous.setMenuBarLayout(MenuBarLayout(lines: [[.pace(window: .session)]]), for: .claude)
        }
        let originalLayout = previous.menuBarLayout
        let originalOverrides = previous.menuBarLayoutOverrides
        #expect(defaults.object(forKey: "menuBarColorPace") == nil)

        let upgraded = testSettingsStore(suiteName: "pace-color-upgraded", userDefaults: defaults)
        #expect(!upgraded.menuBarColorPace)
        #expect(defaults.object(forKey: "menuBarColorPace") == nil)
        for enabled in [true, false] {
            upgraded.menuBarColorPace = enabled
            let restored = testSettingsStore(suiteName: "pace-color-reloaded", userDefaults: defaults)
            #expect(restored.menuBarColorPace == enabled)
            #expect(restored.hasStoredMenuBarLayout == storedLayout)
            #expect(restored.menuBarLayout == originalLayout)
            #expect(restored.menuBarLayoutOverrides == originalOverrides)
            #expect(restored.menuBarDisplayMode == .both)
            #expect(restored.menuBarLayoutGap == .tight)
        }
    }
}
