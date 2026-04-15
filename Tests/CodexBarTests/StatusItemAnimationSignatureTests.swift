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
    func `merged render signature changes when unified icon style changes`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationSignatureTests-merged-style-signature"),
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

        settings.syntheticAPIToken = ""

        #expect(store.enabledProvidersForDisplay() == [.codex, .synthetic])
        #expect(store.enabledProviders() == [.codex])
        #expect(store.iconStyle == .codex)
        controller.applyIcon(phase: nil)
        let codexSignature = controller.lastAppliedMergedIconRenderSignature

        #expect(combinedSignature != nil)
        #expect(codexSignature != nil)
        #expect(combinedSignature != codexSignature)
        #expect(codexSignature?.contains("style=codex") == true)
    }
}
