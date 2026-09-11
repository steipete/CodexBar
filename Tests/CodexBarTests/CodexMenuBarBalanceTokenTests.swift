import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct CodexMenuBarBalanceTokenTests {
    @Test
    func `custom Codex balance token shows authoritative workspace credits in status item and preview`() throws {
        let settings = testSettingsStore(
            suiteName: "CodexMenuBarBalanceTokenTests-workspace-balance",
            userDefaults: InMemoryUserDefaults())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = UsageProvider.codex.instanceID
        settings.menuBarDisplayMode = .both
        settings.menuBarIconStyle = .iconAndPercent
        settings.usageBarsShowUsed = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let layout = MenuBarLayout(lines: [[.percent(window: .automatic), .separatorDot, .balance]])
        settings.setMenuBarLayout(layout, for: nil)

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

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 96,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(3600),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(
            remaining: 1234.73,
            events: [],
            updatedAt: now,
            balanceReadSucceeded: true,
            creditsAvailable: true,
            balanceIsWorkspace: true)

        let statusItemData = controller.menuBarLayoutRenderData(
            provider: .codex,
            snapshot: snapshot,
            warningFlash: false,
            now: now)
        let previewData = MenuBarLayoutPreview(
            layout: layout,
            provider: .codex,
            settings: settings,
            store: store)
            .liveData(provider: .codex, snapshot: snapshot)

        #expect(statusItemData.balance == "1,235")
        #expect(previewData.balance == "1,235")

        // Exercise the observation wiring: the rate windows do not change when credits arrive later.
        let initialSignature = controller.storeIconObservationSignature()
        store.credits = CreditsSnapshot(
            remaining: 1233.49,
            events: [],
            updatedAt: now,
            creditsAvailable: true,
            balanceIsWorkspace: true)
        #expect(controller.storeIconObservationSignature() != initialSignature)
        #expect(controller.storeIconObservationSignature().contains("text=1,233"))
    }
}
