import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Covers `normalRefreshIntervalForHeuristics()` and every consumer that previously read
/// `RefreshFrequency.seconds` directly. That property is nil for both `.manual` and `.adaptive`,
/// so without the helper the interval-derived heuristics (reset-boundary refresh, OpenAI web
/// staleness, persistent-CLI-session idle windows) silently degrade to manual behavior the
/// moment a user picks adaptive. Each consumer has a test here that goes red if its call site
/// is reverted to `.seconds`.
@MainActor
struct AdaptiveRefreshHeuristicsTests {
    @Test
    func `manual keeps the heuristics interval nil`() {
        let store = Self.makeStore(suite: "heuristics-manual-nil", frequency: .manual)
        #expect(store.normalRefreshIntervalForHeuristics() == nil)
    }

    @Test(arguments: [
        (RefreshFrequency.oneMinute, 60.0),
        (.twoMinutes, 120.0),
        (.fiveMinutes, 300.0),
        (.fifteenMinutes, 900.0),
        (.thirtyMinutes, 1800.0)
    ])
    func `fixed frequencies pass their configured seconds through`(
        frequency: RefreshFrequency,
        expectedSeconds: TimeInterval)
    {
        let store = Self.makeStore(suite: "heuristics-fixed-\(frequency.rawValue)", frequency: frequency)
        #expect(store.normalRefreshIntervalForHeuristics() == expectedSeconds)
    }

    @Test
    func `adaptive resolves to the live adaptive decision delay`() {
        let store = Self.makeStore(suite: "heuristics-adaptive-live", frequency: .adaptive)

        // No recorded menu open: the decision is longIdle, or constrained on a low-power/hot
        // machine — both are 30 minutes, so this assertion is environment-independent.
        #expect(store.normalRefreshIntervalForHeuristics() == 1800.0)

        store.noteMenuOpened()
        let expected = TimeInterval(UsageStore.adaptiveRefreshDecision(
            now: Date(),
            lastMenuOpenAt: store.lastMenuOpenAt,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState).delay.components.seconds)
        #expect(store.normalRefreshIntervalForHeuristics() == expected)
        if Self.machineIsUnconstrained {
            #expect(store.normalRefreshIntervalForHeuristics() == 120.0)
        }
    }

    @Test
    func `adaptive cadence schedules a reset-boundary refresh through the refresh pipeline`() async {
        let store = Self.makeStoreWithStubbedCodex(suite: "heuristics-boundary-adaptive", frequency: .adaptive)

        // Goes through the real end-of-refresh scheduling call, which must feed the adaptive
        // interval (30 min here — no menu open) rather than the nil `RefreshFrequency.seconds`.
        await store.refresh()
        defer { store.cancelResetBoundaryRefresh() }

        #expect(store.scheduledResetBoundaryRefreshAt != nil)
    }

    @Test
    func `manual cadence still never schedules a reset-boundary refresh through the refresh pipeline`() async {
        let store = Self.makeStoreWithStubbedCodex(suite: "heuristics-boundary-manual", frequency: .manual)

        await store.refresh()
        defer { store.cancelResetBoundaryRefresh() }

        #expect(store.scheduledResetBoundaryRefreshAt == nil)
    }

    @Test
    func `adaptive mode lifts the openai web refresh interval off the manual floor`() {
        let adaptiveStore = Self.makeStore(suite: "heuristics-web-adaptive", frequency: .adaptive)
        let manualStore = Self.makeStore(suite: "heuristics-web-manual", frequency: .manual)

        let adaptiveInterval = adaptiveStore.openAIWebRefreshIntervalSeconds()
        let manualInterval = manualStore.openAIWebRefreshIntervalSeconds()

        // Manual hits the 120s fallback floor; adaptive with no menu open resolves to 1800s.
        // Comparing as a ratio keeps this independent of the web-refresh multiplier.
        #expect(manualInterval > 0)
        #expect(adaptiveInterval == manualInterval * 15)
    }

