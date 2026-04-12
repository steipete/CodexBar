import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemAnimationCodexCreditsTests {
    private func makeStatusBarForTesting() -> NSStatusBar {
        let env = ProcessInfo.processInfo.environment
        if env["GITHUB_ACTIONS"] == "true" || env["CI"] == "true" {
            return .system
        }
        return NSStatusBar()
    }

    @Test
    func `codex icon keeps credits only rendering when usage is missing`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "StatusItemAnimationTests-credits-only-icon"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = false

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(remaining: 80, events: [], updatedAt: Date())

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: self.makeStatusBarForTesting())

        controller.applyIcon(for: .codex, phase: nil)

        guard let image = controller.statusItems[.codex]?.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        let creditsOnlyAlpha = (rep.colorAt(x: 18, y: 17) ?? .clear).alphaComponent
        #expect(creditsOnlyAlpha > 0.05)
    }
}
