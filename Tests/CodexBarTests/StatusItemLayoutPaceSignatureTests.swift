import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemLayoutPaceSignatureTests {
    @Test
    func `icon observation signature tracks stored layout pace tokens`() {
        let suite = "StatusItemLayoutPaceSignatureTests-layout-pace-signature"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarLayout = MenuBarLayout(lines: [[
            .icon,
            .percent(window: .weekly),
            .separatorDot,
            .pace(window: .weekly),
        ]])

        let registry = ProviderRegistry.shared
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        func snapshot(weeklyResetInDays days: Double) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 30,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(60 * 60),
                    resetDescription: nil),
                secondary: RateWindow(
                    usedPercent: 60,
                    windowMinutes: 10080,
                    resetsAt: now.addingTimeInterval(days * 24 * 60 * 60),
                    resetDescription: nil),
                updatedAt: now)
        }

        store._setSnapshotForTesting(snapshot(weeklyResetInDays: 3), provider: .claude)
        let nearReset = controller.storeIconObservationSignature()

        // Same used percents, later reset => identical percent fields but a different pace delta.
        // The observer must see a signature change here, or a custom pace token renders stale.
        store._setSnapshotForTesting(snapshot(weeklyResetInDays: 6), provider: .claude)
        let farReset = controller.storeIconObservationSignature()

        #expect(nearReset.contains("layoutPace=weekly="))
        #expect(nearReset != farReset)
    }
}
