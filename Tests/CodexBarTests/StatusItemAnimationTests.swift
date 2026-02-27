import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite
struct StatusItemAnimationTests {
    private let outerRingSamplePoints: [(Int, Int)] = [
        (16, 31), (17, 31), (18, 31), (19, 31), (20, 31),
        (16, 32), (17, 32), (18, 32), (19, 32), (20, 32),
    ]

    private func alphaAt(_ x: Int, _ y: Int, in rep: NSBitmapImageRep) -> CGFloat {
        (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
    }

    private func averageAlpha(in rep: NSBitmapImageRep, points: [(Int, Int)]) -> CGFloat {
        guard !points.isEmpty else { return 0 }
        let total = points.reduce(CGFloat(0)) { partial, point in
            partial + self.alphaAt(point.0, point.1, in: rep)
        }
        return total / CGFloat(points.count)
    }

    private func maxAlpha(in rep: NSBitmapImageRep) -> CGFloat {
        var maxAlpha: CGFloat = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                let alpha = (rep.colorAt(x: x, y: y) ?? .clear).alphaComponent
                if alpha > maxAlpha {
                    maxAlpha = alpha
                }
            }
        }
        return maxAlpha
    }

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
        settings.codexMenuBarVisualizationMode = .classic
        settings.codexMenuBarVisualizationMode = .classic

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
    func warpNoBonusLayoutIsPreservedInShowUsedModeWhenBonusIsExhausted() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-warp-no-bonus-used"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let warpMeta = registry.metadata[.warp] {
            settings.setProviderEnabled(provider: .warp, metadata: warpMeta, enabled: true)
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

        // Primary used=10%. Bonus exhausted: used=100% (remaining=0%).
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .warp)
        store._setErrorForTesting(nil, provider: .warp)

        controller.applyIcon(for: .warp, phase: nil)

        guard let image = controller.statusItems[.warp]?.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        // In the Warp "no bonus/exhausted bonus" layout, the bottom bar is a dimmed track.
        // A pixel near the right side of the bottom bar should remain subdued (not fully opaque).
        let alpha = (rep.colorAt(x: 25, y: 9) ?? .clear).alphaComponent
        #expect(alpha < 0.6)
    }

    @Test
    func warpBonusLaneIsPreservedInShowUsedModeWhenBonusIsUnused() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-warp-unused-bonus-used"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let warpMeta = registry.metadata[.warp] {
            settings.setProviderEnabled(provider: .warp, metadata: warpMeta, enabled: true)
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

        // Bonus exists but is unused: used=0% (remaining=100%).
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .warp)
        store._setErrorForTesting(nil, provider: .warp)

        controller.applyIcon(for: .warp, phase: nil)

        guard let image = controller.statusItems[.warp]?.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        // When we incorrectly treat "0 used" as "no bonus", the Warp branch makes the top bar full (100%).
        // A pixel near the right side of the top bar should remain in the track-only range for 10% usage.
        let alpha = (rep.colorAt(x: 31, y: 25) ?? .clear).alphaComponent
        #expect(alpha < 0.6)
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
    func menuBarPercentAutomaticPrefersRateLimitForKimi() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-kimi-automatic"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .kimi
        settings.setMenuBarMetricPreference(.automatic, for: .kimi)

        let registry = ProviderRegistry.shared
        if let kimiMeta = registry.metadata[.kimi] {
            settings.setProviderEnabled(provider: .kimi, metadata: kimiMeta, enabled: true)
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
            secondary: RateWindow(usedPercent: 42, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .kimi)
        store._setErrorForTesting(nil, provider: .kimi)

        let window = controller.menuBarMetricWindow(for: .kimi, snapshot: snapshot)

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

    @Test
    func menuBarDisplayTextUsesCreditsWhenCodexWeeklyIsExhausted() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-credits-fallback"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
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
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remainingCredits = (snapshot.primary?.usedPercent ?? 0) * 4.5 + (snapshot.secondary?.usedPercent ?? 0) / 10
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: remainingCredits, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)
        let expected = UsageFormatter
            .creditsString(from: remainingCredits)
            .replacingOccurrences(of: " left", with: "")

        #expect(displayText == expected)
    }

    @Test
    func menuBarDisplayTextUsesCreditsWhenCodexSessionIsExhausted() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-credits-fallback-session"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primary, for: .codex)

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
            primary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        let remainingCredits = (snapshot.primary?.usedPercent ?? 0) - (snapshot.secondary?.usedPercent ?? 0) / 2
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: remainingCredits, events: [], updatedAt: Date())

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)
        let expected = UsageFormatter
            .creditsString(from: remainingCredits)
            .replacingOccurrences(of: " left", with: "")

        #expect(displayText == expected)
    }

    @Test
    func codexPieRingModeSelectionHonorsProviderAndBrandMode() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-codex-pie-ring"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false
        settings.codexMenuBarVisualizationMode = .classic

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        #expect(controller.shouldUseCodexPieRingMenuBarIcon(provider: .codex, showBrandPercent: false) == false)
        settings.codexMenuBarVisualizationMode = .pieRing
        #expect(controller.shouldUseCodexPieRingMenuBarIcon(provider: .codex, showBrandPercent: false))
        settings.codexMenuBarVisualizationMode = .pieRingSwapped
        #expect(controller.shouldUseCodexPieRingMenuBarIcon(provider: .codex, showBrandPercent: false))
        #expect(controller.shouldUseCodexPieRingMenuBarIcon(provider: .claude, showBrandPercent: false) == false)
        #expect(controller.shouldUseCodexPieRingMenuBarIcon(provider: .codex, showBrandPercent: true) == false)
    }

    @Test
    func codexPieRingRespectsShowUsedPreference() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-codex-pie-ring-show-used"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false
        settings.codexMenuBarVisualizationMode = .pieRing
        settings.usageBarsShowUsed = true

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
            primary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 30, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        controller.applyIcon(for: .codex, phase: nil)
        let showUsedImage = controller.statusItems[.codex]?.button?.image

        settings.usageBarsShowUsed = false
        controller.applyIcon(for: .codex, phase: nil)
        let showRemainingImage = controller.statusItems[.codex]?.button?.image

        let expectedShowUsedImage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 30,
            sessionUsed: 20,
            mode: .pieRing,
            stale: false)
        let expectedShowRemainingImage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 70,
            sessionUsed: 80,
            mode: .pieRing,
            stale: false)

        #expect(showUsedImage?.tiffRepresentation != nil)
        #expect(showRemainingImage?.tiffRepresentation != nil)

        #expect(showUsedImage?.tiffRepresentation == expectedShowUsedImage.tiffRepresentation)
        #expect(showRemainingImage?.tiffRepresentation == expectedShowRemainingImage.tiffRepresentation)
    }

    @Test
    func codexPieRingIconRendersWeeklyPieAndSessionRingFills() {
        let partialUsage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 25,
            sessionUsed: 25,
            mode: .pieRing,
            stale: false)
        let fullUsage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 100,
            sessionUsed: 100,
            mode: .pieRing,
            stale: false)
        let zeroUsage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 0,
            sessionUsed: 0,
            mode: .pieRing,
            stale: false)
        let tinyUsage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 1,
            sessionUsed: 1,
            mode: .pieRing,
            stale: false)
        let swappedUsage = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 25,
            sessionUsed: 25,
            mode: .pieRingSwapped,
            stale: false)
        let invalidRingAvailableFlash = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 25,
            sessionUsed: nil,
            mode: .pieRing,
            invalidCharts: [.ring],
            flashInvalidChartsAsUsed: false,
            stale: false)
        let invalidRingUsedFlash = IconRenderer.makeCodexPieRingIcon(
            weeklyUsed: 25,
            sessionUsed: nil,
            mode: .pieRing,
            invalidCharts: [.ring],
            flashInvalidChartsAsUsed: true,
            stale: false)

        let partialRep = partialUsage.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        let fullRep = fullUsage.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        let zeroRep = zeroUsage.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        let tinyRep = tinyUsage.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        let swappedRep = swappedUsage.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        let invalidRingAvailableRep =
            invalidRingAvailableFlash.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
                $0.pixelsWide == 36 && $0.pixelsHigh == 36
            })
        let invalidRingUsedRep = invalidRingUsedFlash.representations.compactMap { $0 as? NSBitmapImageRep }
            .first(where: {
                $0.pixelsWide == 36 && $0.pixelsHigh == 36
            })

        #expect(partialRep != nil)
        #expect(fullRep != nil)
        #expect(zeroRep != nil)
        #expect(tinyRep != nil)
        #expect(swappedRep != nil)
        #expect(invalidRingAvailableRep != nil)
        #expect(invalidRingUsedRep != nil)

        if let zeroRep, let tinyRep, let fullRep {
            let zeroOuterAlpha = self.averageAlpha(in: zeroRep, points: self.outerRingSamplePoints)
            let tinyOuterAlpha = self.averageAlpha(in: tinyRep, points: self.outerRingSamplePoints)
            let fullOuterAlpha = self.averageAlpha(in: fullRep, points: self.outerRingSamplePoints)
            #expect(fullOuterAlpha > zeroOuterAlpha + 0.06)
            #expect(tinyOuterAlpha < zeroOuterAlpha + (fullOuterAlpha - zeroOuterAlpha) * 0.4)
        }
        if let invalidRingAvailableRep, let invalidRingUsedRep {
            let availableOuterAlpha = self.averageAlpha(in: invalidRingAvailableRep, points: self.outerRingSamplePoints)
            let usedOuterAlpha = self.averageAlpha(in: invalidRingUsedRep, points: self.outerRingSamplePoints)
            #expect(usedOuterAlpha > availableOuterAlpha + 0.06)
        }
    }

    @Test
    func brandImageWithStatusOverlayReturnsOriginalImageWhenNoIssue() {
        let brand = NSImage(size: NSSize(width: 16, height: 16))
        brand.isTemplate = true

        let output = StatusItemController.brandImageWithStatusOverlay(brand: brand, statusIndicator: .none)

        #expect(output === brand)
    }

    @Test
    func brandImageWithStatusOverlayDrawsIssueMark() throws {
        let size = NSSize(width: 16, height: 16)
        let brand = NSImage(size: size)
        brand.lockFocus()
        NSColor.clear.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        brand.unlockFocus()
        brand.isTemplate = true

        let baselineData = try #require(brand.tiffRepresentation)
        let baselineRep = try #require(NSBitmapImageRep(data: baselineData))
        let baselineAlpha = self.maxAlpha(in: baselineRep)

        let output = StatusItemController.brandImageWithStatusOverlay(brand: brand, statusIndicator: .major)

        #expect(output !== brand)
        let outputData = try #require(output.tiffRepresentation)
        let outputRep = try #require(NSBitmapImageRep(data: outputData))
        let outputAlpha = self.maxAlpha(in: outputRep)
        #expect(baselineAlpha < 0.01)
        #expect(outputAlpha > 0.01)
    }
}
