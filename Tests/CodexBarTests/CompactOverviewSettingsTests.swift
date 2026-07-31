import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CompactOverviewSettingsTests {
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
    func `compact overview defaults off persists and refreshes only menus`() async throws {
        let suite = "SettingsStoreTests-compact-overview"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.mergedOverviewUsesCompactLayout == false)
        #expect(defaults.object(forKey: "mergedOverviewUsesCompactLayout") == nil)

        let configEncoder = JSONEncoder()
        configEncoder.outputFormatting = .sortedKeys
        let configData = try configEncoder.encode(store.configSnapshot)
        let configRevision = store.configRevision
        let backgroundRevision = store.backgroundWorkSettingsRevision
        let providerDetailRevision = store.providerDetailSettingsRevision
        let costUsageRevision = store.costUsageSettingsRevision
        let menuDidChange = ObservationFlag()
        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            menuDidChange.set()
        }

        store.mergedOverviewUsesCompactLayout = true
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(defaults.bool(forKey: "mergedOverviewUsesCompactLayout"))
        #expect(menuDidChange.get())
        #expect(try configEncoder.encode(store.configSnapshot) == configData)
        #expect(store.configRevision == configRevision)
        #expect(store.backgroundWorkSettingsRevision == backgroundRevision)
        #expect(store.providerDetailSettingsRevision == providerDetailRevision)
        #expect(store.costUsageSettingsRevision == costUsageRevision)

        let reloaded = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(reloaded.mergedOverviewUsesCompactLayout)
    }
}
