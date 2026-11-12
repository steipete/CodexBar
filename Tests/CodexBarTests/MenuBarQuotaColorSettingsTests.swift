import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
struct MenuBarQuotaColorSettingsTests {
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
    func `quota colors default off persist and trigger menu observation`() {
        let defaults = InMemoryUserDefaults()
        let store = testSettingsStore(suiteName: "quota-color", userDefaults: defaults)
        #expect(!store.menuBarColorByQuota)
        #expect(defaults.object(forKey: "menuBarColorByQuota") == nil)
        let changed = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            changed.set()
        }
        store.menuBarColorByQuota = true
        #expect(changed.get())
        #expect(defaults.bool(forKey: "menuBarColorByQuota"))
        let restored = testSettingsStore(suiteName: "quota-color-restored", userDefaults: defaults)
        #expect(restored.menuBarColorByQuota)
    }

    @Test
    func `quota colors leave the other icon color settings unchanged`() {
        let defaults = InMemoryUserDefaults()
        let store = testSettingsStore(suiteName: "quota-color-independent", userDefaults: defaults)
        let pace = store.menuBarColorPace
        let provider = store.menuBarColorByProvider
        store.menuBarColorByQuota = true
        let restored = testSettingsStore(suiteName: "quota-color-independent-restored", userDefaults: defaults)
        #expect(restored.menuBarColorByQuota)
        #expect(restored.menuBarColorPace == pace)
        #expect(restored.menuBarColorByProvider == provider)
    }
}
