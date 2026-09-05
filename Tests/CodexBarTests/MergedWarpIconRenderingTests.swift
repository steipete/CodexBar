import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct MergedWarpIconRenderingTests {
    @Test
    func `merged warp bonus lane is preserved in show used mode when bonus is unused`() {
        let settings = SettingsStore(
            configStore: testConfigStore(suiteName: "MergedWarpIconRenderingTests-unused-bonus"),
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore())
        settings.statusChecksEnabled = false
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.selectedMenuProvider = .warp
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
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        let exhaustedSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 100, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(exhaustedSnapshot, provider: .warp)
        store._setErrorForTesting(nil, provider: .warp)

        controller.applyIcon(phase: nil)
        let exhaustedSignature = controller.lastAppliedMergedIconRenderSignature
        let exhaustedImage = controller.statusItem.button?.image?.tiffRepresentation

        let unusedSnapshot = UsageSnapshot(
            primary: RateWindow(usedPercent: 10, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            secondary: RateWindow(usedPercent: 0, windowMinutes: nil, resetsAt: nil, resetDescription: nil),
            updatedAt: Date())
        store._setSnapshotForTesting(unusedSnapshot, provider: .warp)

        controller.applyIcon(phase: nil)
        let unusedSignature = controller.lastAppliedMergedIconRenderSignature

        #expect(exhaustedSignature != nil)
        #expect(unusedSignature != nil)
        #expect(exhaustedSignature != unusedSignature)
        #expect(exhaustedSignature?.contains("weekly=0.000") == true)
        #expect(unusedSignature?.contains("weekly=0.100") == true)

        guard let image = controller.statusItem.button?.image else {
            #expect(Bool(false))
            return
        }
        let rep = image.representations.compactMap { $0 as? NSBitmapImageRep }.first(where: {
            $0.pixelsWide == 36 && $0.pixelsHigh == 36
        })
        #expect(rep != nil)
        guard let rep else { return }

        // The exhausted and unused values must reach different renderer cache entries. The latter preserves a
        // normal-strength empty bottom lane instead of Warp's dimmed missing-secondary lane.
        #expect(exhaustedImage != image.tiffRepresentation)
        let alpha = (rep.colorAt(x: 18, y: 9) ?? .clear).alphaComponent
        #expect(alpha > 0.2)
    }
}
