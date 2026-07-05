import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
// swiftlint:disable:next type_body_length
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
        // Use the real system status bar in tests. Creating standalone NSStatusBar instances
        // has caused AppKit teardown crashes under swiftpm-testing-helper.
        .system
    }

    @Test
    func `known unavailable limits stop loading animation`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-known-unavailable"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false

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
        defer { controller.releaseStatusItemsForTesting() }

        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)
        #expect(controller.shouldAnimate(provider: .claude))

        store._setKnownLimitsAvailabilityForTesting(.unavailable, provider: .claude)
        #expect(!controller.shouldAnimate(provider: .claude))
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
        defer { controller.releaseStatusItemsForTesting() }

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
        defer { controller.releaseStatusItemsForTesting() }

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
        defer { controller.releaseStatusItemsForTesting() }

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
        defer { controller.releaseStatusItemsForTesting() }

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
    func `open router without key limit uses meter icon when brand percent is disabled`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-openrouter-no-limit-meter"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        if let openRouterMeta = registry.metadata[.openrouter] {
            settings.setProviderEnabled(provider: .openrouter, metadata: openRouterMeta, enabled: true)
        }
        settings.openRouterAPIToken = "or-token"

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45,
            balance: 5,
            usedPercent: 90,
            keyDataFetched: true,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .openrouter)
        store._setErrorForTesting(nil, provider: .openrouter)

        controller.applyIcon(for: .openrouter, phase: nil)

        guard let image = controller.statusItems[.openrouter]?.button?.image else {
            #expect(Bool(false))
            return
        }

        #expect(image.size.width == 18)
        #expect(image.size.height == 18)
        #expect(snapshot.openRouterUsage?.keyQuotaStatus == .noLimitConfigured)
        #expect(controller.statusItems[.openrouter]?.button?.title.isEmpty == true)
        #expect(MenuBarDisplayText.percentText(window: snapshot.primary, showUsed: false) == nil)

        // With no key limit, the primary bar has no fill — just the dim track.
        // A brand logo would be fully opaque here; the track is not.
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        if let rep {
            let alpha = (rep.colorAt(x: 8, y: 25) ?? .clear).alphaComponent
            #expect(alpha < 0.5)
        }
    }

    @Test
    func `open router key data not fetched still uses meter icon when brand percent is disabled`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-openrouter-no-fetch-meter"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        if let openRouterMeta = registry.metadata[.openrouter] {
            settings.setProviderEnabled(provider: .openrouter, metadata: openRouterMeta, enabled: true)
        }
        settings.openRouterAPIToken = "or-token"

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = OpenRouterUsageSnapshot(
            totalCredits: 50,
            totalUsage: 45,
            balance: 5,
            usedPercent: 90,
            keyDataFetched: false,
            keyLimit: nil,
            keyUsage: nil,
            rateLimit: nil,
            updatedAt: Date()).toUsageSnapshot()

        store._setSnapshotForTesting(snapshot, provider: .openrouter)
        store._setErrorForTesting(nil, provider: .openrouter)

        controller.applyIcon(for: .openrouter, phase: nil)

        guard let image = controller.statusItems[.openrouter]?.button?.image else {
            #expect(Bool(false))
            return
        }

        #expect(image.size.width == 18)
        #expect(image.size.height == 18)
        #expect(snapshot.openRouterUsage?.keyQuotaStatus == .unavailable)

        // Even with no key data, OpenRouter still renders a meter rather than the brand logo.
        // A brand logo would be fully opaque here; the unfilled track is not.
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        if let rep {
            let alpha = (rep.colorAt(x: 8, y: 25) ?? .clear).alphaComponent
            #expect(alpha < 0.5)
        }
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
        defer { controller.releaseStatusItemsForTesting() }

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
    func `combined codex menu bar metric window uses most constrained visible lane`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-codex-combined-window"),
            zaiTokenStore: NoopZaiTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

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
        defer { controller.releaseStatusItemsForTesting() }

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 12, windowMinutes: 300, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 91, windowMinutes: 7 * 24 * 60, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())

        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let window = controller.menuBarMetricWindow(for: .codex, snapshot: snapshot)

        #expect(window?.usedPercent == 91)
        #expect(window?.windowMinutes == 7 * 24 * 60)
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
        defer { controller.releaseStatusItemsForTesting() }

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
    func `menu bar display text formats codex combined percent lanes`() {
        let sessionWindow = RateWindow(usedPercent: 7, windowMinutes: 300, resetsAt: nil, resetDescription: nil)
        let weeklyWindow = RateWindow(usedPercent: 18, windowMinutes: 10080, resetsAt: nil, resetDescription: nil)

        let remaining = MenuBarDisplayText.combinedSessionWeeklyPercentText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            showUsed: false)
        let used = MenuBarDisplayText.combinedSessionWeeklyPercentText(
            sessionWindow: sessionWindow,
            weeklyWindow: weeklyWindow,
            showUsed: true)
        let weeklyOnly = MenuBarDisplayText.combinedSessionWeeklyPercentText(
            sessionWindow: nil,
            weeklyWindow: weeklyWindow,
            showUsed: false)
        let nineHour = MenuBarDisplayText.combinedSessionWeeklyPercentText(
            sessionWindow: RateWindow(
                usedPercent: 7,
                windowMinutes: 540,
                resetsAt: nil,
                resetDescription: nil),
            weeklyWindow: weeklyWindow,
            showUsed: false)
        let unknownSessionDuration = MenuBarDisplayText.combinedSessionWeeklyPercentText(
            sessionWindow: RateWindow(
                usedPercent: 7,
                windowMinutes: nil,
                resetsAt: nil,
                resetDescription: nil),
            weeklyWindow: weeklyWindow,
            showUsed: false)

        #expect(remaining == "5h 93% · W 82%")
        #expect(used == "5h 7% · W 18%")
        #expect(weeklyOnly == "W 82%")
        #expect(nineHour == "9h 93% · W 82%")
        #expect(unknownSessionDuration == "S 93% · W 82%")
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

        #expect(pace == "40%")
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

        #expect(pace == "40%")
        #expect(both == "40%")
    }

    @Test
    func `claude primary menu bar metric computes pace from selected session window`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-primary-pace"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = false
        settings.setMenuBarMetricPreference(.primary, for: .claude)

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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 20,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        #expect(displayText == "20% · +60%")
    }

    @Test
    func `claude combined menu bar metric shows session and weekly lanes`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .claude)
        #expect(settings.menuBarMetricPreference(for: .claude) == .primaryAndSecondary)

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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 45,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(24 * 60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        #expect(displayText == "5h 12% · W 45%")
    }

    @Test
    func `claude combined menu bar metric shows weekly only when session lane is absent`() {
        // Mirrors the Claude OAuth path where `five_hour` is missing: the mapper parks the 7-day
        // window in BOTH `primary` and `secondary`. The combined metric must not relabel the
        // weekly window as a session lane (e.g. "168h 42% · W 42%") — it should show weekly only.
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined-no-session"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = true
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let weekly = RateWindow(
            usedPercent: 42,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(24 * 60 * 60),
            resetDescription: nil)
        let snapshot = UsageSnapshot(primary: weekly, secondary: weekly, updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        #expect(displayText == "W 42%")
    }

    @Test
    func `claude combined menu bar metric paces the weekly lane in both mode`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined-pace"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = false
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        // Session lane is fully consumed, so its own pace is nil; the weekly lane still has room.
        // The combined metric must pace the weekly lane, so a pace component must appear even though
        // the displayed percent comes from the session lane (here fully consumed).
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 50,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // "0% · ±N%": percent from the session lane (here exhausted), pace from the weekly lane.
        #expect(displayText?.hasPrefix("0% · ") == true)
    }

    @Test
    func `claude combined menu bar metric pairs session usage with weekly pace`() {
        // Regression: in pace/both modes the combined metric must pair the SESSION usage with the
        // WEEKLY pace. Previously the usage component came from the most-constrained lane, so when the
        // weekly lane was busier than the session lane it showed weekly usage + weekly pace.
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined-session-pace"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        // Weekly lane (45%) is busier than the session lane (12%). The usage component must still be the
        // session lane, while the pace is computed on the weekly lane (mostly elapsed → pace present).
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 45,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Usage is the session lane (12% used), not the most-constrained weekly lane (45%).
        #expect(displayText?.hasPrefix("12% · ") == true)
        #expect(displayText?.hasPrefix("45%") == false)
    }

    @Test
    func `codex combined menu bar metric pairs session usage with weekly pace`() {
        // The combined metric is shared with Codex, which resolves its lanes through the consumer
        // projection. The session usage must headline the pace/both readout there too — not the busier
        // weekly lane that drives the icon/bar.
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-codex-combined-session-pace"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true
        settings.setMenuBarMetricPreference(.primaryAndSecondary, for: .codex)

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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        // Weekly lane (91%) is busier than the session lane (12%), but neither is exhausted. The usage
        // component must be the session lane while the pace is computed on the weekly lane.
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 91,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText?.hasPrefix("12% · ") == true)
        #expect(displayText?.hasPrefix("91%") == false)
    }

    @Test
    func `claude combined menu bar metric surfaces an exhausted weekly lane in both mode`() {
        // When the weekly lane is exhausted it is the binding cap and has no pace, so the combined metric
        // must surface it instead of a roomy session number that would hide the spent weekly limit.
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined-weekly-exhausted"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = false
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        // Session lane has room (88% remaining); weekly lane is fully consumed (0% remaining).
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 12,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: RateWindow(
                usedPercent: 100,
                windowMinutes: 7 * 24 * 60,
                resetsAt: now.addingTimeInterval(60 * 60),
                resetDescription: nil),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Shows the exhausted weekly lane (0% remaining), not the roomy session lane (88%).
        #expect(displayText == "0%")
        #expect(displayText?.hasPrefix("88%") == false)
    }

    @Test
    func `claude combined menu bar metric falls back to weekly lane in both mode when session absent`() {
        // Five_hour OAuth fallback: the mapper parks the 7-day window in both primary and secondary, so no
        // session lane exists. The pace/both usage component must land on the weekly lane, not collapse to
        // nil.
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined-no-session-both"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .both
        settings.usageBarsShowUsed = true
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let weekly = RateWindow(
            usedPercent: 42,
            windowMinutes: 7 * 24 * 60,
            resetsAt: now.addingTimeInterval(60 * 60),
            resetDescription: nil)
        let snapshot = UsageSnapshot(primary: weekly, secondary: weekly, updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Usage lands on the weekly lane (42% used) rather than collapsing to nil.
        #expect(displayText?.hasPrefix("42%") == true)
    }

    @Test
    func `claude combined menu bar metric shows spend limit for a spend-limit-only account`() {
        // A Claude account that only exposes an enterprise/extra-usage spend limit has no real
        // session/weekly lanes (here a 0% 5h placeholder + a spend limit). With Session + Weekly selected,
        // it must surface the spend-limit usage, not the meaningless "5h 0%" placeholder lane.
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-claude-combined-spend-limit"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .claude
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = true
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 0,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil,
                isSyntheticPlaceholder: true),
            secondary: nil,
            providerCost: ProviderCostSnapshot(
                used: 45,
                limit: 100,
                currencyCode: "USD",
                period: "Spend limit",
                updatedAt: now),
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)

        let displayText = controller.menuBarDisplayText(for: .claude, snapshot: snapshot)

        // Spend-limit usage (45% of the cap), not the "5h 0%" placeholder lane.
        #expect(displayText == "45%")
        #expect(displayText?.contains("5h") == false)
    }

    @Test
    func `codex menu bar pace does not fall back to session when weekly projection is unavailable`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-codex-no-weekly-pace"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarDisplayMode = .both
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
        defer { controller.releaseStatusItemsForTesting() }

        let now = Date()
        let snapshot = UsageSnapshot(
            primary: RateWindow(
                usedPercent: 80,
                windowMinutes: 300,
                resetsAt: now.addingTimeInterval(4 * 60 * 60),
                resetDescription: nil),
            secondary: nil,
            updatedAt: now)
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setErrorForTesting(nil, provider: .codex)

        let displayText = controller.menuBarDisplayText(for: .codex, snapshot: snapshot)

        #expect(displayText == "20%")
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
