import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite
struct StatusItemAnimationTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    @Test
    func mergedIconLoadingAnimationTracksSelectedProviderOnly() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-merged"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: false)
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

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        #expect(controller.needsMenuBarIconAnimation() == false)
    }

    @Test
    func mergedIconLoadingAnimationDoesNotFlipLayoutWhenWeeklyHitsZero() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-weekly"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)

        // Seed with data so init doesn't start the animation driver.
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        // Enter loading state: no data, no stale error.
        store._setSnapshotForTesting(nil, provider: .codex)
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .codex)
        store._setErrorForTesting(nil, provider: .claude)

        controller.animationPattern = .knightRider
        #expect(controller.needsMenuBarIconAnimation() == true)

        // At phase = π/2, the secondary bar hits 0 (weeklyRemaining == 0) due to a π offset.
        // Regression: this used to flip IconRenderer into the "weekly exhausted" layout and cause toolbar flicker.
        controller.applyIcon(phase: .pi / 2)

        guard let image = controller.statusItem.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        let alpha = (rep.colorAt(x: 18, y: 12) ?? .clear).alphaComponent
        #expect(alpha > 0.05)
    }

    @Test
    func menuBarPercentUsesConfiguredMetric() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-metric"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.setMenuBarMetricPreference(.secondary, for: .codex)

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
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

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 42, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let window = controller.menuBarMetricWindow(for: .codex, snapshot: snapshot)

        #expect(window?.usedPercent == 42)
    }

    @Test
    func menuBarPercentUsesAverageForGemini() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-average"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .gemini
        settings.setMenuBarMetricPreference(.average, for: .gemini)

        let registry = ProviderRegistry.shared
        if let geminiMeta = registry.metadata[.gemini] {
            settings.setProviderEnabled(provider: .gemini, metadata: geminiMeta, enabled: true)
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

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 60, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .gemini)
        store._setErrorForTesting(nil, provider: .gemini)

        let window = controller.menuBarMetricWindow(for: .gemini, snapshot: snapshot)

        #expect(window?.usedPercent == 40)
    }

    @Test
    func menuBarDisplayTextFormatsPercentAndPace() {
        let now = Date(timeIntervalSince1970: 0)
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let paceWindow = RateWindow(
            usedPercent: 30,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(60 * 60 * 24 * 6),
            resetDescription: nil)

        let percent = MenuBarDisplayText.displayText(
            mode: .percent,
            provider: .codex,
            percentWindow: percentWindow,
            paceWindow: paceWindow,
            showUsed: true,
            now: now)
        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            provider: .codex,
            percentWindow: percentWindow,
            paceWindow: paceWindow,
            showUsed: true,
            now: now)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            provider: .codex,
            percentWindow: percentWindow,
            paceWindow: paceWindow,
            showUsed: true,
            now: now)

        #expect(percent == "40%")
        #expect(pace == "+16%")
        #expect(both == "40% · +16%")
    }

    @Test
    func menuBarDisplayTextHidesWhenPaceUnavailable() {
        let now = Date(timeIntervalSince1970: 0)
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let paceWindow = RateWindow(
            usedPercent: 30,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(60 * 60 * 24 * 6),
            resetDescription: nil)

        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            provider: .gemini,
            percentWindow: percentWindow,
            paceWindow: paceWindow,
            showUsed: true,
            now: now)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            provider: .gemini,
            percentWindow: percentWindow,
            paceWindow: paceWindow,
            showUsed: true,
            now: now)

        #expect(pace == nil)
        #expect(both == nil)
    }
}
