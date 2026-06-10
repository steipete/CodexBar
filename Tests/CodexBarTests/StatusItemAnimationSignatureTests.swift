import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
struct StatusItemAnimationSignatureTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    @Test
    func `merged render signature changes when unified icon style changes`() throws {
        let suite = "StatusItemAnimationSignatureTests-merged-style-signature"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false
        settings.syntheticAPIToken = "synthetic-test-token"

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let syntheticMeta = registry.metadata[.synthetic] {
            settings.setProviderEnabled(provider: .synthetic, metadata: syntheticMeta, enabled: true)
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

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(store.enabledProvidersForDisplay() == [.codex, .synthetic])
        #expect(store.enabledProviders() == [.codex, .synthetic])
        #expect(store.iconStyle == .combined)
        controller.applyIcon(phase: nil)
        let combinedSignature = controller.lastAppliedMergedIconRenderSignature

        if let syntheticMeta = registry.metadata[.synthetic] {
            settings.setProviderEnabled(provider: .synthetic, metadata: syntheticMeta, enabled: false)
        }

        #expect(store.enabledProvidersForDisplay() == [.codex])
        #expect(store.enabledProviders() == [.codex])
        #expect(store.iconStyle == .codex)
        controller.applyIcon(phase: nil)
        let codexSignature = controller.lastAppliedMergedIconRenderSignature

        #expect(combinedSignature != nil)
        #expect(codexSignature != nil)
        #expect(combinedSignature != codexSignature)
        #expect(codexSignature?.contains("style=codex") == true)
    }

    @Test
    func `merged brand percent reapplies title when cached render is skipped`() throws {
        let suite = "StatusItemAnimationSignatureTests-merged-brand-percent-title-restore"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarDisplayMode = .percent
        settings.usageBarsShowUsed = false
        settings.syntheticAPIToken = "synthetic-test-token"

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let syntheticMeta = registry.metadata[.synthetic] {
            settings.setProviderEnabled(provider: .synthetic, metadata: syntheticMeta, enabled: true)
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
            primary: RateWindow(usedPercent: 23, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)

        let displayText = try #require(controller.menuBarDisplayText(for: .codex, snapshot: snapshot))
        let expectedTitle = StatusItemController.buttonTitle(displayText, hasImage: true)
        controller.applyIcon(phase: nil)
        let button = try #require(controller.statusItem.button)
        #expect(button.title == expectedTitle)
        #expect(button.imagePosition == .imageLeft)

        button.title = ""
        button.imagePosition = .imageOnly

        let skipped = controller.applyIcon(phase: nil)

        #expect(skipped)
        #expect(button.title == expectedTitle)
        #expect(button.imagePosition == .imageLeft)
    }

    @Test
    func `merged icon render defers while merged menu is tracking`() async throws {
        let suite = "StatusItemAnimationSignatureTests-merged-icon-defers-during-tracking"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.menuBarShowsBrandIconWithPercent = false
        settings.syntheticAPIToken = "synthetic-test-token"

        let registry = ProviderRegistry.shared
        for provider in UsageProvider.allCases {
            guard let metadata = registry.metadata[provider] else { continue }
            settings.setProviderEnabled(
                provider: provider,
                metadata: metadata,
                enabled: provider == .codex || provider == .synthetic)
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
        controller.menuRefreshEnabledOverrideForTesting = true

        func snapshot(usedPercent: Double) -> UsageSnapshot {
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: usedPercent,
                    windowMinutes: nil,
                    resetsAt: nil,
                    resetDescription: nil),
                secondary: nil,
                updatedAt: Date())
        }

        store._setSnapshotForTesting(snapshot(usedPercent: 20), provider: .codex)
        for _ in 0..<10 where controller.animationDriver != nil {
            await Task.yield()
        }
        #expect(controller.animationDriver == nil)
        controller.applyIcon(phase: nil)
        let initialSignature = try #require(controller.lastAppliedMergedIconRenderSignature)

        let menu = controller.makeMenu()
        controller.mergedMenu = menu
        controller.statusItem.menu = menu
        controller.menuWillOpen(menu)
        #expect(controller.isMergedMenuOpen)

        store._setSnapshotForTesting(nil, provider: .codex)
        for _ in 0..<10 where controller.animationDriver == nil {
            await Task.yield()
        }
        #expect(controller.animationDriver != nil)
        #expect(controller.deferredMergedIconRenderAfterTracking)

        store._setSnapshotForTesting(snapshot(usedPercent: 80), provider: .codex)
        for _ in 0..<10 where controller.animationDriver != nil {
            await Task.yield()
        }
        #expect(controller.animationDriver == nil)
        #expect(controller.deferredMergedIconRenderAfterTracking)
        #expect(controller.lastAppliedMergedIconRenderSignature == initialSignature)

        controller.startQuotaWarningFlash(provider: .codex)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("warningFlash=1") == true)

        let quotaWarningTask = controller.quotaWarningFlashTasks[.codex]
        controller.clearExpiredQuotaWarningFlash(provider: .codex, now: .distantFuture)
        quotaWarningTask?.cancel()
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("warningFlash=0") == true)

        controller.menuDidClose(menu)

        #expect(!controller.deferredMergedIconRenderAfterTracking)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("warningFlash=0") == true)

        controller.menuWillOpen(menu)
        settings.selectedMenuProvider = .synthetic
        #expect(controller.primaryProviderForUnifiedIcon() == .synthetic)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=codex") == true)

        controller.startQuotaWarningFlash(provider: .codex)
        let switchedProviderWarningTask = controller.quotaWarningFlashTasks[.codex]
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=synthetic") == true)
        controller.clearExpiredQuotaWarningFlash(provider: .codex, now: .distantFuture)
        switchedProviderWarningTask?.cancel()
        controller.menuDidClose(menu)

        settings.selectedMenuProvider = .codex
        for _ in 0..<10 where controller.primaryProviderForUnifiedIcon() != .codex {
            await Task.yield()
        }

        controller.menuWillOpen(menu)
        store._setSnapshotForTesting(nil, provider: .codex)
        controller.updateAnimationState()
        controller.applyIcon(phase: controller.animationPhase)
        #expect(controller.animationDriver != nil)
        #expect(controller.deferredMergedIconRenderAfterTracking)

        controller.animationDriver?.stop()
        controller.animationDriver = nil
        controller.animationPhase = 0
        controller.menuDidClose(menu)

        #expect(controller.animationDriver == nil)
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("primary=nil") == true)
    }

    @Test
    func `merged fallback provider follows enabled provider order`() throws {
        let suite = "StatusItemAnimationSignatureTests-merged-provider-order"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsBrandIconWithPercent = false
        settings.syntheticAPIToken = "synthetic-test-token"
        settings.setProviderOrder([.synthetic, .codex])

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let syntheticMeta = registry.metadata[.synthetic] {
            settings.setProviderEnabled(provider: .synthetic, metadata: syntheticMeta, enabled: true)
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
        store._setSnapshotForTesting(snapshot, provider: .synthetic)

        controller.applyIcon(phase: nil)

        #expect(store.enabledProviders().prefix(2) == [.synthetic, .codex])
        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=synthetic") == true)
    }

    @Test
    func `merged icon follows overview provider order when first overview provider is loading`() {
        let suite = "StatusItemAnimationSignatureTests-merged-overview-provider-order"
        let defaults = UserDefaults(suiteName: suite)
        defaults?.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults ?? .standard,
            configStore: testConfigStore(suiteName: "StatusItemAnimationSignatureTests-merged-overview-provider-order"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.mergedMenuLastSelectedWasOverview = true
        settings.menuBarShowsBrandIconWithPercent = false
        settings.setProviderOrder([.cursor, .codex, .claude])

        let registry = ProviderRegistry.shared
        if let cursorMeta = registry.metadata[.cursor] {
            settings.setProviderEnabled(provider: .cursor, metadata: cursorMeta, enabled: true)
        }
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
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

        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        store._setSnapshotForTesting(snapshot, provider: .claude)

        #expect(store.enabledProvidersForDisplay().prefix(3) == [.cursor, .codex, .claude])
        #expect(settings.resolvedMergedOverviewProviders(activeProviders: store.enabledProvidersForDisplay()) == [
            .cursor,
            .codex,
            .claude,
        ])

        controller.applyIcon(phase: nil)

        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("provider=cursor") == true)
    }

    @Test
    func `split provider icon skips unchanged render signature`() throws {
        let suite = "StatusItemAnimationSignatureTests-split-provider-signature"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: testConfigStore(suiteName: suite),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false

        if let codexMeta = ProviderRegistry.shared.metadata[.codex] {
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

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 25, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(controller.applyIcon(for: .codex, phase: nil) == false)
        #expect(controller.applyIcon(for: .codex, phase: nil) == true)

        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
                secondary: nil,
                updatedAt: Date()),
            provider: .codex)

        #expect(controller.applyIcon(for: .codex, phase: nil) == false)
    }
}
