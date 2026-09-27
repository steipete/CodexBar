import AppKit
import CodexBarCore
import Testing
@testable import CodexBar

struct StatusItemAnimationCapTests {
    @MainActor
    @Test
    func `low power mode stops animations and allows them to resume when disabled`() throws {
        let settings = testSettingsStore(
            suiteName: "StatusItemAnimationTests-low-power", userDefaults: InMemoryUserDefaults())
        settings.refreshFrequency = .manual
        settings.statusChecksEnabled = false
        settings.backgroundWorkLowPowerModePreference = .off
        settings.mergeIcons = true
        settings.selectedMenuProvider = .codex
        settings.randomBlinkEnabled = true
        let metadata = try #require(ProviderRegistry.shared.metadata[.codex])
        settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        let store = UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
        let controller = StatusItemController(
            store: store,
            settings: settings,
            account: AccountInfo(email: nil, plan: nil),
            updater: DisabledUpdaterController(),
            preferencesSelection: PreferencesSelection(),
            statusBar: .system)
        defer { controller.releaseStatusItemsForTesting() }

        store.debugForceAnimation = true
        controller.updateAnimationState()
        #expect(controller.animationDriver != nil)
        settings.backgroundWorkLowPowerModePreference = .on
        controller.updateAnimationState()
        controller.updateBlinkingState()
        #expect(!controller.shouldAnimate(provider: .codex))
        #expect(controller.animationDriver == nil)
        #expect(controller.blinkTask == nil)

        settings.backgroundWorkLowPowerModePreference = .off
        controller.updateAnimationState()
        #expect(controller.animationDriver != nil)

        store.debugForceAnimation = false
        store._setSnapshotForTesting(UsageSnapshot(primary: nil, secondary: nil, updatedAt: Date()), provider: .codex)
        controller.updateAnimationState()
        controller.updateBlinkingState()
        #expect(controller.blinkTask != nil)
        settings.backgroundWorkLowPowerModePreference = .on
        controller.updateBlinkingState()
        #expect(controller.blinkTask == nil)
        settings.backgroundWorkLowPowerModePreference = .off
        controller.updateBlinkingState()
        #expect(controller.blinkTask != nil)
    }

    @Test
    func `loading animation cap expires only after thirty seconds`() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(!StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: now.addingTimeInterval(-30),
            now: now))
        #expect(StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: now.addingTimeInterval(-30.001),
            now: now))
    }

    @Test
    func `capped animation marker does not qualify as a fresh cap`() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)

        #expect(!StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: .distantPast,
            now: now))
        #expect(!StatusItemController.loadingAnimationHasExceededContinuousCap(
            startedAt: nil,
            now: now))
    }
}
