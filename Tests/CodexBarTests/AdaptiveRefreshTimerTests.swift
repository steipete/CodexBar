import CodexBarCore
import Foundation
import Testing
@testable import CodexBar

/// Covers the timer plumbing added on top of the pure `AdaptiveRefreshPolicy` (see
/// `AdaptiveRefreshPolicyTests`): how `UsageStore.startTimer()` wires live signals into the
/// policy, and how manual/fixed/adaptive modes drive (or don't drive) `refresh()` over time.
@MainActor
struct AdaptiveRefreshTimerTests {
    @Test
    func `launch with no menu history begins at thirty minutes`() {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-launch", frequency: .adaptive)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)

        #expect(store.lastMenuOpenAt == nil)
        let decision = UsageStore.adaptiveRefreshDecision(
            now: Date(),
            lastMenuOpenAt: store.lastMenuOpenAt,
            lowPowerModeEnabled: false,
            thermalState: .nominal)
        #expect(decision.reason == .longIdle)
        #expect(decision.delay == .seconds(30 * 60))
    }

    @Test
    func `menu-open signal changes the next adaptive decision`() {
        let now = Date(timeIntervalSinceReferenceDate: 900_000_000)

        let beforeOpen = UsageStore.adaptiveRefreshDecision(
            now: now, lastMenuOpenAt: nil, lowPowerModeEnabled: false, thermalState: .nominal)
        #expect(beforeOpen.reason == .longIdle)

        let afterOpen = UsageStore.adaptiveRefreshDecision(
            now: now, lastMenuOpenAt: now, lowPowerModeEnabled: false, thermalState: .nominal)
        #expect(afterOpen.reason == .recentInteraction)
    }

    @Test
    func `menu open advances a long idle timer during refresh without postponing an earlier tick`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-advance", frequency: .adaptive)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)
        store.restartTimerWithSleepOverrideForTesting(.seconds(10))
        try await Self.waitUntil { store.adaptiveRefreshScheduledAt != nil }

        let longIdleSchedule = try #require(store.adaptiveRefreshScheduledAt)
        let now = Date()
        store._setSnapshotForTesting(
            UsageSnapshot(
                primary: RateWindow(
                    usedPercent: 50,
                    windowMinutes: 300,
                    resetsAt: now.addingTimeInterval(30),
                    resetDescription: nil),
                secondary: nil,
                updatedAt: now,
                identity: nil),
            provider: .codex)
        store.scheduleResetBoundaryRefreshIfNeeded(normalRefreshInterval: 30 * 60, now: now)
        defer { store.cancelResetBoundaryRefresh() }
        let resetBoundarySchedule = try #require(store.scheduledResetBoundaryRefreshAt)

        store.isRefreshing = true
        defer { store.isRefreshing = false }
        store.noteMenuOpened()
        try await Self.waitUntil {
            guard let scheduledAt = store.adaptiveRefreshScheduledAt else { return false }
            return scheduledAt < longIdleSchedule
        }
        let interactionSchedule = try #require(store.adaptiveRefreshScheduledAt)
        #expect(store.isRefreshing)
        #expect(store.scheduledResetBoundaryRefreshAt == resetBoundarySchedule)

