import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@MainActor
@Suite
struct SettingsStoreTests {
    @Test
    func defaultRefreshFrequencyIsFiveMinutes() throws {
        let suite = "SettingsStoreTests-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(store.refreshFrequency.seconds == 300)
    }

    @Test
    func persistsRefreshFrequencyAcrossInstances() throws {
        let suite = "SettingsStoreTests-persist"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.refreshFrequency = .fifteenMinutes

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.refreshFrequency == .fifteenMinutes)
        #expect(storeB.refreshFrequency.seconds == 900)
    }

    @Test
    func persistsSelectedMenuProviderAcrossInstances() throws {
        let suite = "SettingsStoreTests-selectedMenuProvider"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.selectedMenuProvider = .claude

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.selectedMenuProvider == .claude)
    }

    @Test
    func persistsOpenCodeWorkspaceIDAcrossInstances() throws {
        let suite = "SettingsStoreTests-opencode-workspace"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())

        storeA.opencodeWorkspaceID = "wrk_01KEJ50SHK9YR41HSRSJ6QTFCM"

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())

        #expect(storeB.opencodeWorkspaceID == "wrk_01KEJ50SHK9YR41HSRSJ6QTFCM")
    }

    @Test
    func defaultsSessionQuotaNotificationsToEnabled() throws {
        let key = "sessionQuotaNotificationsEnabled"
        let suite = "SettingsStoreTests-sessionQuotaNotifications"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        #expect(store.sessionQuotaNotificationsEnabled == true)
        #expect(defaults.bool(forKey: key) == true)
    }

    @Test
    func defaultsClaudeUsageSourceToAuto() throws {
        let suite = "SettingsStoreTests-claude-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.claudeUsageDataSource == .auto)
    }

    @Test
    func defaultsCodexUsageSourceToAuto() throws {
        let suite = "SettingsStoreTests-codex-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.codexUsageDataSource == .auto)
    }

    @Test
    @MainActor
    func applyExternalConfigDoesNotBroadcast() throws {
        let suite = "SettingsStoreTests-external-config"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        final class NotificationCounter: @unchecked Sendable {
            private let lock = NSLock()
            private var value = 0

            func increment() {
                self.lock.lock()
                self.value += 1
                self.lock.unlock()
            }

            func get() -> Int {
                self.lock.lock()
                defer { self.lock.unlock() }
                return self.value
            }
        }

        let notifications = NotificationCounter()
        let token = NotificationCenter.default.addObserver(
            forName: .codexbarProviderConfigDidChange,
            object: store,
            queue: .main)
        { _ in
            notifications.increment()
        }
        defer { NotificationCenter.default.removeObserver(token) }

        store.applyExternalConfig(store.configSnapshot, reason: "test-external")

        #expect(notifications.get() == 0)
    }

    @Test
    func persistsZaiAPIRegionAcrossInstances() throws {
        let suite = "SettingsStoreTests-zai-region"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())

        storeA.zaiAPIRegion = .bigmodelCN

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())

        #expect(storeB.zaiAPIRegion == .bigmodelCN)
    }

    @Test
    func persistsMiniMaxAPIRegionAcrossInstances() throws {
        let suite = "SettingsStoreTests-minimax-region"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())

        storeA.minimaxAPIRegion = .chinaMainland

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore())

        #expect(storeB.minimaxAPIRegion == .chinaMainland)
    }

    @Test
    func defaultsOpenAIWebAccessToEnabled() throws {
        let suite = "SettingsStoreTests-openai-web"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.openAIWebAccessEnabled == true)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == true)
        #expect(store.codexCookieSource == .auto)
    }

    @Test
    func menuObservationTokenUpdatesOnDefaultsChange() async throws {
        let suite = "SettingsStoreTests-observation-defaults"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        var didChange = false

        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            Task { @MainActor in
                didChange = true
            }
        }

        store.statusChecksEnabled.toggle()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(didChange == true)
    }

    @Test
    func configBackedSettingsTriggerObservation() async throws {
        let suite = "SettingsStoreTests-observation-config"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        var didChange = false

        withObservationTracking {
            _ = store.codexCookieSource
        } onChange: {
            Task { @MainActor in
                didChange = true
            }
        }

        store.codexCookieSource = .manual
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(didChange == true)
    }

    @Test
    func providerOrder_defaultsToAllCases() throws {
        let suite = "SettingsStoreTests-providerOrder-default"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.orderedProviders() == UsageProvider.allCases)
    }

    @Test
    func providerOrder_persistsAndAppendsNewProviders() throws {
        let suite = "SettingsStoreTests-providerOrder-persist"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        // Partial list to mimic "older version" missing providers.
        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .gemini),
            ProviderConfig(id: .codex),
        ])
        try configStore.save(config)

        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeA.orderedProviders() == [
            .gemini,
            .codex,
            .claude,
            .cursor,
            .opencode,
            .factory,
            .antigravity,
            .copilot,
            .zai,
            .minimax,
            .kimi,
            .kiro,
            .vertexai,
            .augment,
            .jetbrains,
            .kimik2,
            .amp,
            .synthetic,
        ])

        // Move one provider; ensure it's persisted across instances.
        let antigravityIndex = try #require(storeA.orderedProviders().firstIndex(of: .antigravity))
        storeA.moveProvider(fromOffsets: IndexSet(integer: antigravityIndex), toOffset: 0)

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.orderedProviders().first == .antigravity)
    }
}
