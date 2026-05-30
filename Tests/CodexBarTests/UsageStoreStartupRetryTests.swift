import Foundation
import Testing
@testable import CodexBar
@testable import CodexBarCore

@MainActor
@Suite(.serialized)
struct UsageStoreStartupRetryTests {
    @Test
    func `startup refresh failure schedules retry that recovers`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "UsageStoreStartupRetryTests-retry-recovers")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false

        UsageStore.startupRetryDelay = .milliseconds(10)
        defer { UsageStore.startupRetryDelay = .seconds(30) }

        let store = self.makeStore(settings: settings)

        store._test_providerRefreshOverride = { [store] _ in
            store._setErrorForTesting(
                "The Internet connection appears to be offline.", provider: .codex)
        }
        defer { store._test_providerRefreshOverride = nil }

        await store.refresh()
        #expect(store.errors[.codex] != nil)
        #expect(store.snapshots[.codex] == nil)

        store._test_providerRefreshOverride = { [store] _ in
            store._setErrorForTesting(nil, provider: .codex)
            store._setSnapshotForTesting(
                UsageSnapshot(
                    primary: RateWindow(
                        usedPercent: 10,
                        windowMinutes: 300,
                        resetsAt: Date().addingTimeInterval(1800),
                        resetDescription: nil),
                    secondary: nil,
                    tertiary: nil,
                    updatedAt: Date(),
                    identity: ProviderIdentitySnapshot(
                        providerID: .codex,
                        accountEmail: "test@example.com",
                        accountOrganization: nil,
                        loginMethod: "Plus Plan")),
                provider: .codex)
        }

        store.scheduleStartupRetryIfNeeded()
        let retryTask = try #require(store.startupRetryTask)
        await retryTask.value

        #expect(store.errors[.codex] == nil)
        #expect(store.snapshots[.codex] != nil)
    }

    @Test
    func `startup retry is not scheduled when refresh succeeds`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "UsageStoreStartupRetryTests-no-retry-on-success")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false

        let store = self.makeStore(settings: settings)
        store._test_providerRefreshOverride = { _ in }
        defer { store._test_providerRefreshOverride = nil }

        await store.refresh()
        store.scheduleStartupRetryIfNeeded()
        #expect(store.startupRetryTask == nil)
    }

    @Test
    func `startup retry is not scheduled twice`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "UsageStoreStartupRetryTests-no-duplicate-retry")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false

        let store = self.makeStore(settings: settings)

        store._test_providerRefreshOverride = { [store] _ in
            store._setErrorForTesting("Network error", provider: .codex)
        }
        defer { store._test_providerRefreshOverride = nil }

        await store.refresh()

        UsageStore.startupRetryDelay = .milliseconds(50)
        defer { UsageStore.startupRetryDelay = .seconds(30) }

        store.scheduleStartupRetryIfNeeded()
        #expect(store.startupRetryTask != nil)

        store.scheduleStartupRetryIfNeeded()
        #expect(store.startupRetryTask != nil)

        store.startupRetryTask?.cancel()
    }

    @Test
    func `startup retry task is cleared after completion`() async throws {
        let settings = try self.makeSettingsStore(
            suite: "UsageStoreStartupRetryTests-task-cleared")
        settings.statusChecksEnabled = false
        settings.openAIWebAccessEnabled = false

        UsageStore.startupRetryDelay = .milliseconds(10)
        defer { UsageStore.startupRetryDelay = .seconds(30) }

        let store = self.makeStore(settings: settings)

        store._test_providerRefreshOverride = { [store] _ in
            store._setErrorForTesting("Network error", provider: .codex)
        }
        defer { store._test_providerRefreshOverride = nil }

        await store.refresh()

        store._test_providerRefreshOverride = { _ in }

        store.scheduleStartupRetryIfNeeded()
        #expect(store.startupRetryTask != nil)

        let retryTask = try #require(store.startupRetryTask)
        await retryTask.value

        #expect(store.startupRetryTask == nil)
    }

    private func makeSettingsStore(suite: String) throws -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")
        let configStore = testConfigStore(suiteName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        let codexMetadata = try #require(ProviderDescriptorRegistry.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: codexMetadata, enabled: true)
        settings.providerDetectionCompleted = true
        return settings
    }

    private func makeStore(settings: SettingsStore) -> UsageStore {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing)
    }
}