        store.noteMenuOpened(at: Date().addingTimeInterval(30))
        #expect(store.adaptiveRefreshScheduledAt == interactionSchedule)
    }

    @Test
    func `coding activity advances a long idle timer without postponing an earlier tick`() async throws {
        let settings = Self.makeSettingsStore(
            suite: "AdaptiveRefreshTimerTests-activity-advance",
            frequency: .adaptiveAgentAware)
        settings.adaptiveActivityScanConsent = .allowed
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)
        store.restartTimerWithSleepOverrideForTesting(.seconds(10))
        try await Self.waitUntil { store.adaptiveRefreshScheduledAt != nil }

        let longIdleSchedule = try #require(store.adaptiveRefreshScheduledAt)
        let observedAt = Date()
        store.noteCodingActivityObserved(at: observedAt, now: observedAt)
        try await Self.waitUntil {
            guard let scheduledAt = store.adaptiveRefreshScheduledAt else { return false }
            return scheduledAt < longIdleSchedule
        }
        let activitySchedule = try #require(store.adaptiveRefreshScheduledAt)
        #expect(store.lastCodingActivityAt == observedAt)

        // An older observation is ignored. A newer observation is retained, but cannot push an
        // already earlier provider refresh later.
        store.noteCodingActivityObserved(
            at: observedAt.addingTimeInterval(-1),
            now: observedAt.addingTimeInterval(30))
        #expect(store.lastCodingActivityAt == observedAt)
        store.noteCodingActivityObserved(
            at: observedAt.addingTimeInterval(1),
            now: observedAt.addingTimeInterval(30))
        #expect(store.lastCodingActivityAt == observedAt.addingTimeInterval(1))
        #expect(store.adaptiveRefreshScheduledAt == activitySchedule)
    }

    @Test
    func `plain adaptive ignores coding activity`() async throws {
        let settings = Self.makeSettingsStore(
            suite: "AdaptiveRefreshTimerTests-plain-adaptive-activity",
            frequency: .adaptive)
        settings.adaptiveActivityScanConsent = .allowed
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)
        store.restartTimerWithSleepOverrideForTesting(.seconds(10))
        try await Self.waitUntil { store.adaptiveRefreshScheduledAt != nil }
        let scheduledAt = try #require(store.adaptiveRefreshScheduledAt)

        store.noteCodingActivityObserved(at: Date())

        #expect(store.adaptiveRefreshScheduledAt == scheduledAt)
        #expect(store.lastCodingActivityAt == nil)
    }

    @Test
    func `noting a menu open records the signal without starting a refresh`() {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-noteMenuOpened", frequency: .manual)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)

        #expect(store.completedRefreshCountForTesting == 0)
        #expect(store.isRefreshing == false)

        store.noteMenuOpened()

        #expect(store.lastMenuOpenAt != nil)
        #expect(store.completedRefreshCountForTesting == 0)
        #expect(store.isRefreshing == false)
    }

    @Test
    func `noting coding activity outside agent aware mode is a no-op`() {
        let settings = Self.makeSettingsStore(
            suite: "AdaptiveRefreshTimerTests-noteCodingActivity",
            frequency: .fiveMinutes)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)
        let observedAt = Date()

        store.noteCodingActivityObserved(at: observedAt)

        #expect(store.lastCodingActivityAt == nil)
        #expect(store.adaptiveRefreshScheduledAt == nil)
        #expect(store.completedRefreshCountForTesting == 0)
    }

    @Test
    func `clearing coding activity removes the adaptive input`() {
        let settings = Self.makeSettingsStore(
            suite: "AdaptiveRefreshTimerTests-clearCodingActivity",
            frequency: .adaptiveAgentAware)
        settings.adaptiveActivityScanConsent = .allowed
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)
        store.noteCodingActivityObserved(at: Date(timeIntervalSinceReferenceDate: 100))
        #expect(store.lastCodingActivityAt != nil)

        store.clearCodingActivityObservation()

        #expect(store.lastCodingActivityAt == nil)
    }

    @Test
    func `opportunistic timer refresh is a no-op while another refresh is already in flight`() async {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-coalesce", frequency: .manual)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .testing)

        store.isRefreshing = true
        await store.refresh(enrichmentMode: .automatic)

        // The guard at the top of runRefresh() returned immediately: no completion was recorded and the
        // flag was left untouched by this call. This is the invariant every timer tick (fixed or
        // adaptive) relies on to avoid overlapping with a refresh already in flight.
        #expect(store.completedRefreshCountForTesting == 0)
        #expect(store.isRefreshing == true)
    }

    @Test
    func `manual mode performs the initial refresh but no recurring ticks`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-manual", frequency: .manual)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .full)
        try await Self.waitUntil { store.completedRefreshCountForTesting >= 1 }

        // Manual mode never starts a timer, so nothing can push the count past the one launch refresh
        // no matter how long we wait; a short settle window is enough to catch a regression.
        try await Task.sleep(for: .milliseconds(300))
        #expect(store.completedRefreshCountForTesting == 1)
    }

    @Test
    func `fixed mode ticks recur at the overridden cadence`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-fixed", frequency: .oneMinute)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .full)
        store.restartTimerWithSleepOverrideForTesting(.milliseconds(20))

        // 1 initial launch refresh plus at least one 20ms-cadence tick; proves the loop recurs
        // rather than sleeping once and stopping. Each refresh cycle here costs low single-digit
        // seconds of wall time even with every provider disabled, so the timeout is generous.
        try await Self.waitUntil(timeout: .seconds(45)) { store.completedRefreshCountForTesting >= 2 }
        #expect(store.completedRefreshCountForTesting >= 2)
    }

    @Test
    func `fixed cadence advances from scheduled tick instead of refresh completion`() {
        let interval = Duration.milliseconds(100)
        let start = ContinuousClock.now
        let firstScheduledAt = start + interval

        let nextAfterExactTick = UsageStore.nextFixedTimerScheduledAt(
            previousScheduledAt: firstScheduledAt,
            completedAt: firstScheduledAt,
            interval: interval)
        #expect(nextAfterExactTick == start + .milliseconds(200))

        let nextJustBeforeFollowingTick = UsageStore.nextFixedTimerScheduledAt(
            previousScheduledAt: firstScheduledAt,
            completedAt: firstScheduledAt + .milliseconds(100) - .nanoseconds(1),
            interval: interval)
        #expect(nextJustBeforeFollowingTick == start + .milliseconds(200))

        let nextAtFollowingTick = UsageStore.nextFixedTimerScheduledAt(
            previousScheduledAt: firstScheduledAt,
            completedAt: firstScheduledAt + .milliseconds(100),
            interval: interval)
        #expect(nextAtFollowingTick == start + .milliseconds(300))

        let nextAfterSlowRefresh = UsageStore.nextFixedTimerScheduledAt(
            previousScheduledAt: firstScheduledAt,
            completedAt: firstScheduledAt + .milliseconds(60),
            interval: interval)
        #expect(nextAfterSlowRefresh == start + .milliseconds(200))

        let nextAfterMissedTicks = UsageStore.nextFixedTimerScheduledAt(
            previousScheduledAt: firstScheduledAt,
            completedAt: firstScheduledAt + .milliseconds(260),
            interval: interval)
        #expect(nextAfterMissedTicks == start + .milliseconds(400))
    }

    @Test
    func `fixed timer loop stays interval aligned after a slow refresh`() async {
        let harness = FixedTimerLoopHarness()

        await UsageStore.runFixedRefreshTimer(
            interval: .milliseconds(100),
            now: { await harness.now() },
            sleep: { duration in await harness.sleep(for: duration) },
            refresh: { await harness.refresh() })

        #expect(await harness.recordedStarts() == [.milliseconds(100), .milliseconds(300)])
        #expect(await harness.maximumConcurrentRefreshes() == 1)
    }

    @Test
    func `adaptive mode keeps recomputing and refreshing across menu-open changes`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-adaptive", frequency: .adaptive)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .full)
        store.restartTimerWithSleepOverrideForTesting(.milliseconds(20))
        try await Self.waitUntil(timeout: .seconds(45)) { store.completedRefreshCountForTesting >= 1 }
        let countBeforeMenuOpen = store.completedRefreshCountForTesting

        store.noteMenuOpened()

        // The loop kept looping (recomputing the decision from a fresh Input) after lastMenuOpenAt
        // changed, rather than sleeping once on a captured delay and stopping.
        try await Self.waitUntil(timeout: .seconds(45)) { store.completedRefreshCountForTesting > countBeforeMenuOpen }
        #expect(store.completedRefreshCountForTesting > countBeforeMenuOpen)
    }

    @Test
    func `changing frequency away from fixed cancels the pending tick without an extra refresh`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-cancel", frequency: .oneMinute)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .full)
        // Deliberately much longer than anything else in this test: the assertion only needs this
        // sleep to still be pending (uncompleted) when we switch away, not to time anything precisely.
        store.restartTimerWithSleepOverrideForTesting(.seconds(5))
        // Only the initial launch refresh can land this quickly; the fixed-mode timer's first tick
        // needs the full 5s override to elapse, so it cannot have fired yet.
        try await Self.waitUntil { store.completedRefreshCountForTesting >= 1 }
        let countBeforeSwitch = store.completedRefreshCountForTesting

        settings.refreshFrequency = .manual

        // The settings-change path (outside adaptive-refresh scope) may fire its own refresh(es) for
        // reasons unrelated to the timer under test; wait for the count to stop moving rather than
        // assuming it fires exactly once. Windows are doubled from an earlier version that flaked once
        // under full parallel `make test` load.
        let countAfterSettling = try await Self.waitForStableCount(store: store, settleWindow: .milliseconds(800))
        #expect(countAfterSettling > countBeforeSwitch)

        // Settle comfortably within the 5s override window. If the old fixed-mode timer had not been
        // canceled, its pending tick would eventually land and push the count past the settled value —
        // but not within this window, so any further increase here indicates a real cancellation bug,
        // not settings-change noise.
        try await Task.sleep(for: .milliseconds(1600))
        #expect(store.completedRefreshCountForTesting == countAfterSettling)
    }

    // The test above goes through `settings.refreshFrequency = .manual`, which also triggers the
    // settings-observer's own `refreshForSettingsChange()` — a legitimate refresh unrelated to the
    // timer. That confound means it cannot, by itself, prove the `guard !Task.isCancelled else { return }`
    // after each branch's sleep is load-bearing (deleting either guard still leaves this test green,
    // since the settings-observer refresh already accounts for the "count increased" expectation).
    // The two tests below isolate `startTimer()`'s cancel-and-replace path directly, by calling
    // `restartTimerWithSleepOverrideForTesting` a second time at the *same* frequency — which goes
    // straight through `startTimer()` with no settings observation involved — so no refresh is
    // legitimately expected at all, and any extra one proves a canceled sleep still ran its body.

    @Test
    func `restarting the timer cancels a pending fixed tick without an extra refresh`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-cancel-fixed", frequency: .oneMinute)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .full)
        store.restartTimerWithSleepOverrideForTesting(.seconds(5))
        try await Self.waitUntil { store.completedRefreshCountForTesting >= 1 }
        let countBeforeRestart = store.completedRefreshCountForTesting

        // Cancels the pending 5s sleep above and starts a fresh one, still at .oneMinute. No settings
        // mutation, so no settings-observer refresh is expected here at all.
        store.restartTimerWithSleepOverrideForTesting(.seconds(5))

        // Neither the old (canceled) timer's tick nor the new timer's first tick can land within this
        // window — both need the full 5s override. Any refresh here can only be the canceled sleep's
        // body running anyway.
        try await Task.sleep(for: .milliseconds(800))
        #expect(store.completedRefreshCountForTesting == countBeforeRestart)
    }

    @Test
    func `restarting the timer cancels a pending adaptive tick without an extra refresh`() async throws {
        let settings = Self.makeSettingsStore(suite: "AdaptiveRefreshTimerTests-cancel-adaptive", frequency: .adaptive)
        let store = Self.makeUsageStore(settings: settings, startupBehavior: .full)
        store.restartTimerWithSleepOverrideForTesting(.seconds(5))
        try await Self.waitUntil { store.completedRefreshCountForTesting >= 1 }
        let countBeforeRestart = store.completedRefreshCountForTesting

        store.restartTimerWithSleepOverrideForTesting(.seconds(5))

        try await Task.sleep(for: .milliseconds(800))
        #expect(store.completedRefreshCountForTesting == countBeforeRestart)
    }

    /// Polls `condition` until it's true or `timeout` elapses, without assuming how long setup or
    /// scheduling takes. Throws `CancellationError` (surfaced as a test failure) on timeout.
    private static func waitUntil(
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(20),
        _ condition: () -> Bool) async throws
    {
        let deadline = ContinuousClock.now + timeout
        while !condition() {
            if ContinuousClock.now >= deadline {
                throw CancellationError()
            }
            try await Task.sleep(for: pollInterval)
        }
    }

    /// Polls `store.completedRefreshCountForTesting` until it stops changing for `settleWindow`,
    /// tolerating an unknown number of in-flight refreshes (e.g. settings-change side effects
    /// unrelated to the timer under test) before returning the final, stable count.
    private static func waitForStableCount(
        store: UsageStore,
        settleWindow: Duration,
        timeout: Duration = .seconds(30),
        pollInterval: Duration = .milliseconds(20)) async throws -> Int
    {
        let deadline = ContinuousClock.now + timeout
        var lastCount = store.completedRefreshCountForTesting
        var lastChangedAt = ContinuousClock.now
        while true {
            try await Task.sleep(for: pollInterval)
            let current = store.completedRefreshCountForTesting
            let now = ContinuousClock.now
            if current != lastCount {
                lastCount = current
                lastChangedAt = now
            } else if now - lastChangedAt >= settleWindow {
                return lastCount
            }
            if now >= deadline {
                throw CancellationError()
            }
        }
    }

    private static func makeSettingsStore(suite: String, frequency: RefreshFrequency) -> SettingsStore {
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let configStore = testConfigStore(suiteName: suite)

        let settings = SettingsStore(
            userDefaults: defaults,
            configStore: configStore,
            zaiTokenStore: NoopZaiTokenStore(),
            syntheticTokenStore: NoopSyntheticTokenStore(),
            codexCookieStore: InMemoryCookieHeaderStore(),
            claudeCookieStore: InMemoryCookieHeaderStore(),
            cursorCookieStore: InMemoryCookieHeaderStore(),
            opencodeCookieStore: InMemoryCookieHeaderStore(),
            factoryCookieStore: InMemoryCookieHeaderStore(),
            minimaxCookieStore: InMemoryMiniMaxCookieStore(),
            minimaxAPITokenStore: InMemoryMiniMaxAPITokenStore(),
            kimiTokenStore: InMemoryKimiTokenStore(),
            augmentCookieStore: InMemoryCookieHeaderStore(),
            ampCookieStore: InMemoryCookieHeaderStore(),
            copilotTokenStore: InMemoryCopilotTokenStore(),
            tokenAccountStore: InMemoryTokenAccountStore())
        settings.providerDetectionCompleted = true
        settings.refreshFrequency = frequency
        Self.disableAllProviders(settings: settings)
        return settings
    }

    /// Codex is enabled by default; disabling every provider (including it) keeps `refresh()` cheap
    /// and deterministic in these tests, which care about tick cadence, not provider fetch results.
    private static func disableAllProviders(settings: SettingsStore) {
        let metadata = ProviderRegistry.shared.metadata
        for provider in UsageProvider.allCases {
            guard let providerMetadata = metadata[provider] else { continue }
            settings.setProviderEnabled(provider: provider, metadata: providerMetadata, enabled: false)
        }
    }

    private static func makeUsageStore(
        settings: SettingsStore,
        startupBehavior: UsageStore.StartupBehavior) -> UsageStore
    {
        UsageStore(
            fetcher: UsageFetcher(environment: [:]),
            browserDetection: BrowserDetection(cacheTTL: 0),
            settings: settings,
            startupBehavior: startupBehavior,
            environmentBase: [:])
    }
}

private actor FixedTimerLoopHarness {
    private let origin = ContinuousClock.now
    private var elapsed = Duration.zero
    private var starts: [Duration] = []
    private var activeRefreshes = 0
    private var maximumActiveRefreshes = 0

    func now() -> ContinuousClock.Instant {
        self.origin + self.elapsed
    }

    func sleep(for duration: Duration) {
        self.elapsed += duration
    }

    func refresh() {
        self.activeRefreshes += 1
        self.maximumActiveRefreshes = max(self.maximumActiveRefreshes, self.activeRefreshes)
        self.starts.append(self.elapsed)
        if self.starts.count == 1 {
            self.elapsed += .milliseconds(160)
        }
        self.activeRefreshes -= 1
        if self.starts.count == 2 {
            withUnsafeCurrentTask { $0?.cancel() }
        }
    }

    func recordedStarts() -> [Duration] {
        self.starts
    }

    func maximumConcurrentRefreshes() -> Int {
        self.maximumActiveRefreshes
    }
}
