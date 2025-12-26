import Foundation
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite
struct SettingsStoreTests {
    @Test
    func defaultRefreshFrequencyIsFiveMinutes() {
        let suite = "SettingsStoreTests-default"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = SettingsStore(userDefaults: defaults)

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(store.refreshFrequency.seconds == 300)
    }

    @Test
    func persistsRefreshFrequencyAcrossInstances() {
        let suite = "SettingsStoreTests-persist"
        let defaultsA = UserDefaults(suiteName: suite)!
        defaultsA.removePersistentDomain(forName: suite)
        let storeA = SettingsStore(userDefaults: defaultsA)

        storeA.refreshFrequency = .fifteenMinutes

        let defaultsB = UserDefaults(suiteName: suite)!
        let storeB = SettingsStore(userDefaults: defaultsB)

        #expect(storeB.refreshFrequency == .fifteenMinutes)
        #expect(storeB.refreshFrequency.seconds == 900)
    }

    @Test
    func persistsSelectedMenuProviderAcrossInstances() {
        let suite = "SettingsStoreTests-selectedMenuProvider"
        let defaultsA = UserDefaults(suiteName: suite)!
        defaultsA.removePersistentDomain(forName: suite)
        let storeA = SettingsStore(userDefaults: defaultsA)

        storeA.selectedMenuProvider = .claude

        let defaultsB = UserDefaults(suiteName: suite)!
        let storeB = SettingsStore(userDefaults: defaultsB)

        #expect(storeB.selectedMenuProvider == .claude)
    }

    @Test
    func defaultsSessionQuotaNotificationsToEnabled() {
        let key = "sessionQuotaNotificationsEnabled"
        let suite = "SettingsStoreTests-sessionQuotaNotifications"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = SettingsStore(userDefaults: defaults)
        #expect(store.sessionQuotaNotificationsEnabled == true)
        #expect(defaults.bool(forKey: key) == true)
    }

    @Test
    func defaultsClaudeUsageSourceToWeb() {
        let suite = "SettingsStoreTests-claude-source"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)

        let store = SettingsStore(userDefaults: defaults)

        #expect(store.claudeUsageDataSource == .web)
    }

    @Test
    func providerOrder_defaultsToAllCases() {
        let suite = "SettingsStoreTests-providerOrder-default"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        defaults.set(true, forKey: "providerDetectionCompleted")

        let store = SettingsStore(userDefaults: defaults)

        #expect(store.orderedProviders() == UsageProvider.allCases)
    }

    @Test
    func providerOrder_persistsAndAppendsNewProviders() {
        let suite = "SettingsStoreTests-providerOrder-persist"
        let defaultsA = UserDefaults(suiteName: suite)!
        defaultsA.removePersistentDomain(forName: suite)
        defaultsA.set(true, forKey: "providerDetectionCompleted")

        // Partial list to mimic "older version" missing providers.
        defaultsA.set([UsageProvider.gemini.rawValue, UsageProvider.codex.rawValue], forKey: "providerOrder")

        let storeA = SettingsStore(userDefaults: defaultsA)

        #expect(storeA.orderedProviders() == [.gemini, .codex, .claude, .cursor, .antigravity])

        // Move one provider; ensure it's persisted across instances.
        storeA.moveProvider(fromOffsets: IndexSet(integer: 4), toOffset: 0)

        let defaultsB = UserDefaults(suiteName: suite)!
        defaultsB.set(true, forKey: "providerDetectionCompleted")
        let storeB = SettingsStore(userDefaults: defaultsB)

        #expect(storeB.orderedProviders().first == .antigravity)
    }
}
