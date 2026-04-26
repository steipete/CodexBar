import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemAnimationTests {
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
    func `merged icon loading animation tracks selected provider only`() {
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
        if let openRouterMeta = registry.metadata[.openrouter] {
            settings.setProviderEnabled(provider: .openrouter, metadata: openRouterMeta, enabled: true)
        }
        settings.openRouterAPIToken = "or-token"
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
    func `merged icon loading animation does not flip layout when weekly hits zero`() {
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
        if let openRouterMeta = registry.metadata[.openrouter] {
            settings.setProviderEnabled(provider: .openrouter, metadata: openRouterMeta, enabled: true)
        }
        settings.openRouterAPIToken = "or-token"

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
    func `warp no bonus layout is preserved in show used mode when bonus is exhausted`() {
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
    func `warp bonus lane is preserved in show used mode when bonus is unused`() {
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
    func `menu bar percent uses configured metric`() {
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
    func `menu bar percent automatic prefers rate limit for kimi`() {
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
    func `menu bar percent uses average for gemini`() {
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
    func `menu bar percent automatic keeps gemini primary over higher tertiary`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-gemini-automatic-primary"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .gemini
        settings.setMenuBarMetricPreference(.automatic, for: .gemini)

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
            secondary: RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 95, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .gemini)
        store._setErrorForTesting(nil, provider: .gemini)

        let window = controller.menuBarMetricWindow(for: .gemini, snapshot: snapshot)

        #expect(window?.usedPercent == 20)
    }

    @Test
    func `menu bar percent automatic picks highest cursor lane including api`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-cursor-automatic-tertiary"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .cursor
        settings.setMenuBarMetricPreference(.automatic, for: .cursor)

        let registry = ProviderRegistry.shared
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
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
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 90, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let window = controller.menuBarMetricWindow(for: .cursor, snapshot: snapshot)

        #expect(window?.usedPercent == 90)
    }

    @Test
    func `menu bar percent automatic falls back to purchased perplexity lane when bonus is exhausted`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-perplexity-automatic-purchased"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .perplexity
        settings.setMenuBarMetricPreference(.automatic, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
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
            primary: nil,
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .perplexity)
        store._setErrorForTesting(nil, provider: .perplexity)

        let window = controller.menuBarMetricWindow(for: .perplexity, snapshot: snapshot)

        #expect(window?.usedPercent == 20)
    }

    @Test
    func `menu bar percent automatic falls through after recurring perplexity credits are exhausted`() {
        let settings = SettingsStore(
            configStore: testConfigStore(
                suiteName: "StatusItemAnimationTests-perplexity-automatic-recurring-exhausted"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .perplexity
        settings.setMenuBarMetricPreference(.automatic, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
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
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 32, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .perplexity)
        store._setErrorForTesting(nil, provider: .perplexity)

        let window = controller.menuBarMetricWindow(for: .perplexity, snapshot: snapshot)

        #expect(window?.usedPercent == 32)
    }

    @Test
    func `menu bar percent automatic prefers purchased perplexity credits before bonus`() {
        let settings = SettingsStore(
            configStore: testConfigStore(
                suiteName: "StatusItemAnimationTests-perplexity-automatic-purchased-before-bonus"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .perplexity
        settings.setMenuBarMetricPreference(.automatic, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
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
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 45, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .perplexity)
        store._setErrorForTesting(nil, provider: .perplexity)

        let window = controller.menuBarMetricWindow(for: .perplexity, snapshot: snapshot)

        #expect(window?.usedPercent == 45)
    }

    @Test
    func `menu bar percent primary preference stays on recurring perplexity credits`() {
        let settings = SettingsStore(
            configStore: testConfigStore(
                suiteName: "StatusItemAnimationTests-perplexity-primary-recurring-exhausted"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .perplexity
        settings.setMenuBarMetricPreference(.primary, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
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
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 32, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .perplexity)
        store._setErrorForTesting(nil, provider: .perplexity)

        let window = controller.menuBarMetricWindow(for: .perplexity, snapshot: snapshot)

        #expect(window?.usedPercent == 100)
    }

    @Test
    func `menu bar percent tertiary preference uses purchased perplexity lane`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-perplexity-tertiary-pref"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .perplexity
        settings.setMenuBarMetricPreference(.tertiary, for: .perplexity)

        let registry = ProviderRegistry.shared
        if let perplexityMeta = registry.metadata[.perplexity] {
            settings.setProviderEnabled(provider: .perplexity, metadata: perplexityMeta, enabled: true)
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
            primary: nil,
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 28, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .perplexity)
        store._setErrorForTesting(nil, provider: .perplexity)

        let window = controller.menuBarMetricWindow(for: .perplexity, snapshot: snapshot)

        #expect(window?.usedPercent == 28)
    }

    @Test
    func `menu bar percent tertiary preference uses api lane for cursor`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-cursor-tertiary-pref"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .cursor
        settings.setMenuBarMetricPreference(.tertiary, for: .cursor)

        let registry = ProviderRegistry.shared
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
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
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: RateWindow(usedPercent: 72, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let window = controller.menuBarMetricWindow(for: .cursor, snapshot: snapshot)

        #expect(window?.usedPercent == 72)
    }

    @Test
    func `menu bar tertiary preference falls back to automatic when cursor api lane is missing`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-cursor-tertiary-missing-api"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .cursor
        settings.setMenuBarMetricPreference(.tertiary, for: .cursor)

        let registry = ProviderRegistry.shared
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
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
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 72, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            tertiary: nil,
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .cursor)
        store._setErrorForTesting(nil, provider: .cursor)

        let window = controller.menuBarMetricWindow(for: .cursor, snapshot: snapshot)

        #expect(window?.usedPercent == 72)
    }

    @Test
    func `menu bar display text formats percent and pace`() {
        let now = Date(timeIntervalSince1970: 0)
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)
        let paceWindow = RateWindow(
            usedPercent: 30,
            windowMinutes: 10080,
            resetsAt: now.addingTimeInterval(60 * 60 * 24 * 6),
            resetDescription: nil)
        let paceValue = UsagePace.weekly(window: paceWindow, now: now, defaultWindowMinutes: 10080)

        let percent = MenuBarDisplayText.displayText(
            mode: .percent,
            percentWindow: percentWindow,
            pace: paceValue,
            showUsed: true)
        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: percentWindow,
            pace: paceValue,
            showUsed: true)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: percentWindow,
            pace: paceValue,
            showUsed: true)

        #expect(percent == "40%")
        #expect(pace == "+16%")
        #expect(both == "40% · +16%")
    }

    @Test
    func `menu bar display text falls back to percent when pace unavailable`() {
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: percentWindow,
            showUsed: true)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: percentWindow,
            showUsed: true)

        #expect(pace == nil)
        // "Both" mode falls back to percent-only when pace is unavailable
        #expect(both == "40%")
    }

    @Test
    func `menu bar display text falls back to percent when pace nil for codex`() {
        let percentWindow = RateWindow(usedPercent: 40, windowMinutes: nil, resetsAt: nil, resetDescription: nil)

        let pace = MenuBarDisplayText.displayText(
            mode: .pace,
            percentWindow: percentWindow,
            pace: nil,
            showUsed: true)
        let both = MenuBarDisplayText.displayText(
            mode: .both,
            percentWindow: percentWindow,
            pace: nil,
            showUsed: true)

        #expect(pace == nil)
        // "Both" mode falls back to percent-only when pace is unavailable
        #expect(both == "40%")
    }

    @Test
    func `menu bar display text uses credits when codex weekly is exhausted`() {
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
    func `menu bar display text uses credits when codex session is exhausted`() {
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
    func `menu bar display text shows zero percent for kilo zero total edge`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-kilo-zero-edge"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .kilo
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primary, for: .kilo)

        let registry = ProviderRegistry.shared
        if let kiloMeta = registry.metadata[.kilo] {
            settings.setProviderEnabled(provider: .kilo, metadata: kiloMeta, enabled: true)
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

        let snapshot = KiloUsageSnapshot(
            creditsUsed: 0,
            creditsTotal: 0,
            creditsRemaining: 0,
            planName: "Kilo Pass Pro",
            autoTopUpEnabled: true,
            autoTopUpMethod: "visa",
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .kilo)
        store._setErrorForTesting(nil, provider: .kilo)

        let displayText = controller.menuBarDisplayText(for: .kilo, snapshot: snapshot)

        #expect(displayText == "0%")
    }

    @Test
    func `brand image with status overlay returns original image when no issue`() {
        let brand = NSImage(size: NSSize(width: 16, height: 16))
        brand.isTemplate = true

        let output = StatusItemController.brandImageWithStatusOverlay(brand: brand, statusIndicator: .none)

        #expect(output === brand)
    }

    @Test
    func `brand image with status overlay draws issue mark`() throws {
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