    @Test
    func `registry nominal interval maps adaptive to the policy nominal and keeps manual nil`() {
        #expect(ProviderRegistry.nominalRefreshInterval(for: .adaptive)
            == AdaptiveRefreshPolicy.nominalIntervalForHeuristics)
        #expect(ProviderRegistry.nominalRefreshInterval(for: .manual) == nil)
        #expect(ProviderRegistry.nominalRefreshInterval(for: .thirtyMinutes) == 1800.0)
    }

    @Test
    func `provider specs give adaptive a nominal cli session idle window instead of the floor`() {
        let adaptiveStore = Self.makeStore(suite: "heuristics-spec-adaptive", frequency: .adaptive)
        let manualStore = Self.makeStore(suite: "heuristics-spec-manual", frequency: .manual)

        // Registry specs have no UsageStore to ask, so adaptive maps to the policy's nominal
        // 300s steady-state interval: max(180, 300 + 60) = 360.
        let adaptiveWindow = adaptiveStore.providerSpecs[.codex]?
            .makeFetchContext().persistentCLISessionIdleWindow
        let manualWindow = manualStore.providerSpecs[.codex]?
            .makeFetchContext().persistentCLISessionIdleWindow
        #expect(adaptiveWindow == 360)
        #expect(manualWindow == 180)
    }

    @Test
    func `account-scoped fetch contexts derive the idle window from the live adaptive interval`() {
        let adaptiveStore = Self.makeStore(suite: "heuristics-account-adaptive", frequency: .adaptive)
        let manualStore = Self.makeStore(suite: "heuristics-account-manual", frequency: .manual)

        // Unlike registry specs, this path runs inside UsageStore, so adaptive uses the live
        // decision: 1800s with no menu open, giving max(180, 1800 + 60) = 1860.
        let adaptiveWindow = adaptiveStore
            .makeFetchContext(provider: .codex, override: nil).persistentCLISessionIdleWindow
        let manualWindow = manualStore
            .makeFetchContext(provider: .codex, override: nil).persistentCLISessionIdleWindow
        #expect(adaptiveWindow == 1860)
        #expect(manualWindow == 180)
    }

    private static var machineIsUnconstrained: Bool {
        let thermalState = ProcessInfo.processInfo.thermalState
        return !ProcessInfo.processInfo.isLowPowerModeEnabled
            && (thermalState == .nominal || thermalState == .fair)
    }

    private static func makeStore(suite: String, frequency: RefreshFrequency) -> UsageStore {
        let settings = testSettingsStore(suiteName: "AdaptiveRefreshHeuristicsTests-\(suite)")
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = frequency
        Self.disableAllProviders(settings: settings)
        return UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: .testing,
            environmentBase: [:])
    }

    /// The reset-boundary pipeline tests need `refresh()` to complete with a snapshot still in
    /// place, and `clearDisabledProviderRefreshState` wipes snapshots of disabled providers. So
    /// codex stays enabled but its fetch is stubbed to return a canned snapshot whose primary
    /// window resets 10 minutes out — inside a 30-minute normal-refresh window, outside nothing.
    /// The live-system account is pinned and the snapshot carries the same email, so the
    /// account-scoped apply guard resolves identically whether or not the machine running the
    /// tests has a real `~/.codex` login (CI runners do not).
    private static func makeStoreWithStubbedCodex(suite: String, frequency: RefreshFrequency) -> UsageStore {
        let store = Self.makeStore(suite: suite, frequency: frequency)
        let metadata = ProviderRegistry.shared.metadata[.codex]!
        store.settings._test_liveSystemCodexAccount = ObservedSystemCodexAccount(
            email: Self.stubbedCodexEmail,
            codexHomePath: "/Users/test/.codex",
            observedAt: Date(),
            identity: .unresolved)
        store.settings.codexActiveSource = .liveSystem
        store.settings.setProviderEnabled(provider: .codex, metadata: metadata, enabled: true)
        store.providerSpecs[.codex] = CodexAccountScopedRefreshTests.makeCodexProviderSpec(
            baseSpec: store.providerSpecs[.codex]!)
        {
            Self.snapshot(updatedAt: Date(), primaryResetsAt: Date().addingTimeInterval(10 * 60))
        }
        return store
    }

    private nonisolated static let stubbedCodexEmail = "adaptive-heuristics@example.com"

    /// Keeps `refresh()` cheap and deterministic: no provider fetch can replace the snapshot
    /// injected by the reset-boundary tests or slow the pipeline tests down.
    private static func disableAllProviders(settings: SettingsStore) {
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            guard let providerMetadata = metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: providerMetadata, enabled: false)
        }
    }

    private nonisolated static func snapshot(updatedAt: Date, primaryResetsAt: Date) -> UsageSnapshot {
        UsageSnapshot(
            primary: RateWindow(
                usedPercent: 100,
                windowMinutes: 300,
                resetsAt: primaryResetsAt,
                resetDescription: nil),
            secondary: nil,
            tertiary: nil,
            updatedAt: updatedAt,
            identity: ProviderIdentitySnapshot(
                providerID: .codex,
                accountEmail: self.stubbedCodexEmail,
                accountOrganization: nil,
                loginMethod: "Pro"))
    }
}
