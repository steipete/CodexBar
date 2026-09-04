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
        let configStore = testConfigStore(suiteName: "SettingsStoreTests-pace-color")
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
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
        let restored = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(restored.menuBarColorPace)
    }
}
