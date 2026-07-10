import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MenuBarSmartResetIntegrationTests {
    @Test(arguments: [MenuBarDisplayMode.pace, .both])
    func `combined smart reset keeps exhausted session percent without a reset`(mode: MenuBarDisplayMode) {
        let settings = testSettingsStore(
            suiteName: "MenuBarSmartResetIntegrationTests-combined-fallback-\(mode.rawValue)")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = mode
        settings.menuBarShowsResetTimeWhenExhausted = true
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)

        if let metadata = ProviderRegistry.shared.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: metadata, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(
            fetcher: fetcher,
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 50,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        // Weekly pace remains available, but it must not hide that the displayed session is exhausted.
        // Without a concrete future session reset there is no reset text or timer to surface instead.
        #expect(controller.menuBarDisplayText(for: .claude, snapshot: snapshot, now: now) == "0%")
        #expect(controller.menuBarDisplayedResetDates(for: .claude, now: now).isEmpty)
        #expect(!controller._test_isMenuBarCountdownRefreshScheduled())
    }
}
