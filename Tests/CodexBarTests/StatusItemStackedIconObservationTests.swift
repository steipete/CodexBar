import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

@MainActor
@Suite(.serialized)
struct StatusItemStackedIconObservationTests {
    private func makeStackedController(suiteName: String) -> (UsageStore, StatusItemController) {
        let settings = testSettingsStore(suiteName: suiteName)
        settings.statusChecksEnabled = true
        settings.refreshFrequency = .manual
        settings.mergeIcons = true
        settings.menuBarShowsBrandIconWithPercent = true
        settings.mergedIconDisplayStyle = .stacked
        settings.mergeIconStackedTopProvider = .codex
        settings.mergeIconStackedBottomProvider = .claude

        let registry = ProviderRegistry.shared
        if let codexMeta = registry.metadata[.codex] {
            settings.setProviderEnabled(provider: .codex, metadata: codexMeta, enabled: true)
        }
        if let claudeMeta = registry.metadata[.claude] {
            settings.setProviderEnabled(provider: .claude, metadata: claudeMeta, enabled: true)
        }

        let fetcher = UsageFetcher()
        let store = UsageStore(fetcher: fetcher, browserDetection: BrowserDetection(cacheTTL: 0), settings: settings)
        store._setSnapshotForTesting(Self.makeSnapshot(provider: .codex, email: "codex@example.com"), provider: .codex)
        store._setSnapshotForTesting(
            Self.makeSnapshot(provider: .claude, email: "claude@example.com"),
            provider: .claude)
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: fetcher.loadAccountInfo(),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        return (store, controller)
    }

    private static func makeSnapshot(
        provider: UsageProvider,
        email: String,
        primaryUsedPercent: Double = 10,
        updatedAt: Date = Date(timeIntervalSince1970: 100))
        -> UsageSnapshot
    {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: primaryUsedPercent,
                windowMinutes: 300,
                resetsAt: nil,
                resetDescription: nil),
            secondary: RateWindow(usedPercent: 20, windowMinutes: 10080, resetsAt: nil, resetDescription: nil),
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: provider.instanceID,
                accountEmail: email,
                accountOrganization: nil,
                loginMethod: "plus"))
    }

    @Test
    func `stacked merge icon providers resolves to the configured top and bottom`() {
        let (_, controller) = self.makeStackedController(
            suiteName: "StatusItemStackedIconObservationTests-resolve")
        defer { controller.releaseStatusItemsForTesting() }

        let resolved = controller.stackedMergeIconProvidersIfActive()

        #expect(resolved?.top == .codex)
        #expect(resolved?.bottom == .claude)
    }

    @Test
    func `store icon observation signature changes when the non-primary stacked row changes`() {
        let (store, controller) = self.makeStackedController(
            suiteName: "StatusItemStackedIconObservationTests-secondary-row-change")
        defer { controller.releaseStatusItemsForTesting() }

        // Codex (top) is the primary provider for the unified icon; Claude (bottom) is the row this
        // regression covers, since a merged-mode signature keyed on only the primary would miss it.
        let baseline = controller.storeIconObservationSignature()

        store._setSnapshotForTesting(
            Self.makeSnapshot(provider: .claude, email: "claude@example.com", primaryUsedPercent: 90),
            provider: .claude)

        #expect(controller.storeIconObservationSignature() != baseline)
    }

    @Test
    func `stacked merge icon providers is nil when the icon style cannot render it`() {
        let (_, controller) = self.makeStackedController(
            suiteName: "StatusItemStackedIconObservationTests-non-percent-style")
        controller.settings.menuBarShowsBrandIconWithPercent = false
        defer { controller.releaseStatusItemsForTesting() }

        #expect(controller.stackedMergeIconProvidersIfActive() == nil)
    }

    @Test
    func `needs menu bar icon animation is false in stacked mode even while a row is still loading`() {
        let (store, controller) = self.makeStackedController(
            suiteName: "StatusItemStackedIconObservationTests-no-animation")
        defer { controller.releaseStatusItemsForTesting() }

        // Claude (the bottom row) has no snapshot and no error yet, which ordinarily drives
        // shouldAnimate(provider:) to true for a loading provider.
        store._setSnapshotForTesting(nil, provider: .claude)
        store._setErrorForTesting(nil, provider: .claude)
        #expect(controller.shouldAnimate(provider: .claude))

        // Stacked rows always render through the layout-token path (guarded by
        // menuBarShowsBrandIconWithPercent), which has no phase-driven blink/wiggle/tilt/morph rendering —
        // the 30 FPS driver must not be scheduled for a frame that never actually changes.
        #expect(controller.needsMenuBarIconAnimation() == false)
    }

    @Test
    func `updateBlinkingState does not start the surprise-me blink task in stacked mode`() {
        let (_, controller) = self.makeStackedController(
            suiteName: "StatusItemStackedIconObservationTests-no-blink")
        defer { controller.releaseStatusItemsForTesting() }

        // "Surprise me" would ordinarily start blinkTask for any enabled provider; stacked rendering never
        // consumes blinkAmounts/wiggleAmounts/tiltAmounts, so the task must never start regardless.
        controller.settings.randomBlinkEnabled = true
        controller.updateBlinkingState()

        #expect(controller.blinkTask == nil)
    }
}
