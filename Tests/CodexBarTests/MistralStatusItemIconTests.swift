import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MistralStatusItemIconTests {
    @Test
    func `mistral automatic icon uses allowance window without billing history`() {
        let suite = "MistralStatusItemIconTests-automatic-allowance"
        let settings = testSettingsStore(suiteName: suite)
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.setMenuBarMetricPreference(.automatic, for: .mistral)

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

        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 35,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: "$3.50 / $10.00"),
            secondary: nil,
            updatedAt: Date())

        let usedPercents = controller.resolvedMenuBarIconPercents(
            provider: .mistral,
            snapshot: snapshot,
            style: .mistral,
            showUsed: true)
        #expect(usedPercents?.primary == 35)
        #expect(usedPercents?.secondary == nil)

        let remainingPercents = controller.resolvedMenuBarIconPercents(
            provider: .mistral,
            snapshot: snapshot,
            style: .mistral,
            showUsed: false)
        #expect(remainingPercents?.primary == 65)
        #expect(remainingPercents?.secondary == nil)
    }
}
