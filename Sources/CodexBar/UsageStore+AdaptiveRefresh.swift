import CodexBarCore
import Foundation

struct RefreshPowerState: Sendable, Equatable {
    let lowPowerModeEnabled: Bool
    let thermalState: ProcessInfo.ThermalState

    static let nominal = Self(lowPowerModeEnabled: false, thermalState: .nominal)

    static var current: Self {
        Self(
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
    }

    var isConstrained: Bool {
        self.lowPowerModeEnabled || self.thermalState == .serious || self.thermalState == .critical
    }

    var thermalStateLabel: String {
        switch self.thermalState {
        case .nominal: "nominal"
        case .fair: "fair"
        case .serious: "serious"
        case .critical: "critical"
        @unknown default: "unknown"
        }
    }
}

/// Wiring around `AdaptiveRefreshPolicy` for `UsageStore.startTimer()`: gathering live signals,
/// logging the resulting decision, and applying the DEBUG-only sleep-duration override used by
/// tests. Split out of UsageStore.swift to keep that file's class body under the lint line limit.
extension UsageStore {
    nonisolated static let constrainedRefreshInterval: Duration = .seconds(30 * 60)

    nonisolated static func constrainedFixedRefreshInterval(
        _ interval: Duration,
        powerState: RefreshPowerState) -> Duration
    {
        powerState.isConstrained ? max(interval, self.constrainedRefreshInterval) : interval
    }

    nonisolated static func shouldDeferConstrainedBackgroundWork(
        interaction: ProviderInteraction,
        enrichmentMode: RefreshEnrichmentMode,
        powerState: RefreshPowerState) -> Bool
    {
        interaction == .background && enrichmentMode == .automatic && powerState.isConstrained
    }

    func effectiveTimerSleepDuration(_ computed: Duration) -> Duration {
        #if DEBUG
        self.refreshTimerSleepOverrideForTesting ?? computed
        #else
        computed
        #endif
    }

    /// Pure wiring helper: builds the `AdaptiveRefreshPolicy.Input` from explicit values and
    /// returns the resulting decision. `startTimer()` supplies live `ProcessInfo` state and
    /// `lastMenuOpenAt` at call time; this stays a plain, testable function of its arguments.
    nonisolated static func adaptiveRefreshDecision(
        now: Date,
        lastMenuOpenAt: Date?,
        lastCodingActivityAt: Date? = nil,
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState,
        policy: AdaptiveRefreshPolicy = AdaptiveRefreshPolicy()) -> AdaptiveRefreshPolicy.Decision
    {
        policy.nextDelay(for: AdaptiveRefreshPolicy.Input(
            now: now,
            lastMenuOpenAt: lastMenuOpenAt,
            lastCodingActivityAt: lastCodingActivityAt,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState))
    }

    nonisolated static func shouldAdvanceAdaptiveTimer(scheduledAt: Date?, candidate: Date) -> Bool {
        guard let scheduledAt else { return true }
        return candidate < scheduledAt
    }

    func noteCodingActivityObserved(at date: Date, now: Date = Date()) {
        guard self.settings.adaptiveActivityScanningEnabled else { return }
        self.retainCodingActivityIfNewer(date)
        self.advanceAdaptiveTimerIfEarlier(at: now)
    }

