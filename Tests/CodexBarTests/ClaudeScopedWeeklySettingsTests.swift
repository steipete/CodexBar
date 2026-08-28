import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct ClaudeScopedWeeklySettingsTests {
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
    func `Claude model scoped widget usage defaults off persists and refreshes only menus`() async throws {
        let suite = "ClaudeScopedWeeklySettingsTests-claude-model-scoped-widget-usage-visible"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.claudeModelScopedWeeklyUsageVisible == false)
        let backgroundRevision = store.backgroundWorkSettingsRevision
        let menuDidChange = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            menuDidChange.set()
        }
        store.claudeModelScopedWeeklyUsageVisible = true
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(store.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(menuDidChange.get())

        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(reloaded.claudeModelScopedWeeklyUsageVisible)
    }
}
