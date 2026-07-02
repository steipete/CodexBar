import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

/// Regression coverage for the combined "Session + Weekly" menu-bar metric ignoring Claude web's
/// synthetic `five_hour: null` session placeholder. Claude web parses an account with no live session
/// (but a real `seven_day` lane) into a 0% 5-hour `primary` with no reset signal; the combined metric
/// must drop that placeholder so the readout falls back to the weekly lane instead of rendering a
/// non-existent `5h 0%`/`5h 100%` session. A genuine, freshly reset session (which still carries a
/// `resetsAt`) must survive the filter.
@MainActor
@Suite(.serialized)
struct StatusItemCombinedMetricPlaceholderTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        // Use the real system status bar in tests. Standalone NSStatusBar instances have caused
        // AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    /// Builds a Claude-only controller with the combined Session + Weekly metric selected.
    private func makeClaudeCombinedController(
        suiteName: String,
        displayMode: MenuBarDisplayMode,
        showUsed: Bool) -> (controller: StatusItemController, store: UsageStore)
    {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: suiteName),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = displayMode
        settings.usageBarsShowUsed = showUsed
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)

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
            statusBar: self.makeStatusBarForTesting())
        return (controller, store)
    }

    @Test
    func `combined metric ignores the claude web null-session placeholder in percent mode`() {
        let (controller, store) = self.makeClaudeCombinedController(
            suiteName: "StatusItemCombinedMetricPlaceholderTests-percent",
            displayMode: .percent,
            showUsed: true)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        // `primary` is the synthetic placeholder Claude web emits for `five_hour: null`: a 0% 5h window
        // flagged `isSyntheticPlaceholder`. `secondary` is the real weekly lane.
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Weekly lane only — the placeholder session is dropped (no "5h" component).
        #expect(displayText == "W 42%")
        #expect(displayText?.contains("5h") == false)
    }

    @Test
    func `combined metric ignores the claude web null-session placeholder in both mode`() {
        let (controller, store) = self.makeClaudeCombinedController(
            suiteName: "StatusItemCombinedMetricPlaceholderTests-both",
            displayMode: .both,
            showUsed: false)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Percent comes from the weekly lane (58% remaining), not the placeholder session's 100%.
        #expect(displayText?.hasPrefix("58%") == true)
        #expect(displayText?.hasPrefix("100%") == false)
        // The placeholder session lane never surfaces, so no "5h" label appears.
        #expect(displayText?.contains("5h") == false)
    }

    @Test
    func `combined metric keeps a real freshly reset claude session lane`() {
        let (controller, store) = self.makeClaudeCombinedController(
            suiteName: "StatusItemCombinedMetricPlaceholderTests-fresh",
            displayMode: .percent,
            showUsed: true)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        // A real, freshly reset session: 0% used but with a concrete reset time — unlike the placeholder.
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // The real session lane survives the filter, so both lanes render.
        #expect(displayText == "5h 0% · W 42%")
    }

    @Test
    func `combined metric keeps an unflagged zero-usage session sharing the placeholder shape`() {
        // Precision guard: a real empty session can share the placeholder's exact RateWindow shape
        // (0% used, 5h cadence, no reset) — e.g. the Claude CLI scrape, where session reset text can be
        // absent. Because the drop keys on the explicit `isSyntheticPlaceholder` marker (set only at the
        // Claude web boundary) rather than the shape, this unflagged session must be kept, not dropped.
        let (controller, store) = self.makeClaudeCombinedController(
            suiteName: "StatusItemCombinedMetricPlaceholderTests-unflagged-shape",
            displayMode: .percent,
            showUsed: true)
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 0, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 42,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Unflagged session is real, so it renders despite matching the placeholder shape.
        #expect(displayText == "5h 0% · W 42%")
    }
}
