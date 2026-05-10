import CodexBarCore
import Foundation
import Observation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
// swiftlint:disable:next type_body_length
struct SettingsStoreTests {
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
    func `default refresh frequency is five minutes`() throws {
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
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.fiveMinutes.rawValue)
    }

    @Test
    func `repairs unrecognized refresh frequency raw value`() throws {
        let suite = "SettingsStoreTests-invalid-refresh"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set("legacyValue", forKey: "refreshFrequency")
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.refreshFrequency == .fiveMinutes)
        #expect(defaults.string(forKey: "refreshFrequency") == RefreshFrequency.fiveMinutes.rawValue)
    }

    @Test
    func `persists refresh frequency across instances`() throws {
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
    func `weekly confetti setting defaults off and persists`() throws {
        let suite = "SettingsStoreTests-weekly-confetti"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeA.confettiOnWeeklyLimitResetsEnabled == false)
        storeA.confettiOnWeeklyLimitResetsEnabled = true

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.confettiOnWeeklyLimitResetsEnabled == true)
    }

    @Test
    func `provider storage setting defaults off and persists`() throws {
        let suite = "SettingsStoreTests-provider-storage"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeA.providerStorageFootprintsEnabled == false)
        #expect(defaultsA.bool(forKey: "providerStorageFootprintsEnabled") == false)
        storeA.providerStorageFootprintsEnabled = true

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.providerStorageFootprintsEnabled == true)
    }

    @Test
    func `persists selected menu provider across instances`() throws {
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
    func `persists merged menu last selected was overview across instances`() throws {
        let suite = "SettingsStoreTests-merged-last-overview"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.mergedMenuLastSelectedWasOverview = true

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.mergedMenuLastSelectedWasOverview == true)
    }

    @Test
    func `merged overview selected providers persists and normalizes across instances`() throws {
        let suite = "SettingsStoreTests-merged-overview-selection"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.mergedOverviewSelectedProviders = [.opencode, .codex, .opencode, .claude]
        #expect(storeA.mergedOverviewSelectedProviders == [.opencode, .codex, .claude])

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.mergedOverviewSelectedProviders == [.opencode, .codex, .claude])
    }

    @Test
    func `merged overview selected providers ignores invalid raw values`() throws {
        let suite = "SettingsStoreTests-merged-overview-invalid-raw"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(["codex", "unknown-provider", "claude", "codex"], forKey: "mergedOverviewSelectedProviders")
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.mergedOverviewSelectedProviders == [.codex, .claude])
    }

    @Test
    func `resolved merged overview providers defaults to first three when selection empty`() throws {
        let suite = "SettingsStoreTests-merged-overview-default-first-three"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor, .opencode, .warp]
        let resolved = store.resolvedMergedOverviewProviders(activeProviders: activeProviders)

        #expect(resolved == [.codex, .claude, .cursor])
    }

    @Test
    func `resolved merged overview providers honors explicit empty selection`() throws {
        let suite = "SettingsStoreTests-merged-overview-explicit-empty"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = []
        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor, .opencode, .warp]
        let resolved = store.resolvedMergedOverviewProviders(activeProviders: activeProviders)

        #expect(resolved == [])
    }

    @Test
    func `resolved merged overview providers uses provider order not selection order`() throws {
        let suite = "SettingsStoreTests-merged-overview-order"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = [.opencode, .codex, .cursor]
        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor, .opencode]
        let resolved = store.resolvedMergedOverviewProviders(activeProviders: activeProviders)

        #expect(resolved == [.codex, .cursor, .opencode])
    }

    @Test
    func `reconcile merged overview selection removes unavailable without auto fill`() throws {
        let suite = "SettingsStoreTests-merged-overview-reconcile"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = [.codex, .claude, .opencode]
        let activeProviders: [UsageProvider] = [.codex, .cursor, .gemini, .opencode]

        let resolved = store.reconcileMergedOverviewSelectedProviders(activeProviders: activeProviders)

        #expect(resolved == [.codex, .opencode])
        #expect(store.mergedOverviewSelectedProviders == [.codex, .opencode])
    }

    @Test
    func `reconcile merged overview selection does not clobber stored preference when three or fewer`() throws {
        let suite = "SettingsStoreTests-merged-overview-three-or-fewer"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = [.codex, .claude, .cursor]
        let activeProviders: [UsageProvider] = [.codex, .claude]

        let resolved = store.reconcileMergedOverviewSelectedProviders(activeProviders: activeProviders)

        #expect(resolved == [.codex, .claude])
        #expect(store.mergedOverviewSelectedProviders == [.codex, .claude, .cursor])
    }

    @Test
    func `reconcile merged overview selection ignores stale subset without persisting auto fill when three or fewer`()
        throws
    {
        let suite = "SettingsStoreTests-merged-overview-three-or-fewer-subset"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = [.codex]
        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor]

        let resolved = store.reconcileMergedOverviewSelectedProviders(activeProviders: activeProviders)

        #expect(resolved == [.codex, .claude, .cursor])
        #expect(store.mergedOverviewSelectedProviders == [.codex])
    }

    @Test
    func `merged overview selection allows deselecting providers when three or fewer`() throws {
        let suite = "SettingsStoreTests-merged-overview-deselect-three-or-fewer"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor]
        #expect(store.resolvedMergedOverviewProviders(activeProviders: activeProviders) == activeProviders)

        _ = store.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)

        #expect(store.mergedOverviewSelectedProviders == [.codex, .cursor])
        #expect(store.resolvedMergedOverviewProviders(activeProviders: activeProviders) == [.codex, .cursor])
    }

    @Test
    func `merged overview selection applies when same active set is reordered`() throws {
        let suite = "SettingsStoreTests-merged-overview-ordered-context"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let initialActiveProviders: [UsageProvider] = [.codex, .claude, .cursor]
        _ = store.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: initialActiveProviders)

        let reorderedActiveProviders: [UsageProvider] = [.cursor, .codex, .claude]
        let resolved = store.resolvedMergedOverviewProviders(activeProviders: reorderedActiveProviders)

        #expect(resolved == [.cursor, .codex])
    }

    @Test
    func `merged overview selection allows deselecting providers when more than three active`() throws {
        let suite = "SettingsStoreTests-merged-overview-deselect-subset"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.mergedOverviewSelectedProviders = [.codex, .claude, .cursor]
        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor, .opencode]

        _ = store.setMergedOverviewProviderSelection(
            provider: .cursor,
            isSelected: false,
            activeProviders: activeProviders)

        #expect(store.mergedOverviewSelectedProviders == [.codex, .claude])
        #expect(store.resolvedMergedOverviewProviders(activeProviders: activeProviders) == [.codex, .claude])
    }

    @Test
    func `reconcile merged overview selection preserves stored subset when active drops to three or fewer`() throws {
        let suite = "SettingsStoreTests-merged-overview-preserve-subset-across-drop"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor, .opencode]
        _ = store.setMergedOverviewProviderSelection(
            provider: .claude,
            isSelected: false,
            activeProviders: activeProviders)
        _ = store.setMergedOverviewProviderSelection(
            provider: .opencode,
            isSelected: true,
            activeProviders: activeProviders)
        #expect(store.mergedOverviewSelectedProviders == [.codex, .cursor, .opencode])

        let reducedActiveProviders: [UsageProvider] = [.codex, .claude, .cursor]
        let resolvedWhenReduced = store.reconcileMergedOverviewSelectedProviders(
            activeProviders: reducedActiveProviders)

        #expect(resolvedWhenReduced == [.codex, .claude, .cursor])
        #expect(store.mergedOverviewSelectedProviders == [.codex, .cursor, .opencode])

        let resolvedWhenRestored = store.resolvedMergedOverviewProviders(activeProviders: activeProviders)
        #expect(resolvedWhenRestored == [.codex, .cursor, .opencode])
    }

    @Test
    func `reconcile merged overview selection clears preference when no providers active`() throws {
        let suite = "SettingsStoreTests-merged-overview-clear-on-empty-active"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let activeProviders: [UsageProvider] = [.codex, .claude, .cursor, .opencode]
        _ = store.setMergedOverviewProviderSelection(
            provider: .codex,
            isSelected: false,
            activeProviders: activeProviders)
        #expect(store.resolvedMergedOverviewProviders(activeProviders: activeProviders) == [.claude, .cursor])

        let resolvedWhenEmpty = store.reconcileMergedOverviewSelectedProviders(activeProviders: [])
        #expect(resolvedWhenEmpty == [])

        let resolvedAfterReenable = store.resolvedMergedOverviewProviders(activeProviders: activeProviders)
        #expect(resolvedAfterReenable == [.codex, .claude, .cursor])
    }

    @Test
    func `persists open code workspace ID across instances`() throws {
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
    func `defaults session quota notifications to enabled`() throws {
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
    func `defaults quota warnings to disabled with global thresholds and sound`() throws {
        let suite = "SettingsStoreTests-quota-warning-defaults"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.quotaWarningNotificationsEnabled == false)
        #expect(store.quotaWarningThresholds == [50, 20])
        #expect(store.quotaWarningWindowEnabled(.session) == true)
        #expect(store.quotaWarningWindowEnabled(.weekly) == true)
        #expect(store.quotaWarningSoundEnabled == true)
        #expect(defaults.array(forKey: "quotaWarningThresholds") as? [Int] == [50, 20])
        #expect(defaults.object(forKey: "quotaWarningSessionEnabled") as? Bool == true)
        #expect(defaults.object(forKey: "quotaWarningWeeklyEnabled") as? Bool == true)
        #expect(defaults.bool(forKey: "quotaWarningSoundEnabled") == true)
    }

    @Test
    func `global quota warning windows persist independently`() throws {
        let suite = "SettingsStoreTests-quota-warning-window-enabled"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.setQuotaWarningWindowEnabled(.weekly, enabled: false)

        #expect(store.quotaWarningWindowEnabled(.session) == true)
        #expect(store.quotaWarningWindowEnabled(.weekly) == false)
        #expect(defaults.object(forKey: "quotaWarningWeeklyEnabled") as? Bool == false)
    }

    @Test
    func `sanitizes invalid quota warning thresholds from defaults`() throws {
        let suite = "SettingsStoreTests-quota-warning-sanitize"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set([120, 20, 20, -5, 50], forKey: "quotaWarningThresholds")
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.quotaWarningThresholds == [99, 50, 20, 0])
        #expect(defaults.array(forKey: "quotaWarningThresholds") as? [Int] == [99, 50, 20, 0])
    }

    @Test
    func `quota warning threshold pair resolves blanks and clamps bounds`() {
        #expect(QuotaWarningThresholds.resolved(upper: nil, lower: nil) == [50, 20])
        #expect(QuotaWarningThresholds.resolved(upper: nil, lower: 10) == [50, 10])
        #expect(QuotaWarningThresholds.resolved(upper: 10, lower: nil) == [10, 0])
        #expect(QuotaWarningThresholds.resolved(upper: 120, lower: -5) == [99, 0])
    }

    @Test
    func `provider quota warning override resolves before global thresholds`() throws {
        let suite = "SettingsStoreTests-quota-warning-provider-override"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        store.quotaWarningThresholds = [50, 20]

        #expect(store.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [50, 20])
        store.setQuotaWarningThresholds(provider: .codex, window: .session, thresholds: [10])
        #expect(store.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [10])
        #expect(store.resolvedQuotaWarningThresholds(provider: .codex, window: .weekly) == [50, 20])

        store.setQuotaWarningThresholds(provider: .codex, window: .session, thresholds: nil)
        #expect(store.resolvedQuotaWarningThresholds(provider: .codex, window: .session) == [50, 20])
    }

    @Test
    func `provider quota warning windows override global enablement independently`() throws {
        let suite = "SettingsStoreTests-quota-warning-provider-window-override"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.setQuotaWarningWindowEnabled(.weekly, enabled: false)
        #expect(store.quotaWarningEnabled(provider: .codex, window: .weekly) == false)

        store.setQuotaWarningWindowEnabled(provider: .codex, window: .weekly, enabled: true)
        store.setQuotaWarningWindowEnabled(provider: .codex, window: .session, enabled: false)
        #expect(store.quotaWarningEnabled(provider: .codex, window: .weekly) == true)
        #expect(store.quotaWarningEnabled(provider: .codex, window: .session) == false)
        #expect(store.hasQuotaWarningOverride(provider: .codex, window: .weekly) == true)
        #expect(store.hasQuotaWarningOverride(provider: .codex, window: .session) == true)

        store.setQuotaWarningWindowEnabled(provider: .codex, window: .weekly, enabled: nil)
        #expect(store.quotaWarningEnabled(provider: .codex, window: .weekly) == false)
    }

    @Test
    func `defaults claude usage source to auto`() throws {
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
    func `defaults codex usage source to auto`() throws {
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
    func `defaults kilo usage source to auto`() throws {
        let suite = "SettingsStoreTests-kilo-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.kiloUsageDataSource == .auto)
    }

    @Test
    func `persists kilo usage source across instances`() throws {
        let suite = "SettingsStoreTests-kilo-source-persist"
        let defaultsA = try #require(UserDefaults(suiteName: suite))
        defaultsA.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let storeA = SettingsStore(
            userDefaults: defaultsA,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        storeA.kiloUsageDataSource = .cli

        let defaultsB = try #require(UserDefaults(suiteName: suite))
        let storeB = SettingsStore(
            userDefaults: defaultsB,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(storeB.kiloUsageDataSource == .cli)
    }

    @Test
    func `kilo extras only apply in auto mode`() throws {
        let suite = "SettingsStoreTests-kilo-extras"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)
        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.kiloExtrasEnabled = true
        #expect(store.kiloExtrasEnabled)

        store.kiloUsageDataSource = .api
        #expect(!store.kiloExtrasEnabled)

        store.kiloUsageDataSource = .auto
        #expect(store.kiloExtrasEnabled)
    }

    @Test
    @MainActor
    func `apply external config does not broadcast`() throws {
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
    func `persists zai API region across instances`() throws {
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
    func `persists mini max API region across instances`() throws {
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
    func `defaults open AI web access to disabled`() throws {
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

        #expect(store.openAIWebAccessEnabled == false)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == false)
        #expect(store.openAIWebBatterySaverEnabled == false)
        #expect(defaults.bool(forKey: "openAIWebBatterySaverEnabled") == false)
        #expect(store.codexCookieSource == .off)
    }

    @Test
    func `infers open AI web access enabled for legacy configured codex cookies`() throws {
        let suite = "SettingsStoreTests-openai-web-legacy"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.removeObject(forKey: "openAIWebAccessEnabled")
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [
            ProviderConfig(id: .codex, cookieSource: .auto),
        ]))

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.openAIWebAccessEnabled == true)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == true)
        #expect(store.openAIWebBatterySaverEnabled == false)
        #expect(defaults.bool(forKey: "openAIWebBatterySaverEnabled") == false)
        #expect(store.codexCookieSource == .auto)
    }

    @Test
    func `imports legacy open AI web access defaults key`() throws {
        let suite = "SettingsStoreTests-openai-web-legacy-key"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.removeObject(forKey: "openAIWebAccessEnabled")
        defaults.set(false, forKey: "openAIWebAccess")
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [
            ProviderConfig(id: .codex, cookieSource: .auto),
        ]))

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.openAIWebAccessEnabled == false)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == false)
    }

    @Test
    func `infers open AI web access enabled for legacy codex config with implicit auto cookies`() throws {
        let suite = "SettingsStoreTests-openai-web-legacy-implicit-auto"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.removeObject(forKey: "openAIWebAccessEnabled")
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suite)
        try configStore.save(CodexBarConfig(providers: [
            ProviderConfig(id: .codex),
        ]))

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.openAIWebAccessEnabled == true)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == true)
        #expect(store.openAIWebBatterySaverEnabled == false)
        #expect(defaults.bool(forKey: "openAIWebBatterySaverEnabled") == false)
        #expect(store.codexCookieSource == .auto)
    }

    @Test
    func `disabling open AI web access turns codex cookie source off`() throws {
        let suite = "SettingsStoreTests-openai-web-toggle"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        store.codexCookieSource = .auto
        #expect(store.codexCookieSource == .auto)

        store.openAIWebAccessEnabled = false
        #expect(store.codexCookieSource == .off)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == false)

        store.openAIWebAccessEnabled = true
        #expect(store.codexCookieSource == .auto)
        #expect(defaults.bool(forKey: "openAIWebAccessEnabled") == true)
    }

    @Test
    func `open AI web battery saver persists separately from extras availability`() throws {
        let suite = "SettingsStoreTests-openai-web-battery-saver"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "debugDisableKeychainAccess")
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        #expect(store.openAIWebBatterySaverEnabled == false)

        store.openAIWebBatterySaverEnabled = false
        #expect(defaults.bool(forKey: "openAIWebBatterySaverEnabled") == false)

        store.openAIWebAccessEnabled = true
        #expect(store.openAIWebBatterySaverEnabled == false)
    }

    @Test
    func `menu observation token updates on defaults change`() async throws {
        let suite = "SettingsStoreTests-observation-defaults"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let didChange = ObservationFlag()

        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            didChange.set()
        }

        store.statusChecksEnabled.toggle()
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(didChange.get() == true)
    }

    @Test
    func `config backed settings trigger observation`() async throws {
        let suite = "SettingsStoreTests-observation-config"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let didChange = ObservationFlag()

        withObservationTracking {
            _ = store.codexCookieSource
        } onChange: {
            didChange.set()
        }

        store.codexCookieSource = .manual
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(didChange.get() == true)
    }

    @Test
    func `menu observation token updates on codex active source change`() async throws {
        let suite = "SettingsStoreTests-observation-codex-active-source"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let didChange = ObservationFlag()

        withObservationTracking {
            _ = store.menuObservationToken
        } onChange: {
            didChange.set()
        }

        store.codexActiveSource = .liveSystem
        try? await Task.sleep(nanoseconds: 50_000_000)

        #expect(didChange.get() == true)
    }

    @Test
    func `provider order defaults to all cases`() throws {
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
    func `provider order persists and appends new providers`() throws {
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
            .opencodego,
            .alibaba,
            .factory,
            .antigravity,
            .copilot,
            .zai,
            .minimax,
            .manus,
            .kimi,
            .kilo,
            .kiro,
            .vertexai,
            .augment,
            .jetbrains,
            .kimik2,
            .amp,
            .ollama,
            .synthetic,
            .warp,
            .openrouter,
            .windsurf,
            .perplexity,
            .mimo,
            .doubao,
            .abacus,
            .mistral,
            .deepseek,
            .codebuff,
            .crof,
            .venice,
            .commandcode,
            .stepfun,
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

    @Test
    func `setting alibaba API key enables provider`() throws {
        let suite = "SettingsStoreTests-alibaba-enable-on-token"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let metadata = try #require(ProviderDescriptorRegistry.metadata[.alibaba])
        store.setProviderEnabled(provider: .alibaba, metadata: metadata, enabled: false)

        store.alibabaCodingPlanAPIToken = "cpk-test-token"

        #expect(store.isProviderEnabled(provider: .alibaba, metadata: metadata))
    }

    @Test
    func `alibaba provider auto enables on startup when token exists`() throws {
        let suite = "SettingsStoreTests-alibaba-auto-enable-startup"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let config = CodexBarConfig(providers: [
            ProviderConfig(id: .alibaba, enabled: false, apiKey: "cpk-startup-token"),
        ])
        try configStore.save(config)

        let store = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())

        let metadata = try #require(ProviderDescriptorRegistry.metadata[.alibaba])
        #expect(store.isProviderEnabled(provider: .alibaba, metadata: metadata))
    }
}
