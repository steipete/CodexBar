import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite
struct StatusItemVisibilityTests {
    @Test
    func statusItemVisibleWhenThresholdDisabled() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = false
        settings.statusItemThresholdPercent = 80

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Usage at 50% (below 80% threshold), but threshold is disabled
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        #expect(controller.isVisible(.codex) == true)
    }

    @Test
    func statusItemHiddenWhenBelowThreshold() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Usage at 50% (below 80% threshold)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        #expect(controller.isVisible(.codex) == false)
    }

    @Test
    func statusItemVisibleWhenAboveThreshold() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Usage at 90% (above 80% threshold)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        #expect(controller.isVisible(.codex) == true)
    }

    @Test
    func statusItemHiddenWhenProviderDisabled() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80

        let registry = ProviderRegistry.shared
        // Enable claude so codex isn't the fallback when disabled
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        // Disable codex
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: false)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Usage at 50% (below 80% threshold), provider disabled
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        // Should be hidden because provider is disabled (not because of threshold)
        #expect(controller.isVisible(.codex) == false)
    }

    @Test
    func statusItemVisibleWhenNoSnapshot() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // No snapshot available
        store._setSnapshotForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        // Should be visible when no data is available (default to visible)
        #expect(controller.isVisible(.codex) == true)
    }

    @Test
    func statusItemVisibleWhenMenuOpen() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Usage at 50% (below 80% threshold)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        // Simulate a menu being open
        let menu = NSMenu()
        controller.openMenus[ObjectIdentifier(menu)] = menu

        // Should be visible while menu is open, even though below threshold
        #expect(controller.isVisible(.codex) == true)
    }

    @Test
    func mergedIconVisibleWhenThresholdDisabled() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = false
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Both providers at 50% (below 80% threshold), but threshold is disabled
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        #expect(controller.statusItem.isVisible == true)
    }

    @Test
    func mergedIconHiddenWhenAllProvidersBelowThreshold() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Both providers at 50% (below 80% threshold)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        controller.updateVisibility()

        #expect(controller.statusItem.isVisible == false)
    }

    @Test
    func mergedIconVisibleWhenOneProviderAboveThreshold() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Codex at 50% (below), Claude at 90% (above)
        let lowSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        let highSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(lowSnapshot, provider: .codex)
        store._setSnapshotForTesting(highSnapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        controller.updateVisibility()

        #expect(controller.statusItem.isVisible == true)
    }

    @Test
    func mergedIconVisibleWhenMenuOpenEvenIfAllBelowThreshold() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Both providers at 50% (below 80% threshold)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        // Simulate a menu being open
        let menu = NSMenu()
        controller.openMenus[ObjectIdentifier(menu)] = menu

        controller.updateVisibility()

        #expect(controller.statusItem.isVisible == true)
    }

    @Test
    func mergedIconVisibleWhenAllProvidersAboveThreshold() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        // Cancel the launch visibility task to immediately apply threshold
        controller.launchVisibilityTask?.cancel()

        // Both providers at 90% (above 80% threshold)
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        controller.updateVisibility()

        #expect(controller.statusItem.isVisible == true)
    }

    @Test
    func mergedIconVisibleWhenNoProvidersEnabledAndThresholdDisabled() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = false
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        // Disable all providers
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
            }
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        controller.launchVisibilityTask?.cancel()
        controller.updateVisibility()

        // Should be visible because threshold setting is disabled
        #expect(controller.statusItem.isVisible == true)
    }

    @Test
    func mergedIconHiddenWhenNoProvidersEnabledAndThresholdEnabled() {
        let settings = SettingsStore(zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.hideStatusItemBelowThreshold = true
        settings.statusItemThresholdPercent = 80
        settings.mergeIcons = true

        let registry = ProviderRegistry.shared
        // Disable all providers
        for provider in UsageProvider.allCases {
            if let metadata = registry.metadata[provider] {
                settings.setProviderEnabled(provider: provider, metadata: metadata, enabled: false)
            }
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection())

        controller.launchVisibilityTask?.cancel()
        controller.updateVisibility()

        // Should be hidden because threshold setting is enabled
        #expect(controller.statusItem.isVisible == false)
    }
}
