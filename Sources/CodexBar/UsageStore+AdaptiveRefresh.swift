import Foundation

/// Wiring around `AdaptiveRefreshPolicy` for `UsageStore.startTimer()`: gathering live signals,
/// logging the resulting decision, and applying the DEBUG-only sleep-duration override used by
/// tests. Split out of UsageStore.swift to keep that file's class body under the lint line limit.
extension UsageStore {
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
        lowPowerModeEnabled: Bool,
        thermalState: ProcessInfo.ThermalState,
        policy: AdaptiveRefreshPolicy = AdaptiveRefreshPolicy()) -> AdaptiveRefreshPolicy.Decision
    {
        policy.nextDelay(for: AdaptiveRefreshPolicy.Input(
            now: now,
            lastMenuOpenAt: lastMenuOpenAt,
            lowPowerModeEnabled: lowPowerModeEnabled,
            thermalState: thermalState))
    }

    func logAdaptiveRefreshDecision(_ decision: AdaptiveRefreshPolicy.Decision) {
        // Reason and delay only; never provider/account/email/path/credential/response data.
        self.adaptiveRefreshLogger.debug(
            "adaptive refresh: reason=\(decision.reason.rawValue) delay=\(decision.delay.components.seconds)s")
    }

    /// Computes this tick's adaptive sleep duration (and logs the decision) while briefly holding a
    /// strong reference to `store`; returns nil once the store has deallocated, ending the loop.
    /// Kept as a separate call so the strong reference doesn't extend into the caller's `Task.sleep`.
    static func nextAdaptiveTimerSleepDuration(for store: UsageStore?) async -> Duration? {
        guard let store else { return nil }
        let decision = Self.adaptiveRefreshDecision(
            now: Date(),
            lastMenuOpenAt: store.lastMenuOpenAt,
            lowPowerModeEnabled: ProcessInfo.processInfo.isLowPowerModeEnabled,
            thermalState: ProcessInfo.processInfo.thermalState)
        store.logAdaptiveRefreshDecision(decision)
        return store.effectiveTimerSleepDuration(decision.delay)
    }
}
