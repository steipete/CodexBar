import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@Suite(.serialized)
@MainActor
struct StatusItemAnimationCodexCreditsTests {
    @Test
    func `codex automatic percentage uses credit limit when usage is missing`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-credit-limit-layout")
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = false
        settings.menuBarShowsBrandIconWithPercent = true
        settings.menuBarLayout = .defaultLayout
        settings.usageBarsShowUsed = true

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }

        let now = Date()
        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(nil, provider: .codex)
        store.credits = CreditsSnapshot(
            remaining: 41556.4,
            events: [],
            updatedAt: now,
            codexCreditLimit: CodexCreditLimitSnapshot(
                used: 1193.6,
                limit: 42750,
                remainingPercent: 97.208,
                resetsAt: nil,
                updatedAt: now))

        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

        controller.applyIcon(for: .codex, phase: nil)

        let title = controller.statusItems[.codex]?.button?.attributedTitle.string
        #expect(title?.contains("3%") == true)
        #expect(title?.contains("–") == false)
    }

    @Test
    func `codex icon keeps credits only rendering when usage is missing`() {
        let settings = testSettingsStore(suiteName: "StatusItemAnimationTests-credits-only-icon")
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
            statusBar: testStatusBar())
        defer { controller.releaseStatusItemsForTesting() }

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
