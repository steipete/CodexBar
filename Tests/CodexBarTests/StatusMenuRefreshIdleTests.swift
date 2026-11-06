import AppKit
import CodexBarCore
import Observation
import os
import Testing
@testable import CodexBar

@MainActor
struct StatusMenuRefreshIdleTests {
    @Test
    func `idle refresh availability observes activity without resolving provider selection`() {
        let settings = testSettingsStore(
            suiteName: "StatusMenuRefreshIdleTests",
            userDefaults: InMemoryUserDefaults(),
            config: testConfigWithAllProvidersDisabled(),
            keychainAccessPolicy: .init(setDisabled: { _ in }, isExplicitlyDisabled: { true }))
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.mergeIcons = false
        settings.randomBlinkEnabled = false
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(userDefaults: InMemoryUserDefaults()),
            menuRefreshEnabled: false,
            observeProviderConfigNotifications: false)
        controller.statusItem.isVisible = false
        defer {
            controller.releaseStatusItemsForTesting()
            store.stopSharedSpendDashboardPublication()
            settings.configFileWatcher?.stop()
        }
        let menu = NSMenu()
        let invalidations = OSAllocatedUnfairLock(initialState: 0)
        let busy = withObservationTracking {
            controller.isRefreshActionInFlight(for: menu)
        } onChange: {
            invalidations.withLock { $0 += 1 }
        }
        #expect(!busy)

        settings.mergeIcons = true
        #expect(invalidations.withLock { $0 } == 0)

        store.isRefreshing = true
        #expect(invalidations.withLock { $0 } == 1)
        #expect(controller.isRefreshActionInFlight(for: menu))
    }
}