    func advanceAdaptiveTimerIfEarlier(at date: Date) {
        guard self.settings.refreshFrequency.usesAdaptivePolicy else { return }
        let decision = Self.adaptiveRefreshDecision(
            now: date,
            lastMenuOpenAt: self.lastMenuOpenAt,
            lastCodingActivityAt: self.settings.adaptiveActivityScanningEnabled ? self.lastCodingActivityAt : nil,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        let candidate = date.addingTimeInterval(TimeInterval(decision.delay.components.seconds))
        guard Self.shouldAdvanceAdaptiveTimer(
            scheduledAt: self.adaptiveRefreshScheduledAt,
            candidate: candidate)
        else { return }
        self.restartAdaptiveTimerPreservingResetBoundary()
    }

    /// Advances a fixed timer from the last scheduled tick instead of the refresh completion time.
    /// Missed ticks are skipped so a refresh that runs longer than its interval does not create
    /// overlapping catch-up refreshes.
    nonisolated static func nextFixedTimerScheduledAt(
        previousScheduledAt: ContinuousClock.Instant,
        completedAt: ContinuousClock.Instant,
        interval: Duration) -> ContinuousClock.Instant
    {
        precondition(interval > .zero)
        var scheduledAt = previousScheduledAt + interval
        while scheduledAt <= completedAt {
            scheduledAt += interval
        }
        return scheduledAt
    }

    nonisolated static func runFixedRefreshTimer(
        interval: Duration,
        sleepOverride: Duration? = nil,
        now: @escaping @Sendable () async -> ContinuousClock.Instant = { ContinuousClock.now },
        sleep: @escaping @Sendable (Duration) async throws -> Void = { duration in
            try await Task.sleep(for: duration)
        },
        powerState: @escaping @Sendable () -> RefreshPowerState = { .current },
        decision: @escaping @Sendable (RefreshPowerState, Duration) async -> Void = { _, _ in },
        refresh: @escaping @Sendable () async -> Void) async
    {
        precondition(interval > .zero)
        var scheduledInterval = Self.constrainedFixedRefreshInterval(interval, powerState: powerState())
        var scheduledAt = await now() + scheduledInterval
        while !Task.isCancelled {
            let currentPowerState = powerState()
            let effectiveInterval = Self.constrainedFixedRefreshInterval(
                interval,
                powerState: currentPowerState)
            if effectiveInterval != scheduledInterval {
                let current = await now()
                scheduledAt = current + effectiveInterval
                scheduledInterval = effectiveInterval
            }
            await decision(currentPowerState, scheduledInterval)

            let current = await now()
            let computedSleep = current >= scheduledAt ? .zero : scheduledAt - current
            do {
                try await sleep(sleepOverride ?? computedSleep)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }

            let tickInterval = Self.constrainedFixedRefreshInterval(interval, powerState: powerState())
            if sleepOverride == nil, tickInterval != scheduledInterval {
                scheduledAt = await now() + tickInterval
                scheduledInterval = tickInterval
                await decision(powerState(), scheduledInterval)
                continue
            }

            await refresh()
            let nextPowerState = powerState()
            let nextInterval = Self.constrainedFixedRefreshInterval(
                interval,
                powerState: nextPowerState)
            let completedAt = await now()
            scheduledAt = await self.nextFixedTimerScheduledAt(
                previousScheduledAt: scheduledAt,
                completedAt: completedAt,
                interval: nextInterval)
            scheduledInterval = nextInterval
        }
    }

    func logAdaptiveRefreshDecision(
        _ decision: AdaptiveRefreshPolicy.Decision,
        powerState: RefreshPowerState)
    {
        // Never provider/account/email/path/credential/response data.
        // No "adaptive refresh: " prefix — the adaptiveRefresh log category already identifies the source.
        self.adaptiveRefreshLogger.debug(
            "reason=\(decision.reason.rawValue) delay=\(decision.delay.components.seconds)s " +
                "lowPower=\(powerState.lowPowerModeEnabled ? 1 : 0) thermal=\(powerState.thermalStateLabel)")
    }

    func logConstrainedRefreshDecision(
        lane: String,
        powerState: RefreshPowerState,
        cadence: Duration = Self.constrainedRefreshInterval,
        decision: String = "defer")
    {
        guard powerState.isConstrained else { return }
        self.adaptiveRefreshLogger.debug(
            "decision=\(decision) lane=\(lane) lowPower=\(powerState.lowPowerModeEnabled ? 1 : 0) " +
                "thermal=\(powerState.thermalStateLabel) cadence=\(cadence.components.seconds)s")
    }

    /// Computes this tick's adaptive sleep duration (and logs the decision) while briefly holding a
    /// strong reference to `store`; returns nil once the store has deallocated, ending the loop.
    /// Kept as a separate call so the strong reference doesn't extend into the caller's `Task.sleep`.
    static func nextAdaptiveTimerSleepDuration(for store: UsageStore?) async -> Duration? {
        guard let store else { return nil }
        let now = Date()
        let powerState = RefreshPowerState.current
        let decision = Self.adaptiveRefreshDecision(
            now: now,
            lastMenuOpenAt: store.lastMenuOpenAt,
            lastCodingActivityAt: store.settings.adaptiveActivityScanningEnabled
                ? store.lastCodingActivityAt
                : nil,
            lowPowerModeEnabled: powerState.lowPowerModeEnabled,
            thermalState: powerState.thermalState)
        store.adaptiveRefreshScheduledAt = now.addingTimeInterval(TimeInterval(decision.delay.components.seconds))
        store.logAdaptiveRefreshDecision(decision, powerState: powerState)
        return store.effectiveTimerSleepDuration(decision.delay)
    }

    /// The refresh interval scheduling *heuristics* (reset-boundary refresh, OpenAI web staleness,
    /// persistent-CLI-session idle windows) should use as "how often does a normal refresh happen".
    /// This is deliberately distinct from `RefreshFrequency.seconds`, which is nil for both `.manual`
    /// (no timer at all — heuristics correctly get nil here too) and `.adaptive` (no *fixed*
    /// interval, but ticks are still happening on a real, computable cadence). For `.adaptive`, this
    /// resolves to what `AdaptiveRefreshPolicy` would decide right now from live signals, so those
    /// heuristics stay active and roughly proportionate instead of silently behaving like manual.
    func normalRefreshIntervalForHeuristics() -> TimeInterval? {
        switch self.settings.refreshFrequency {
        case .manual:
            nil
        case .adaptive, .adaptiveAgentAware:
            TimeInterval(Self.adaptiveRefreshDecision(
                now: Date(),
                lastMenuOpenAt: self.lastMenuOpenAt,
                lastCodingActivityAt: self.settings.adaptiveActivityScanningEnabled
                    ? self.lastCodingActivityAt
                    : nil,
                lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
                thermalState: ProcessInfo.processInfo.thermalState).delay.components.seconds)
        default:
            self.settings.refreshFrequency.seconds
        }
    }
}
