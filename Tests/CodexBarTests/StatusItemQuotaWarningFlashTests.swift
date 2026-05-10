import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemQuotaWarningFlashTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        NSStatusBar.system
    }

    @Test
    func `quota warning flash state lasts for configured duration`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemQuotaWarningFlashTests-duration"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        let now = Date()
        controller.startQuotaWarningFlash(provider: .codex, postedAt: now)

        #expect(controller.quotaWarningFlashActive(provider: .codex, now: now.addingTimeInterval(59)) == true)
        #expect(controller.quotaWarningFlashActive(provider: .codex, now: now.addingTimeInterval(61)) == false)
    }

    @Test
    func `quota warning flash image draws non template red overlay`() throws {
        let size = NSSize(width: 16, height: 16)
        let base = NSImage(size: size)
        base.lockFocus()
        NSColor.black.setFill()
        NSBezierPath(rect: NSRect(origin: .zero, size: size)).fill()
        base.unlockFocus()
        base.isTemplate = true

        let output = StatusItemController.quotaWarningFlashImage(base: base)
        let outputData = try #require(output.tiffRepresentation)
        let outputRep = try #require(NSBitmapImageRep(data: outputData))
        let center = try #require(outputRep.colorAt(x: 8, y: 8))

        #expect(output.isTemplate == false)
        #expect(center.redComponent > center.blueComponent)
    }

    @Test
    func `merged icon render signature includes quota warning flash for selected provider`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemQuotaWarningFlashTests-merged"),
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
        let snapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 50, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: nil,
            updatedAt: Date())
        store._setSnapshotForTesting(snapshot, provider: .codex)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        controller.startQuotaWarningFlash(provider: .codex)

        #expect(controller.lastAppliedMergedIconRenderSignature?.contains("warningFlash=1") == true)
    }
}
